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
}
