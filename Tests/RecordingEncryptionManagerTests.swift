import XCTest
import CryptoKit
@testable import Glitcho

@MainActor
final class RecordingEncryptionManagerTests: XCTestCase {

    private func makeManager(key: SymmetricKey? = nil) -> RecordingEncryptionManager {
        let mgr = RecordingEncryptionManager()
        if let key {
            mgr._keyOverride = key
        }
        return mgr
    }

    // MARK: - Task 1: Key management

    func testGetOrCreateKey_ReturnsSameKeyOnRepeatedCalls() {
        let mgr = RecordingEncryptionManager()
        mgr._keyOverride = SymmetricKey(size: .bits256)
        let key1 = mgr.encryptionKey()
        let key2 = mgr.encryptionKey()
        XCTAssertEqual(
            key1.withUnsafeBytes { Data($0) },
            key2.withUnsafeBytes { Data($0) }
        )
    }

    // MARK: - Task 2: Encrypt/decrypt

    func testEncryptDecrypt_RoundTripsData() throws {
        let key = SymmetricKey(size: .bits256)
        let mgr = makeManager(key: key)
        let original = Data("Hello, encrypted world!".utf8)

        let encrypted = try mgr.encrypt(data: original)
        XCTAssertNotEqual(encrypted, original)

        let decrypted = try mgr.decrypt(data: encrypted)
        XCTAssertEqual(decrypted, original)
    }

    func testDecrypt_FailsWithWrongKey() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let mgr1 = makeManager(key: key1)
        let mgr2 = makeManager(key: key2)

        let encrypted = try mgr1.encrypt(data: Data("secret".utf8))
        XCTAssertThrowsError(try mgr2.decrypt(data: encrypted))
    }

    func testEncrypt_ProducesDifferentCiphertextEachTime() throws {
        let key = SymmetricKey(size: .bits256)
        let mgr = makeManager(key: key)
        let data = Data("same input".utf8)

        let enc1 = try mgr.encrypt(data: data)
        let enc2 = try mgr.encrypt(data: data)
        XCTAssertNotEqual(enc1, enc2, "Each encryption should use a unique nonce")
    }

    // MARK: - Task 3: Hash filename

    func testGenerateHashFilename_Returns32HexCharsWithGlitchoExtension() {
        let mgr = makeManager(key: SymmetricKey(size: .bits256))
        let result = mgr.generateHashFilename(originalFilename: "streamer_2026-02-17_14-30-45.mp4")

        XCTAssertTrue(result.hasSuffix(".glitcho"))
        let stem = result.replacingOccurrences(of: ".glitcho", with: "")
        XCTAssertEqual(stem.count, 32)
        XCTAssertTrue(stem.allSatisfy { $0.isHexDigit })
    }

    func testGenerateHashFilename_ProducesDifferentResultsForSameInput() {
        let mgr = makeManager(key: SymmetricKey(size: .bits256))
        let a = mgr.generateHashFilename(originalFilename: "same.mp4")
        let b = mgr.generateHashFilename(originalFilename: "same.mp4")
        XCTAssertNotEqual(a, b, "Each call uses a random salt")
    }

    // MARK: - Helpers

    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    // MARK: - Task 4: Manifest CRUD

    func testManifest_SaveAndLoadRoundTrip() throws {
        try withTemporaryDirectory { dir in
            let key = SymmetricKey(size: .bits256)
            let mgr = makeManager(key: key)

            let entry = RecordingManifestEntry(
                channelName: "streamer",
                date: Date(timeIntervalSinceReferenceDate: 1000),
                quality: "best",
                originalFilename: "streamer_2026-02-17_14-30-45.mp4"
            )
            var manifest: [String: RecordingManifestEntry] = [:]
            manifest["abc123def456.glitcho"] = entry

            try mgr.saveManifest(manifest, to: dir)
            let loaded = try mgr.loadManifest(from: dir)

            XCTAssertEqual(loaded.count, 1)
            XCTAssertEqual(loaded["abc123def456.glitcho"]?.channelName, "streamer")
            XCTAssertEqual(loaded["abc123def456.glitcho"]?.quality, "best")
            XCTAssertEqual(loaded["abc123def456.glitcho"]?.originalFilename, "streamer_2026-02-17_14-30-45.mp4")
        }
    }

    func testLoadManifest_ReturnsEmptyWhenNoManifestExists() throws {
        try withTemporaryDirectory { dir in
            let mgr = makeManager(key: SymmetricKey(size: .bits256))
            let loaded = try mgr.loadManifest(from: dir)
            XCTAssertTrue(loaded.isEmpty)
        }
    }

    func testLoadManifest_ThrowsWhenDecryptionFails() throws {
        try withTemporaryDirectory { dir in
            let key1 = SymmetricKey(size: .bits256)
            let key2 = SymmetricKey(size: .bits256)
            let mgr1 = makeManager(key: key1)
            let mgr2 = makeManager(key: key2)

            let entry = RecordingManifestEntry(
                channelName: "test",
                date: Date(),
                quality: "best",
                originalFilename: "test.mp4"
            )
            try mgr1.saveManifest(["file.glitcho": entry], to: dir)
            XCTAssertThrowsError(try mgr2.loadManifest(from: dir))
        }
    }

    // MARK: - Task 5: File-level encrypt/decrypt

    func testEncryptFile_CreatesEncryptedFileAndDeletesOriginal() throws {
        try withTemporaryDirectory { dir in
            let key = SymmetricKey(size: .bits256)
            let mgr = makeManager(key: key)

            let original = dir.appendingPathComponent("streamer_2026-02-17_14-30-45.mp4")
            try Data("video data".utf8).write(to: original)

            let result = try mgr.encryptFile(at: original, in: dir)

            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

            let encryptedURL = dir.appendingPathComponent(result.hashFilename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
            XCTAssertTrue(result.hashFilename.hasSuffix(".glitcho"))
            XCTAssertEqual(result.entry.originalFilename, "streamer_2026-02-17_14-30-45.mp4")
        }
    }

    func testDecryptFile_WritesDecryptedDataToDestination() throws {
        try withTemporaryDirectory { dir in
            let key = SymmetricKey(size: .bits256)
            let mgr = makeManager(key: key)

            let original = dir.appendingPathComponent("test.mp4")
            let content = Data("test video content".utf8)
            try content.write(to: original)

            let result = try mgr.encryptFile(at: original, in: dir)

            let decryptedURL = dir.appendingPathComponent("decrypted.mp4")
            try mgr.decryptFile(named: result.hashFilename, in: dir, to: decryptedURL)

            let decrypted = try Data(contentsOf: decryptedURL)
            XCTAssertEqual(decrypted, content)
        }
    }

    // MARK: - Task 6: Migration logic

    func testMigrateUnencryptedRecordings_EncryptsAllMP4Files() throws {
        try withTemporaryDirectory { dir in
            let key = SymmetricKey(size: .bits256)
            let mgr = makeManager(key: key)

            try Data("video1".utf8).write(to: dir.appendingPathComponent("streamer_2026-02-17_10-00-00.mp4"))
            try Data("video2".utf8).write(to: dir.appendingPathComponent("streamer_2026-02-17_11-00-00.mp4"))

            let result = try mgr.migrateUnencryptedRecordings(in: dir, activeOutputURLs: [])

            XCTAssertEqual(result.migratedCount, 2)
            XCTAssertEqual(result.skippedCount, 0)

            let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let mp4s = remaining.filter { $0.pathExtension.lowercased() == "mp4" }
            XCTAssertTrue(mp4s.isEmpty)

            let glitchos = remaining.filter { $0.pathExtension == "glitcho" }
            XCTAssertEqual(glitchos.count, 3) // 2 recordings + 1 manifest

            let manifest = try mgr.loadManifest(from: dir)
            XCTAssertEqual(manifest.count, 2)
        }
    }

    func testMigrateUnencryptedRecordings_SkipsActiveRecordings() throws {
        try withTemporaryDirectory { dir in
            let key = SymmetricKey(size: .bits256)
            let mgr = makeManager(key: key)

            let activeURL = dir.appendingPathComponent("active_2026-02-17_12-00-00.mp4")
            try Data("active".utf8).write(to: activeURL)
            try Data("done".utf8).write(to: dir.appendingPathComponent("done_2026-02-17_13-00-00.mp4"))

            let result = try mgr.migrateUnencryptedRecordings(in: dir, activeOutputURLs: [activeURL])

            XCTAssertEqual(result.migratedCount, 1)
            XCTAssertEqual(result.skippedCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path))
        }
    }

    func testMigrateUnencryptedRecordings_IsIdempotent() throws {
        try withTemporaryDirectory { dir in
            let key = SymmetricKey(size: .bits256)
            let mgr = makeManager(key: key)

            try Data("video".utf8).write(to: dir.appendingPathComponent("test_2026-02-17_10-00-00.mp4"))

            let result1 = try mgr.migrateUnencryptedRecordings(in: dir, activeOutputURLs: [])
            XCTAssertEqual(result1.migratedCount, 1)

            let result2 = try mgr.migrateUnencryptedRecordings(in: dir, activeOutputURLs: [])
            XCTAssertEqual(result2.migratedCount, 0)
        }
    }

    // MARK: - Task 7: Temp file cleanup

    func testCleanupTempFiles_RemovesGlitchoTempFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("\(UUID().uuidString).glitcho-playback.mp4")
        try Data("temp".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        let mgr = makeManager(key: SymmetricKey(size: .bits256))
        mgr.cleanupTempPlaybackFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
    }
}
