import Foundation
import CryptoKit
import AVFoundation
import AppKit
import Security

#if canImport(SwiftUI)

struct RecordingManifestEntry: Codable, Equatable {
    let channelName: String
    let date: Date
    let quality: String
    let originalFilename: String
    let sourceType: RecordingCaptureType

    private enum CodingKeys: String, CodingKey {
        case channelName
        case date
        case quality
        case originalFilename
        case sourceType
    }

    init(
        channelName: String,
        date: Date,
        quality: String,
        originalFilename: String,
        sourceType: RecordingCaptureType = .liveRecording
    ) {
        self.channelName = channelName
        self.date = date
        self.quality = quality
        self.originalFilename = originalFilename
        self.sourceType = sourceType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelName = try container.decode(String.self, forKey: .channelName)
        date = try container.decode(Date.self, forKey: .date)
        quality = try container.decode(String.self, forKey: .quality)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        sourceType = try container.decodeIfPresent(RecordingCaptureType.self, forKey: .sourceType) ?? .liveRecording
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channelName, forKey: .channelName)
        try container.encode(date, forKey: .date)
        try container.encode(quality, forKey: .quality)
        try container.encode(originalFilename, forKey: .originalFilename)
        try container.encode(sourceType, forKey: .sourceType)
    }
}

final class RecordingEncryptionManager {
    private static let keychainService = "com.glitcho.recording-encryption"
    private static let keychainAccount = "master-key"
    private static var cachedKey: SymmetricKey?

    /// Serializes all manifest reads and writes to prevent a read-modify-write race
    /// when two recordings finish concurrently.
    private let manifestQueue = DispatchQueue(label: "com.glitcho.manifest", qos: .utility)

    /// Override for unit tests to avoid real Keychain access.
    var _keyOverride: SymmetricKey?

    private enum KeyUse {
        case encrypt
        case decrypt
    }

    // MARK: - Key Management (Task 1)

    func encryptionKey() -> SymmetricKey {
        if let override = _keyOverride { return override }
        if let cached = Self.cachedKey { return cached }
        if let resolved = try? resolveKey(for: .encrypt) {
            return resolved
        }

        // Legacy non-throwing accessor fallback: avoid crashing call-sites that still
        // use this helper directly. Production encrypt/decrypt paths use `resolveKey`.
        let key = SymmetricKey(size: .bits256)
        Self.cachedKey = key
        return key
    }

    private func securityMessage(for status: OSStatus) -> String {
        guard let text = SecCopyErrorMessageString(status, nil) as String? else {
            return "\(status)"
        }
        return "\(status) (\(text))"
    }

    private func resolveKey(for use: KeyUse) throws -> SymmetricKey {
        if let override = _keyOverride { return override }
        if let cached = Self.cachedKey { return cached }

        var requiredInteractiveUnlock = false
        var lookup = KeychainHelper.getData(
            service: Self.keychainService,
            account: Self.keychainAccount,
            allowUserInteraction: false
        )
        if lookup.status == errSecInteractionNotAllowed {
            requiredInteractiveUnlock = true
            lookup = KeychainHelper.getData(
                service: Self.keychainService,
                account: Self.keychainAccount,
                allowUserInteraction: true
            )
        }

        switch lookup.status {
        case errSecSuccess:
            guard let raw = lookup.data,
                  let stored = String(data: raw, encoding: .utf8),
                  let keyData = Data(base64Encoded: stored),
                  keyData.count == 32 else {
                throw EncryptionError.keyMaterialCorrupted
            }

            // Legacy builds may have created the key with ACL that always prompts.
            // After one successful interactive unlock, normalize the item to our
            // default non-interactive accessibility to prevent repeated prompts.
            if requiredInteractiveUnlock {
                _ = KeychainHelper.set(
                    keyData.base64EncodedString(),
                    service: Self.keychainService,
                    account: Self.keychainAccount
                )
            }

            let key = SymmetricKey(data: keyData)
            Self.cachedKey = key
            return key

        case errSecItemNotFound:
            // Never auto-create on decrypt/read paths; that would silently "rotate"
            // and make existing recordings appear corrupted.
            guard use == .encrypt else {
                throw EncryptionError.missingKey
            }

            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            let persisted = KeychainHelper.set(
                keyData.base64EncodedString(),
                service: Self.keychainService,
                account: Self.keychainAccount
            )
            guard persisted else {
                throw EncryptionError.keyPersistFailed
            }
            Self.cachedKey = key
            return key

        default:
            throw EncryptionError.keychainAccessFailed(securityMessage(for: lookup.status))
        }
    }

    fileprivate func decryptionKeyForStreaming() throws -> SymmetricKey {
        try resolveKey(for: .decrypt)
    }

    private func resolveKeyIfAvailableWithoutInteraction(for use: KeyUse) throws -> SymmetricKey? {
        if let override = _keyOverride { return override }
        if let cached = Self.cachedKey { return cached }

        let lookup = KeychainHelper.getData(
            service: Self.keychainService,
            account: Self.keychainAccount,
            allowUserInteraction: false
        )

        switch lookup.status {
        case errSecSuccess:
            guard let raw = lookup.data,
                  let stored = String(data: raw, encoding: .utf8),
                  let keyData = Data(base64Encoded: stored),
                  keyData.count == 32 else {
                throw EncryptionError.keyMaterialCorrupted
            }
            let key = SymmetricKey(data: keyData)
            Self.cachedKey = key
            return key
        case errSecInteractionNotAllowed, errSecItemNotFound:
            return nil
        default:
            throw EncryptionError.keychainAccessFailed(securityMessage(for: lookup.status))
        }
    }

    // MARK: - Encrypt & Decrypt (Task 2)

    func encrypt(data: Data) throws -> Data {
        let key = try resolveKey(for: .encrypt)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw EncryptionError.sealFailed
        }
        return combined
    }

    func decrypt(data: Data) throws -> Data {
        let key = try resolveKey(for: .decrypt)
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key)
        } catch {
            // Hide raw CryptoKit errors so UI can present a meaningful recovery hint.
            throw EncryptionError.decryptionFailed
        }
    }

    enum EncryptionError: LocalizedError {
        case sealFailed
        case manifestCorrupted
        case fileNotFound(String)
        case decryptionFailed
        case missingKey
        case keyMaterialCorrupted
        case keyPersistFailed
        case keychainAccessFailed(String)

        var errorDescription: String? {
            switch self {
            case .sealFailed:
                return "Failed to encrypt data."
            case .manifestCorrupted:
                return "The recordings manifest could not be read. Recordings metadata may be lost."
            case .fileNotFound(let name):
                return "Recording file not found: \(name)"
            case .decryptionFailed:
                return "This recording could not be decrypted with the current key. The key may have changed, or the file is corrupted."
            case .missingKey:
                return "Recording key was not found in Keychain. Existing encrypted recordings cannot be decrypted."
            case .keyMaterialCorrupted:
                return "Recording key in Keychain is invalid."
            case .keyPersistFailed:
                return "Could not save recording key to Keychain."
            case .keychainAccessFailed(let detail):
                return "Keychain access failed: \(detail)"
            }
        }
    }

    // MARK: - Hash Filename Generation (Task 3)

    /// Generates a non-deterministic hash filename for the given original filename.
    /// The mapping is one-way (uses a random salt) and must be persisted by the caller
    /// (e.g. in the encrypted manifest) — it cannot be re-derived from the original name.
    func generateHashFilename(originalFilename: String) -> String {
        let salt = UUID().uuidString
        let input = "\(originalFilename)\(salt)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(hex).glitcho"
    }

    // MARK: - Manifest CRUD (Task 4)

    static let manifestFilename = "manifest.glitcho"

    func saveManifest(_ manifest: [String: RecordingManifestEntry], to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(manifest)
        let encrypted = try encrypt(data: json)
        let url = directory.appendingPathComponent(Self.manifestFilename)
        try encrypted.write(to: url, options: .atomic)
    }

    func loadManifest(from directory: URL) throws -> [String: RecordingManifestEntry] {
        let url = directory.appendingPathComponent(Self.manifestFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let encrypted = try Data(contentsOf: url)
        let json = try decrypt(data: encrypted)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: RecordingManifestEntry].self, from: json)
    }

    /// Non-interactive manifest read used by list rendering paths. Returns `nil`
    /// when the key is currently unavailable without user interaction.
    func loadManifestIfAvailableWithoutInteraction(from directory: URL) -> [String: RecordingManifestEntry]? {
        manifestQueue.sync {
            let url = directory.appendingPathComponent(Self.manifestFilename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return [:]
            }
            guard let key = try? resolveKeyIfAvailableWithoutInteraction(for: .decrypt) else {
                return nil
            }
            guard let encrypted = try? Data(contentsOf: url) else {
                return [:]
            }

            do {
                let box = try AES.GCM.SealedBox(combined: encrypted)
                let json = try AES.GCM.open(box, using: key)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode([String: RecordingManifestEntry].self, from: json)
            } catch {
                return [:]
            }
        }
    }

    // MARK: - Serialized Manifest Access

    /// Thread-safe wrapper around `loadManifest` that serializes access through `manifestQueue`.
    func loadManifestSerialized(from directory: URL) throws -> [String: RecordingManifestEntry] {
        try manifestQueue.sync { try loadManifest(from: directory) }
    }

    /// Thread-safe wrapper around `saveManifest` that serializes access through `manifestQueue`.
    func saveManifestSerialized(_ manifest: [String: RecordingManifestEntry], to directory: URL) throws {
        try manifestQueue.sync { try saveManifest(manifest, to: directory) }
    }

    /// Atomically adds or updates a single manifest entry without a full read-modify-write race.
    /// All manifest I/O is serialized through `manifestQueue`, so concurrent callers cannot
    /// overwrite each other's entries.
    func upsertManifestEntry(_ entry: RecordingManifestEntry, hashFilename: String, in directory: URL) throws {
        try manifestQueue.sync {
            var manifest = (try? loadManifest(from: directory)) ?? [:]
            manifest[hashFilename] = entry
            try saveManifest(manifest, to: directory)
        }
    }

    // MARK: - Thumbnail Cache

    static var thumbnailCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("Glitcho/thumbnails", isDirectory: true)
    }

    static func thumbnailURL(for hashFilename: String) -> URL {
        thumbnailCacheDirectory.appendingPathComponent(hashFilename + ".thumb")
    }

    private static func ensureThumbnailCacheDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: thumbnailCacheDirectory,
            withIntermediateDirectories: true
        )
    }

    func generateThumbnailSidecar(for videoURL: URL, hashFilename: String) {
        Self.ensureThumbnailCacheDirectoryExists()
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        // Be maximally tolerant: snap to any available frame near each candidate time.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 5, preferredTimescale: 600)

        // Try several timestamps in case the stream starts late or the first second is black.
        let candidates: [Double] = [1.0, 0.0, 3.0, 5.0, 10.0]
        var cgImage: CGImage?
        for seconds in candidates {
            let t = CMTime(seconds: seconds, preferredTimescale: 600)
            if let img = try? generator.copyCGImage(at: t, actualTime: nil) {
                cgImage = img
                break
            }
        }
        guard let cgImage else { return }

        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return }
        try? jpegData.write(to: Self.thumbnailURL(for: hashFilename), options: .atomic)
    }

    // MARK: - File-Level Encrypt/Decrypt (Task 5)

    struct EncryptFileResult {
        let hashFilename: String
        let entry: RecordingManifestEntry
    }

    // Magic prefix written at the start of every chunked .glitcho file.
    // Absence of this prefix means the file uses the legacy single-block format.
    private static let chunkMagic = Data("GLITCHO1".utf8)
    private static let chunkSize  = 8 * 1024 * 1024  // 8 MB per chunk

    func encryptFile(
        at sourceURL: URL,
        in directory: URL,
        channelName: String? = nil,
        quality: String = "best",
        date: Date = Date(),
        sourceType: RecordingCaptureType = .liveRecording
    ) throws -> EncryptFileResult {
        let originalFilename = sourceURL.lastPathComponent

        // Generate thumbnail before encryption while the source file is still readable.
        let hashFilename = generateHashFilename(originalFilename: originalFilename)
        generateThumbnailSidecar(for: sourceURL, hashFilename: hashFilename)

        let destinationURL = directory.appendingPathComponent(hashFilename)

        // Chunked streaming encryption: read/encrypt/write one chunk at a time so
        // peak RAM usage is O(chunkSize) rather than O(fileSize).
        guard let srcHandle = FileHandle(forReadingAtPath: sourceURL.path) else {
            throw EncryptionError.fileNotFound(sourceURL.lastPathComponent)
        }
        defer { srcHandle.closeFile() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        guard let dstHandle = FileHandle(forWritingAtPath: destinationURL.path) else {
            throw EncryptionError.sealFailed
        }
        defer { dstHandle.closeFile() }

        // Header: magic(8) + chunkSize(4) + chunkCount(4, back-patched later).
        var cs = UInt32(Self.chunkSize).bigEndian
        var placeholder = UInt32(0).bigEndian
        dstHandle.write(Self.chunkMagic)
        dstHandle.write(Data(bytes: &cs, count: 4))
        let chunkCountOffset = dstHandle.offsetInFile
        dstHandle.write(Data(bytes: &placeholder, count: 4))

        var chunkCount = UInt32(0)
        while true {
            let chunk = srcHandle.readData(ofLength: Self.chunkSize)
            guard !chunk.isEmpty else { break }
            let sealed = try encrypt(data: chunk)
            var sealedLen = UInt32(sealed.count).bigEndian
            dstHandle.write(Data(bytes: &sealedLen, count: 4))
            dstHandle.write(sealed)
            chunkCount += 1
        }

        // Back-patch chunk count into header.
        dstHandle.seek(toFileOffset: chunkCountOffset)
        var finalCount = chunkCount.bigEndian
        dstHandle.write(Data(bytes: &finalCount, count: 4))

        // Delete the plaintext original.
        try FileManager.default.removeItem(at: sourceURL)

        let resolvedChannelName = channelName ?? Self.parseChannelName(from: originalFilename)
        let resolvedDate = Self.parseDate(from: originalFilename) ?? date

        let entry = RecordingManifestEntry(
            channelName: resolvedChannelName,
            date: resolvedDate,
            quality: quality,
            originalFilename: originalFilename,
            sourceType: sourceType
        )

        return EncryptFileResult(hashFilename: hashFilename, entry: entry)
    }

    /// Decrypts a .glitcho file to `destinationURL`.
    ///
    /// - Parameter onFirstChunk: Called on the background thread immediately after the first
    ///   chunk has been written to `destinationURL`. The caller can use this to start
    ///   AVPlayer on the partial file before the full decryption is complete, enabling
    ///   streaming playback of large recordings.
    func decryptFile(
        named hashFilename: String,
        in directory: URL,
        to destinationURL: URL,
        onFirstChunk: (() -> Void)? = nil
    ) throws {
        let sourceURL = directory.appendingPathComponent(hashFilename)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw EncryptionError.fileNotFound(hashFilename)
        }

        guard let srcHandle = FileHandle(forReadingAtPath: sourceURL.path) else {
            throw EncryptionError.fileNotFound(hashFilename)
        }
        defer { srcHandle.closeFile() }

        let header = srcHandle.readData(ofLength: 8)
        if header == Self.chunkMagic {
            // Chunked format: read header, decrypt each chunk, stream to destination.
            let chunkSizeData  = srcHandle.readData(ofLength: 4)
            let chunkCountData = srcHandle.readData(ofLength: 4)
            guard chunkSizeData.count == 4, chunkCountData.count == 4 else {
                throw EncryptionError.manifestCorrupted
            }
            let chunkCount = chunkCountData.withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped }

            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            guard let dstHandle = FileHandle(forWritingAtPath: destinationURL.path) else {
                throw EncryptionError.sealFailed
            }
            defer { dstHandle.closeFile() }

            for chunkIndex in 0..<chunkCount {
                let sealedLenData = srcHandle.readData(ofLength: 4)
                guard sealedLenData.count == 4 else { throw EncryptionError.manifestCorrupted }
                let sealedLen = sealedLenData.withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped }
                let sealedData = srcHandle.readData(ofLength: Int(sealedLen))
                let plaintext = try decrypt(data: sealedData)
                dstHandle.write(plaintext)
                // Signal after first chunk so callers can start streaming playback immediately.
                if chunkIndex == 0 { onFirstChunk?() }
            }
        } else {
            // Legacy single-block format: whole file is one AES-GCM sealed blob.
            srcHandle.seek(toFileOffset: 0)
            let encrypted = srcHandle.readDataToEndOfFile()
            let plaintext = try decrypt(data: encrypted)
            try plaintext.write(to: destinationURL, options: .atomic)
            // Single-block: the full file is ready — signal now.
            onFirstChunk?()
        }
    }

    // MARK: - Migration Logic (Task 6)

    struct MigrationResult {
        let migratedCount: Int
        let skippedCount: Int
    }

    func migrateUnencryptedRecordings(
        in directory: URL,
        activeOutputURLs: [URL]
    ) throws -> MigrationResult {
        let activeURLSet = Set(activeOutputURLs.map { $0.standardizedFileURL })

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return MigrationResult(migratedCount: 0, skippedCount: 0)
        }

        let mp4Files = files.filter { $0.pathExtension.lowercased() == "mp4" }
        guard !mp4Files.isEmpty else {
            return MigrationResult(migratedCount: 0, skippedCount: 0)
        }

        var migrated = 0
        var skipped = 0

        for mp4URL in mp4Files {
            if activeURLSet.contains(mp4URL.standardizedFileURL) {
                skipped += 1
                continue
            }
            // Skip stderr log files and remux temp files.
            if mp4URL.lastPathComponent.hasSuffix(".stderr.log") { continue }
            if mp4URL.lastPathComponent.contains(".remux-") { continue }

            let result = try encryptFile(at: mp4URL, in: directory)
            // Save manifest after each file to avoid data loss if interrupted.
            // Use upsertManifestEntry so concurrent access from other contexts is safe.
            try upsertManifestEntry(result.entry, hashFilename: result.hashFilename, in: directory)
            migrated += 1
        }

        return MigrationResult(migratedCount: migrated, skippedCount: skipped)
    }

    // MARK: - Temp File Cleanup (Task 7)

    static let tempPlaybackSuffix = ".glitcho-playback.mp4"

    func tempPlaybackURL() -> URL {
        let filename = "\(UUID().uuidString)\(Self.tempPlaybackSuffix)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    func cleanupTempPlaybackFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.lastPathComponent.hasSuffix(Self.tempPlaybackSuffix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes `.thumb` sidecar files whose corresponding `.glitcho` recording no longer
    /// exists in the manifest. This handles deletions that bypassed `deleteRecording(at:)`
    /// (e.g. via Finder or a pre-fix retention policy) and keeps the thumbnail cache lean.
    /// Safe to call at launch — the thumbnails directory is typically small.
    func cleanupOrphanedThumbnails(knownHashFilenames: Set<String>) {
        let dir = Self.thumbnailCacheDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension == "thumb" {
            // The thumb filename is "<hashFilename>.thumb", so the base name is the hash.
            let hashFilename = file.deletingPathExtension().lastPathComponent
            if !knownHashFilenames.contains(hashFilename) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Filename Parsing Helpers


    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parseChannelName(from filename: String) -> String {
        let stem = filename.replacingOccurrences(of: ".mp4", with: "")
        let parts = stem.split(separator: "_")
        guard parts.count >= 3 else { return stem }
        if parts.count >= 4,
           RecordingCaptureType.fromFilenameTag(String(parts[parts.count - 3])) != nil {
            return parts.dropLast(3).joined(separator: "_")
        }
        return parts.dropLast(2).joined(separator: "_")
    }

    static func parseDate(from filename: String) -> Date? {
        let stem = filename.replacingOccurrences(of: ".mp4", with: "")
        let parts = stem.split(separator: "_")
        guard parts.count >= 3 else { return nil }
        let dateString = "\(parts[parts.count - 2])_\(parts[parts.count - 1])"
        return filenameDateFormatter.date(from: dateString)
    }
}

// MARK: - Streaming Resource Loader

/// AVAssetResourceLoader delegate for zero-wait streaming of encrypted .glitcho files.
///
/// Usage:
/// ```swift
/// var comps = URLComponents()
/// comps.scheme = "glitcho-stream"; comps.host = "local"; comps.path = glitchoFile.path
/// let asset = AVURLAsset(url: comps.url!)
/// let loader = GlitchoStreamResourceLoader(glitchoURL: glitchoFile, encryptionManager: mgr)
/// asset.resourceLoader.setDelegate(loader, queue: .global(qos: .userInitiated))
/// let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
/// ```
final class GlitchoStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    private let glitchoURL: URL
    private let encryptionManager: RecordingEncryptionManager

    // Must match the constants in RecordingEncryptionManager.encryptFile
    private static let chunkMagic      = Data("GLITCHO1".utf8)
    private static let headerSize      = 16           // magic(8) + chunkSize(4) + chunkCount(4)
    private static let chunkLenSize    = 4            // UInt32 BE per chunk
    private static let gcmOverhead     = 28           // nonce(12) + tag(16)
    private static let plainChunkSize  = 8 * 1024 * 1024         // 8 MB
    private static let sealedChunkSize = plainChunkSize + gcmOverhead  // 8 388 636
    private static let chunkBlockSize  = chunkLenSize + sealedChunkSize // 8 388 640

    // Cached total plaintext size (computed once on first content-info request).
    private var cachedTotalSize: Int?
    // For legacy single-block files: cache decrypted bytes to avoid repeated full decryption.
    private var cachedLegacyData: Data?

    init(glitchoURL: URL, encryptionManager: RecordingEncryptionManager) {
        self.glitchoURL = glitchoURL
        self.encryptionManager = encryptionManager
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // Handle both content-info and data in a single async block so that
        // finishLoading() is called exactly once after ALL parts are fulfilled.
        // The first request from AVPlayer typically carries both; the old
        // if/else-if pattern dropped the data request and called finishLoading()
        // with no data, which caused AVPlayer to stall.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                if let info = loadingRequest.contentInformationRequest {
                    let total = try computeTotalSize()
                    info.contentType = "public.mpeg-4"
                    info.contentLength = Int64(total)
                    info.isByteRangeAccessSupported = true
                }
                if let data = loadingRequest.dataRequest {
                    try serveData(data)
                }
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    // MARK: Helpers

    private func computeTotalSize() throws -> Int {
        if let cached = cachedTotalSize { return cached }

        guard let fh = FileHandle(forReadingAtPath: glitchoURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { fh.closeFile() }

        let magic = fh.readData(ofLength: 8)
        if magic == Self.chunkMagic {
            let rest = fh.readData(ofLength: 8) // chunkSize(4) + chunkCount(4)
            guard rest.count == 8 else { throw CocoaError(.fileReadCorruptFile) }
            let chunkCount = rest.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped }
            guard chunkCount > 0 else { cachedTotalSize = 0; return 0 }

            // Read last chunk's sealedLen to determine its plaintext size.
            let lastOffset = UInt64(Self.headerSize + Int(chunkCount - 1) * Self.chunkBlockSize)
            fh.seek(toFileOffset: lastOffset)
            let lenData = fh.readData(ofLength: 4)
            guard lenData.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
            let lastSealedLen = lenData.withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped }
            let lastPlain = Int(lastSealedLen) - Self.gcmOverhead
            let total = Int(chunkCount - 1) * Self.plainChunkSize + lastPlain
            cachedTotalSize = total
            return total
        } else {
            // Legacy single-block: decrypt everything once and cache it.
            fh.seek(toFileOffset: 0)
            let encrypted = fh.readDataToEndOfFile()
            let key = try encryptionManager.decryptionKeyForStreaming()
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plain = try AES.GCM.open(box, using: key)
            cachedLegacyData = plain
            cachedTotalSize = plain.count
            return plain.count
        }
    }

    private func serveData(_ dataRequest: AVAssetResourceLoadingDataRequest) throws {
        let reqOffset = Int(dataRequest.requestedOffset)
        let reqLength = dataRequest.requestedLength
        let reqEnd    = reqOffset + reqLength
        guard reqLength > 0 else { return }

        guard let fh = FileHandle(forReadingAtPath: glitchoURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { fh.closeFile() }

        let magic = fh.readData(ofLength: 8)
        if magic == Self.chunkMagic {
            // Chunked format: decrypt only the chunks that cover the requested range.
            let rest = fh.readData(ofLength: 8)
            guard rest.count == 8 else { throw CocoaError(.fileReadCorruptFile) }
            let chunkCount = Int(rest.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped })
            guard chunkCount > 0 else { return }

            let startChunk = reqOffset / Self.plainChunkSize
            let endChunk   = min(chunkCount - 1, (reqEnd - 1) / Self.plainChunkSize)
            guard startChunk <= endChunk else { return }

            let key = try encryptionManager.decryptionKeyForStreaming()
            for idx in startChunk...endChunk {
                let chunkFileOff = UInt64(Self.headerSize + idx * Self.chunkBlockSize)
                fh.seek(toFileOffset: chunkFileOff)
                let lenData = fh.readData(ofLength: 4)
                guard lenData.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
                let sealedLen = Int(lenData.withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped })
                let sealed    = fh.readData(ofLength: sealedLen)
                guard sealed.count == sealedLen else { throw CocoaError(.fileReadCorruptFile) }

                let box      = try AES.GCM.SealedBox(combined: sealed)
                let plain    = try AES.GCM.open(box, using: key)
                let chunkBeg = idx * Self.plainChunkSize
                let chunkEnd = chunkBeg + plain.count
                let from     = max(reqOffset, chunkBeg) - chunkBeg
                let to       = min(reqEnd, chunkEnd)    - chunkBeg
                guard from < to else { continue }
                dataRequest.respond(with: plain.subdata(in: from..<to))
            }
        } else {
            // Legacy single-block: use cached decrypted data if already available.
            let plain: Data
            if let cached = cachedLegacyData {
                plain = cached
            } else {
                fh.seek(toFileOffset: 0)
                let encrypted = fh.readDataToEndOfFile()
                let key = try encryptionManager.decryptionKeyForStreaming()
                let box = try AES.GCM.SealedBox(combined: encrypted)
                plain = try AES.GCM.open(box, using: key)
                cachedLegacyData = plain
            }
            let from = min(reqOffset, plain.count)
            let to   = min(reqEnd, plain.count)
            if from < to { dataRequest.respond(with: plain.subdata(in: from..<to)) }
        }
    }
}

#endif
