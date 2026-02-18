import Foundation
import CryptoKit

#if canImport(SwiftUI)

struct RecordingManifestEntry: Codable, Equatable {
    let channelName: String
    let date: Date
    let quality: String
    let originalFilename: String
}

@MainActor
final class RecordingEncryptionManager {
    private static let keychainService = "com.glitcho.recording-encryption"
    private static let keychainAccount = "master-key"

    /// Override for unit tests to avoid real Keychain access.
    var _keyOverride: SymmetricKey?

    // MARK: - Key Management (Task 1)

    func encryptionKey() -> SymmetricKey {
        if let override = _keyOverride { return override }

        // Try loading from Keychain.
        if let stored = KeychainHelper.get(
            service: Self.keychainService,
            account: Self.keychainAccount,
            allowUserInteraction: false
        ),
           let data = Data(base64Encoded: stored),
           data.count == 32 {
            return SymmetricKey(data: data)
        }

        // Generate and persist a new key.
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let persisted = KeychainHelper.set(
            keyData.base64EncodedString(),
            service: Self.keychainService,
            account: Self.keychainAccount
        )
        if !persisted {
            GlitchoTelemetry.track("encryption_key_persist_failed")
        }
        return key
    }

    // MARK: - Encrypt & Decrypt (Task 2)

    func encrypt(data: Data) throws -> Data {
        let key = encryptionKey()
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw EncryptionError.sealFailed
        }
        return combined
    }

    func decrypt(data: Data) throws -> Data {
        let key = encryptionKey()
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    enum EncryptionError: LocalizedError {
        case sealFailed
        case manifestCorrupted
        case fileNotFound(String)

        var errorDescription: String? {
            switch self {
            case .sealFailed:
                return "Failed to encrypt data."
            case .manifestCorrupted:
                return "The recordings manifest could not be read. Recordings metadata may be lost."
            case .fileNotFound(let name):
                return "Recording file not found: \(name)"
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

    // MARK: - File-Level Encrypt/Decrypt (Task 5)

    struct EncryptFileResult {
        let hashFilename: String
        let entry: RecordingManifestEntry
    }

    func encryptFile(
        at sourceURL: URL,
        in directory: URL,
        channelName: String? = nil,
        quality: String = "best",
        date: Date = Date()
    ) throws -> EncryptFileResult {
        let originalFilename = sourceURL.lastPathComponent
        let plaintext = try Data(contentsOf: sourceURL)
        let encrypted = try encrypt(data: plaintext)

        let hashFilename = generateHashFilename(originalFilename: originalFilename)
        let destinationURL = directory.appendingPathComponent(hashFilename)
        try encrypted.write(to: destinationURL, options: .atomic)

        // Delete the plaintext original.
        try FileManager.default.removeItem(at: sourceURL)

        let resolvedChannelName = channelName ?? Self.parseChannelName(from: originalFilename)
        let resolvedDate = Self.parseDate(from: originalFilename) ?? date

        let entry = RecordingManifestEntry(
            channelName: resolvedChannelName,
            date: resolvedDate,
            quality: quality,
            originalFilename: originalFilename
        )

        return EncryptFileResult(hashFilename: hashFilename, entry: entry)
    }

    func decryptFile(named hashFilename: String, in directory: URL, to destinationURL: URL) throws {
        let sourceURL = directory.appendingPathComponent(hashFilename)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw EncryptionError.fileNotFound(hashFilename)
        }
        let encrypted = try Data(contentsOf: sourceURL)
        let plaintext = try decrypt(data: encrypted)
        try plaintext.write(to: destinationURL, options: .atomic)
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

#endif
