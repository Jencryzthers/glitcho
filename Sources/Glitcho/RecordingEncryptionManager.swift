import Foundation
import CryptoKit
import AVFoundation
import AppKit
import Security
import Darwin

#if canImport(SwiftUI)

struct RecordingManifestEntry: Codable, Equatable {
    let channelName: String
    let date: Date
    let quality: String
    let originalFilename: String
    let sourceType: RecordingCaptureType
    let sourceTarget: String?

    private enum CodingKeys: String, CodingKey {
        case channelName
        case date
        case quality
        case originalFilename
        case sourceType
        case sourceTarget
    }

    init(
        channelName: String,
        date: Date,
        quality: String,
        originalFilename: String,
        sourceType: RecordingCaptureType = .liveRecording,
        sourceTarget: String? = nil
    ) {
        self.channelName = channelName
        self.date = date
        self.quality = quality
        self.originalFilename = originalFilename
        self.sourceType = sourceType
        self.sourceTarget = sourceTarget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelName = try container.decode(String.self, forKey: .channelName)
        date = try container.decode(Date.self, forKey: .date)
        quality = try container.decode(String.self, forKey: .quality)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        sourceType = try container.decodeIfPresent(RecordingCaptureType.self, forKey: .sourceType) ?? .liveRecording
        sourceTarget = try container.decodeIfPresent(String.self, forKey: .sourceTarget)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channelName, forKey: .channelName)
        try container.encode(date, forKey: .date)
        try container.encode(quality, forKey: .quality)
        try container.encode(originalFilename, forKey: .originalFilename)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encodeIfPresent(sourceTarget, forKey: .sourceTarget)
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
    /// (e.g. in the manifest) — it cannot be re-derived from the original name.
    func generateHashFilename(originalFilename: String) -> String {
        let salt = UUID().uuidString
        let input = "\(originalFilename)\(salt)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(hex).glitcho"
    }

    // MARK: - Manifest CRUD (Task 4)

    static let manifestFilename = "manifest.glitcho"
    private static let legacyManifestBackupFilename = "manifest.glitcho.legacy.bak"

    private func manifestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func manifestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func decodePlainManifest(from data: Data) throws -> [String: RecordingManifestEntry] {
        try manifestDecoder().decode([String: RecordingManifestEntry].self, from: data)
    }

    private func decodeLegacyEncryptedManifest(
        from data: Data,
        key: SymmetricKey
    ) throws -> [String: RecordingManifestEntry] {
        let box = try AES.GCM.SealedBox(combined: data)
        let json = try AES.GCM.open(box, using: key)
        return try manifestDecoder().decode([String: RecordingManifestEntry].self, from: json)
    }

    func saveManifest(_ manifest: [String: RecordingManifestEntry], to directory: URL) throws {
        let json = try manifestEncoder().encode(manifest)
        let url = directory.appendingPathComponent(Self.manifestFilename)
        try json.write(to: url, options: .atomic)
    }

    func loadManifest(from directory: URL) throws -> [String: RecordingManifestEntry] {
        let url = directory.appendingPathComponent(Self.manifestFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let raw = try Data(contentsOf: url)
        if let plain = try? decodePlainManifest(from: raw) {
            return plain
        }

        // Backward compatibility for older encrypted manifests.
        let key = try resolveKey(for: .decrypt)
        return try decodeLegacyEncryptedManifest(from: raw, key: key)
    }

    /// Non-interactive manifest read used by list rendering paths. Returns `nil`
    /// when the key is currently unavailable without user interaction.
    func loadManifestIfAvailableWithoutInteraction(from directory: URL) -> [String: RecordingManifestEntry]? {
        manifestQueue.sync {
            let url = directory.appendingPathComponent(Self.manifestFilename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return [:]
            }
            guard let raw = try? Data(contentsOf: url) else {
                return [:]
            }
            if let plain = try? decodePlainManifest(from: raw) {
                return plain
            }

            guard let key = try? resolveKeyIfAvailableWithoutInteraction(for: .decrypt) else {
                return nil
            }

            do {
                return try decodeLegacyEncryptedManifest(from: raw, key: key)
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
            let url = directory.appendingPathComponent(Self.manifestFilename)
            var manifest: [String: RecordingManifestEntry] = [:]

            if let raw = try? Data(contentsOf: url), !raw.isEmpty {
                if let plain = try? decodePlainManifest(from: raw) {
                    manifest = plain
                } else if let key = try? resolveKeyIfAvailableWithoutInteraction(for: .decrypt),
                          let legacy = try? decodeLegacyEncryptedManifest(from: raw, key: key) {
                    manifest = legacy
                    let backupURL = directory.appendingPathComponent(Self.legacyManifestBackupFilename)
                    if !FileManager.default.fileExists(atPath: backupURL.path) {
                        try? raw.write(to: backupURL, options: .atomic)
                    }
                } else {
                    // Preserve unknown/legacy manifest bytes before replacing with plaintext format.
                    let backupURL = directory.appendingPathComponent(Self.legacyManifestBackupFilename)
                    if !FileManager.default.fileExists(atPath: backupURL.path) {
                        try? FileManager.default.copyItem(at: url, to: backupURL)
                    }
                }
            }

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
        let thumbURL = Self.thumbnailURL(for: hashFilename)
        var temporaryInputs: [URL] = []
        defer {
            for tempURL in temporaryInputs {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        var candidates: [URL] = [videoURL]

        // Some streams are MPEG-TS data with a .mp4 extension; AVAsset probing is
        // much more reliable when the extension matches the container.
        if videoURL.pathExtension.lowercased() == "mp4" || Self.isTransportStreamFile(at: videoURL) {
            let tsTempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).thumb.ts")
            if (try? cloneOrCopyItem(at: videoURL, to: tsTempURL)) != nil {
                candidates.append(tsTempURL)
                temporaryInputs.append(tsTempURL)
            }
        }

        for candidate in candidates {
            guard let image = Self.extractThumbnailImage(from: candidate),
                  let jpegData = Self.jpegData(from: image) else {
                continue
            }
            try? jpegData.write(to: thumbURL, options: .atomic)
            return
        }
    }

    private static func extractThumbnailImage(from videoURL: URL) -> NSImage? {
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 5, preferredTimescale: 600)

        let candidateSeconds: [Double] = [1.0, 0.0, 3.0, 5.0, 10.0, 20.0, 30.0, 45.0, 60.0]

        var seen = Set<Int>()
        for seconds in candidateSeconds {
            let bucket = Int((seconds * 10).rounded())
            if !seen.insert(bucket).inserted {
                continue
            }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                continue
            }
            return NSImage(cgImage: cgImage, size: .zero)
        }

        return nil
    }

    private static func jpegData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return nil
        }
        return jpegData
    }

    private static func isTransportStreamFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 512),
              !data.isEmpty else {
            return false
        }

        func byte(at offset: Int) -> UInt8? {
            guard offset >= 0, offset < data.count else { return nil }
            return data[data.index(data.startIndex, offsetBy: offset)]
        }

        guard byte(at: 0) == 0x47 else { return false }
        if let b188 = byte(at: 188), b188 != 0x47 { return false }
        if let b376 = byte(at: 376), b376 != 0x47 { return false }
        return true
    }

    func regenerateThumbnailSidecar(for hashFilename: String, in directory: URL) throws {
        let sourceURL = directory.appendingPathComponent(hashFilename)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw EncryptionError.fileNotFound(hashFilename)
        }

        let tempURL = tempPlaybackURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try decryptFile(named: hashFilename, in: directory, to: tempURL)
        generateThumbnailSidecar(for: tempURL, hashFilename: hashFilename)
    }

    // MARK: - File-Level Encrypt/Decrypt (Task 5)

    struct EncryptFileResult {
        let hashFilename: String
        let entry: RecordingManifestEntry
    }

    // Magic prefix for legacy chunk-encrypted .glitcho files.
    // New recordings use lightweight header obfuscation instead of full-file encryption.
    private static let chunkMagic = Data("GLITCHO1".utf8)
    private static let legacyObfuscationPrefixLength = 4096
    private static let legacyObfuscationMask: UInt8 = 0xA7
    private static let obfuscationMinLength = 1024
    private static let obfuscationMaxLength = 4096

    private struct ObfuscationRecipe {
        let offset: Int
        let length: Int
        let seed: Data
    }

    func encryptFile(
        at sourceURL: URL,
        in directory: URL,
        channelName: String? = nil,
        quality: String = "best",
        date: Date = Date(),
        sourceType: RecordingCaptureType = .liveRecording,
        sourceTarget: String? = nil
    ) throws -> EncryptFileResult {
        let originalFilename = sourceURL.lastPathComponent

        // Generate thumbnail before protection while the source file is still readable.
        let hashFilename = generateHashFilename(originalFilename: originalFilename)
        generateThumbnailSidecar(for: sourceURL, hashFilename: hashFilename)

        let destinationURL = directory.appendingPathComponent(hashFilename)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }

        // Lightweight protection: alter only a small, per-file region near the MP4 header.
        // This avoids full-file crypto cost while keeping files non-playable outside Glitcho.
        try toggleObfuscationRegion(at: destinationURL, hashFilename: hashFilename)

        let resolvedChannelName = channelName ?? Self.parseChannelName(from: originalFilename)
        let resolvedDate = Self.parseDate(from: originalFilename) ?? date

        let entry = RecordingManifestEntry(
            channelName: resolvedChannelName,
            date: resolvedDate,
            quality: quality,
            originalFilename: originalFilename,
            sourceType: sourceType,
            sourceTarget: sourceTarget
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

        let probe = srcHandle.readData(ofLength: 512)
        let header = probe.prefix(8)
        if header == Self.chunkMagic {
            srcHandle.seek(toFileOffset: 8)
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
            let fileSize = ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.intValue) ?? 0
            if looksLikeV2ObfuscatedMedia(probe: probe, hashFilename: hashFilename, fileSize: fileSize) {
                try copyObfuscatedFileForPlayback(
                    from: sourceURL,
                    to: destinationURL,
                    hashFilename: hashFilename
                )
                onFirstChunk?()
                return
            }

            if looksLikeLegacyObfuscatedMP4(header: header) {
                try copyLegacyObfuscatedFileForPlayback(from: sourceURL, to: destinationURL)
                onFirstChunk?()
                return
            }

            // Legacy single-block format: whole file is one AES-GCM sealed blob.
            srcHandle.seek(toFileOffset: 0)
            let encrypted = srcHandle.readDataToEndOfFile()
            let plaintext = try decrypt(data: encrypted)
            try plaintext.write(to: destinationURL, options: .atomic)
            // Single-block: the full file is ready — signal now.
            onFirstChunk?()
        }
    }

    private func copyObfuscatedFileForPlayback(
        from sourceURL: URL,
        to destinationURL: URL,
        hashFilename: String
    ) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try cloneOrCopyItem(at: sourceURL, to: destinationURL)
        try toggleObfuscationRegion(at: destinationURL, hashFilename: hashFilename)
    }

    private func copyLegacyObfuscatedFileForPlayback(from sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try cloneOrCopyItem(at: sourceURL, to: destinationURL)
        try toggleLegacyObfuscationPrefix(at: destinationURL)
    }

    private func cloneOrCopyItem(at sourceURL: URL, to destinationURL: URL) throws {
        let didClone = sourceURL.path.withCString { srcPtr in
            destinationURL.path.withCString { dstPtr in
                clonefile(srcPtr, dstPtr, 0) == 0
            }
        }
        if didClone {
            return
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func obfuscationRecipe(hashFilename: String, fileSize: Int) -> ObfuscationRecipe {
        let seed = Data(
            SHA256.hash(data: Data("glitcho-obf-v2|\(hashFilename)".utf8))
        )
        let boundedFileSize = max(0, fileSize)
        guard boundedFileSize > 0 else {
            return ObfuscationRecipe(offset: 0, length: 0, seed: seed)
        }

        let desiredLengthRange = Self.obfuscationMaxLength - Self.obfuscationMinLength + 1
        let desiredLength = Self.obfuscationMinLength + Int(seed[0]) % max(1, desiredLengthRange)
        var offset = Int(seed[1] % 5) // keep close to header while varying per file
        if offset >= boundedFileSize {
            offset = 0
        }
        var length = min(desiredLength, max(0, boundedFileSize - offset))
        if length < 8 {
            offset = 0
            length = min(desiredLength, boundedFileSize)
        }
        return ObfuscationRecipe(offset: offset, length: length, seed: seed)
    }

    private func keyStream(seed: Data, length: Int) -> Data {
        guard length > 0 else { return Data() }
        var stream = Data()
        stream.reserveCapacity(length)
        var counter: UInt32 = 0
        while stream.count < length {
            var material = Data()
            material.append(seed)
            var beCounter = counter.bigEndian
            withUnsafeBytes(of: &beCounter) { bytes in
                material.append(contentsOf: bytes)
            }
            stream.append(contentsOf: SHA256.hash(data: material))
            counter &+= 1
        }
        return stream.prefix(length)
    }

    private func toggleObfuscationRegion(at url: URL, hashFilename: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let recipe = obfuscationRecipe(hashFilename: hashFilename, fileSize: fileSize)
        guard recipe.length > 0 else { return }

        guard let handle = FileHandle(forUpdatingAtPath: url.path) else {
            throw EncryptionError.fileNotFound(url.lastPathComponent)
        }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: UInt64(recipe.offset))
        var chunk = handle.readData(ofLength: recipe.length)
        guard !chunk.isEmpty else { return }
        let stream = keyStream(seed: recipe.seed, length: chunk.count)

        chunk.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<buffer.count {
                base[index] ^= stream[stream.index(stream.startIndex, offsetBy: index)]
            }
        }

        handle.seek(toFileOffset: UInt64(recipe.offset))
        handle.write(chunk)
    }

    private func toggleLegacyObfuscationPrefix(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let length = min(Self.legacyObfuscationPrefixLength, max(0, fileSize))
        guard length > 0 else { return }

        guard let handle = FileHandle(forUpdatingAtPath: url.path) else {
            throw EncryptionError.fileNotFound(url.lastPathComponent)
        }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: 0)
        var prefix = handle.readData(ofLength: length)
        guard !prefix.isEmpty else { return }

        prefix.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<buffer.count {
                base[index] ^= Self.legacyObfuscationMask
            }
        }

        handle.seek(toFileOffset: 0)
        handle.write(prefix)
    }

    private func looksLikeV2ObfuscatedMedia(probe: Data, hashFilename: String, fileSize: Int) -> Bool {
        guard !probe.isEmpty else { return false }
        let recipe = obfuscationRecipe(hashFilename: hashFilename, fileSize: fileSize)
        guard recipe.length > 0 else { return false }

        var bytes = [UInt8](probe)
        if recipe.offset < bytes.count {
            let overlapStart = max(0, recipe.offset)
            let overlapEnd = min(bytes.count, recipe.offset + recipe.length)
            if overlapStart < overlapEnd {
                let stream = keyStream(seed: recipe.seed, length: overlapEnd - recipe.offset)
                for absoluteIndex in overlapStart..<overlapEnd {
                    let streamIndex = absoluteIndex - recipe.offset
                    bytes[absoluteIndex] ^= stream[stream.index(stream.startIndex, offsetBy: streamIndex)]
                }
            }
        }

        if looksLikeMP4Header(bytes) {
            return true
        }
        return looksLikeTransportStreamHeader(bytes)
    }

    private func looksLikeLegacyObfuscatedMP4(header: Data) -> Bool {
        guard header.count >= 8 else { return false }
        var bytes = [UInt8](header.prefix(8))
        for index in 0..<bytes.count {
            bytes[index] ^= Self.legacyObfuscationMask
        }
        return looksLikeMP4Header(bytes)
    }

    private func looksLikeMP4Header(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 8 else { return false }
        let boxSize = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])

        guard boxSize >= 8, boxSize <= 1_048_576 else { return false }
        return bytes[4] == 0x66
            && bytes[5] == 0x74
            && bytes[6] == 0x79
            && bytes[7] == 0x70
    }

    private func looksLikeTransportStreamHeader(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, bytes[0] == 0x47 else { return false }
        if bytes.count > 188, bytes[188] != 0x47 { return false }
        if bytes.count > 376, bytes[376] != 0x47 { return false }
        return true
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
    static let tempPlaybackTransportSuffix = ".glitcho-playback.ts"

    func tempPlaybackURL() -> URL {
        let filename = "\(UUID().uuidString)\(Self.tempPlaybackSuffix)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    func tempTransportPlaybackURL() -> URL {
        let filename = "\(UUID().uuidString)\(Self.tempPlaybackTransportSuffix)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    func cleanupTempPlaybackFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            let name = file.lastPathComponent
            if name.hasSuffix(Self.tempPlaybackSuffix) || name.hasSuffix(Self.tempPlaybackTransportSuffix) {
                try? FileManager.default.removeItem(at: file)
            }
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
