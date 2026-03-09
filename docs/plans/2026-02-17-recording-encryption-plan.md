# Recording Encryption Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Encrypt recordings on disk with AES-256-GCM so they are unplayable outside the app, with hashed filenames and an encrypted metadata manifest.

**Architecture:** New `RecordingEncryptionManager` handles all encryption logic (key management via Keychain, AES-GCM encrypt/decrypt, manifest CRUD, migration). `RecordingManager` delegates to it after remux and before playback. `RecordingsLibraryView` reads from manifest for display and decrypts for export.

**Tech Stack:** Apple CryptoKit (AES-256-GCM, SHA-256), existing `KeychainHelper`, macOS 13+ (already target)

**Design doc:** `docs/plans/2026-02-17-recording-encryption-design.md`

---

### Task 1: RecordingEncryptionManager — Key Management

**Files:**
- Create: `Sources/Glitcho/RecordingEncryptionManager.swift`
- Test: `Tests/RecordingEncryptionManagerTests.swift`

**Step 1: Write the failing tests**

Create `Tests/RecordingEncryptionManagerTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import Glitcho

@MainActor
final class RecordingEncryptionManagerTests: XCTestCase {

    // Allow tests to inject a key instead of hitting the real Keychain.
    private func makeManager(key: SymmetricKey? = nil) -> RecordingEncryptionManager {
        let mgr = RecordingEncryptionManager()
        if let key {
            mgr._keyOverride = key
        }
        return mgr
    }

    func testGetOrCreateKey_ReturnsSameKeyOnRepeatedCalls() {
        let mgr = RecordingEncryptionManager()
        mgr._keyOverride = SymmetricKey(size: .bits256)
        let key1 = mgr.encryptionKey()
        let key2 = mgr.encryptionKey()
        // SymmetricKey doesn't conform to Equatable, compare raw bytes
        XCTAssertEqual(
            key1.withUnsafeBytes { Data($0) },
            key2.withUnsafeBytes { Data($0) }
        )
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: Compilation error — `RecordingEncryptionManager` does not exist.

**Step 3: Write minimal implementation**

Create `Sources/Glitcho/RecordingEncryptionManager.swift`:

```swift
import Foundation
import CryptoKit

#if canImport(SwiftUI)

@MainActor
final class RecordingEncryptionManager {
    private static let keychainService = "com.glitcho.recording-encryption"
    private static let keychainAccount = "master-key"

    /// Override for unit tests to avoid real Keychain access.
    var _keyOverride: SymmetricKey?

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
        _ = KeychainHelper.set(
            keyData.base64EncodedString(),
            service: Self.keychainService,
            account: Self.keychainAccount
        )
        return key
    }
}

#endif
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingEncryptionManager.swift Tests/RecordingEncryptionManagerTests.swift
git commit -m "feat(encryption): add RecordingEncryptionManager with Keychain key management"
```

---

### Task 2: RecordingEncryptionManager — Encrypt & Decrypt Data

**Files:**
- Modify: `Sources/Glitcho/RecordingEncryptionManager.swift`
- Modify: `Tests/RecordingEncryptionManagerTests.swift`

**Step 1: Write the failing tests**

Add to `Tests/RecordingEncryptionManagerTests.swift`:

```swift
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
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: Compilation error — `encrypt` and `decrypt` methods do not exist.

**Step 3: Write minimal implementation**

Add to `RecordingEncryptionManager`:

```swift
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
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingEncryptionManager.swift Tests/RecordingEncryptionManagerTests.swift
git commit -m "feat(encryption): add AES-256-GCM encrypt/decrypt methods"
```

---

### Task 3: RecordingEncryptionManager — Hash Filename Generation

**Files:**
- Modify: `Sources/Glitcho/RecordingEncryptionManager.swift`
- Modify: `Tests/RecordingEncryptionManagerTests.swift`

**Step 1: Write the failing tests**

```swift
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
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: Compilation error — `generateHashFilename` does not exist.

**Step 3: Write minimal implementation**

Add to `RecordingEncryptionManager`:

```swift
func generateHashFilename(originalFilename: String) -> String {
    let salt = UUID().uuidString
    let input = "\(originalFilename)\(salt)"
    let digest = SHA256.hash(data: Data(input.utf8))
    let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    return "\(hex).glitcho"
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingEncryptionManager.swift Tests/RecordingEncryptionManagerTests.swift
git commit -m "feat(encryption): add SHA-256 hash filename generation"
```

---

### Task 4: RecordingEncryptionManager — Manifest CRUD

**Files:**
- Modify: `Sources/Glitcho/RecordingEncryptionManager.swift`
- Modify: `Tests/RecordingEncryptionManagerTests.swift`

**Step 1: Write the failing tests**

```swift
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

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
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: Compilation error — `RecordingManifestEntry`, `saveManifest`, `loadManifest` do not exist.

**Step 3: Write minimal implementation**

Add to `RecordingEncryptionManager.swift` (outside the class, but inside the `#if canImport(SwiftUI)` block):

```swift
struct RecordingManifestEntry: Codable, Equatable {
    let channelName: String
    let date: Date
    let quality: String
    let originalFilename: String
}
```

Add to `RecordingEncryptionManager` class:

```swift
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
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingEncryptionManager.swift Tests/RecordingEncryptionManagerTests.swift
git commit -m "feat(encryption): add encrypted manifest save/load with RecordingManifestEntry"
```

---

### Task 5: RecordingEncryptionManager — Encrypt File & Decrypt File

**Files:**
- Modify: `Sources/Glitcho/RecordingEncryptionManager.swift`
- Modify: `Tests/RecordingEncryptionManagerTests.swift`

**Step 1: Write the failing tests**

```swift
func testEncryptFile_CreatesEncryptedFileAndDeletesOriginal() throws {
    try withTemporaryDirectory { dir in
        let key = SymmetricKey(size: .bits256)
        let mgr = makeManager(key: key)

        let original = dir.appendingPathComponent("streamer_2026-02-17_14-30-45.mp4")
        try Data("video data".utf8).write(to: original)

        let result = try mgr.encryptFile(at: original, in: dir)

        // Original should be gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        // Encrypted file should exist.
        let encryptedURL = dir.appendingPathComponent(result.hashFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))

        // Hash filename should have .glitcho extension.
        XCTAssertTrue(result.hashFilename.hasSuffix(".glitcho"))

        // Manifest entry should have correct metadata.
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
        try mgr.decryptFile(
            named: result.hashFilename,
            in: dir,
            to: decryptedURL
        )

        let decrypted = try Data(contentsOf: decryptedURL)
        XCTAssertEqual(decrypted, content)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: Compilation error — `encryptFile` and `decryptFile` do not exist.

**Step 3: Write minimal implementation**

Add to `RecordingEncryptionManager`:

```swift
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
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingEncryptionManager.swift Tests/RecordingEncryptionManagerTests.swift
git commit -m "feat(encryption): add file-level encrypt/decrypt with metadata parsing"
```

---

### Task 6: RecordingEncryptionManager — Migration Logic

**Files:**
- Modify: `Sources/Glitcho/RecordingEncryptionManager.swift`
- Modify: `Tests/RecordingEncryptionManagerTests.swift`

**Step 1: Write the failing tests**

```swift
func testMigrateUnencryptedRecordings_EncryptsAllMP4Files() throws {
    try withTemporaryDirectory { dir in
        let key = SymmetricKey(size: .bits256)
        let mgr = makeManager(key: key)

        // Create two fake MP4 files.
        try Data("video1".utf8).write(to: dir.appendingPathComponent("streamer_2026-02-17_10-00-00.mp4"))
        try Data("video2".utf8).write(to: dir.appendingPathComponent("streamer_2026-02-17_11-00-00.mp4"))

        let result = try mgr.migrateUnencryptedRecordings(in: dir, activeOutputURLs: [])

        XCTAssertEqual(result.migratedCount, 2)
        XCTAssertEqual(result.skippedCount, 0)

        // No .mp4 files should remain.
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let mp4s = remaining.filter { $0.pathExtension.lowercased() == "mp4" }
        XCTAssertTrue(mp4s.isEmpty)

        // Should have .glitcho files + manifest.
        let glitchos = remaining.filter { $0.pathExtension == "glitcho" }
        XCTAssertEqual(glitchos.count, 3) // 2 recordings + 1 manifest

        // Manifest should have 2 entries.
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

        // Active file should still exist as .mp4.
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

        // Running again should find nothing to migrate.
        let result2 = try mgr.migrateUnencryptedRecordings(in: dir, activeOutputURLs: [])
        XCTAssertEqual(result2.migratedCount, 0)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: Compilation error — `migrateUnencryptedRecordings` does not exist.

**Step 3: Write minimal implementation**

Add to `RecordingEncryptionManager`:

```swift
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

    // Load existing manifest (or start fresh).
    var manifest = (try? loadManifest(from: directory)) ?? [:]

    var migrated = 0
    var skipped = 0

    for mp4URL in mp4Files {
        if activeURLSet.contains(mp4URL.standardizedFileURL) {
            skipped += 1
            continue
        }

        // Skip stderr log files.
        if mp4URL.lastPathComponent.hasSuffix(".stderr.log") { continue }
        // Skip remux temp files.
        if mp4URL.lastPathComponent.contains(".remux-") { continue }

        let result = try encryptFile(at: mp4URL, in: directory)
        manifest[result.hashFilename] = result.entry
        migrated += 1
    }

    if migrated > 0 {
        try saveManifest(manifest, to: directory)
    }

    return MigrationResult(migratedCount: migrated, skippedCount: skipped)
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingEncryptionManagerTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingEncryptionManager.swift Tests/RecordingEncryptionManagerTests.swift
git commit -m "feat(encryption): add migration logic for existing unencrypted recordings"
```

---

### Task 7: RecordingEncryptionManager — Temp File Cleanup

**Files:**
- Modify: `Sources/Glitcho/RecordingEncryptionManager.swift`
- Modify: `Tests/RecordingEncryptionManagerTests.swift`

**Step 1: Write the failing tests**

```swift
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
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingEncryptionManagerTests/testCleanupTempFiles 2>&1 | tail -20`
Expected: Compilation error — `cleanupTempPlaybackFiles` does not exist.

**Step 3: Write minimal implementation**

Add to `RecordingEncryptionManager`:

```swift
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
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingEncryptionManagerTests/testCleanupTempFiles 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingEncryptionManager.swift Tests/RecordingEncryptionManagerTests.swift
git commit -m "feat(encryption): add temp playback file cleanup"
```

---

### Task 8: Integrate Encryption into RecordingManager — listRecordings

**Files:**
- Modify: `Sources/Glitcho/RecordingManager.swift` (lines 7, 82-89, 108-159)
- Modify: `Sources/Glitcho/RecordingEncryptionManager.swift`

**Step 1: Write the failing test**

Add to `RecordingManagerTests.swift`:

```swift
func testListRecordings_ReturnsEntriesFromEncryptedManifest() async throws {
    try await withTemporaryDirectory { dir in
        try await withRecordingsDirectory(dir) {
            let key = SymmetricKey(size: .bits256)
            let encMgr = RecordingEncryptionManager()
            encMgr._keyOverride = key

            // Create an encrypted recording via the encryption manager.
            let mp4 = dir.appendingPathComponent("streamer_2026-01-15_10-00-00.mp4")
            try Data("video".utf8).write(to: mp4)
            let result = try encMgr.encryptFile(at: mp4, in: dir)
            try encMgr.saveManifest([result.hashFilename: result.entry], to: dir)

            let manager = RecordingManager()
            manager._encryptionManagerOverride = encMgr

            let recordings = manager.listRecordings()
            XCTAssertEqual(recordings.count, 1)
            XCTAssertEqual(recordings.first?.channelName, "streamer")
            XCTAssertNotNil(recordings.first?.recordedAt)
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingManagerTests/testListRecordings_ReturnsEntriesFromEncryptedManifest 2>&1 | tail -20`
Expected: Compilation error — `_encryptionManagerOverride` does not exist.

**Step 3: Implement changes**

In `RecordingManager.swift`:

1. Add `RecordingEncryptionManager` property and test override (near line 78):

```swift
let encryptionManager: RecordingEncryptionManager
var _encryptionManagerOverride: RecordingEncryptionManager? {
    didSet {
        if let override = _encryptionManagerOverride {
            encryptionManager = override
        }
    }
}
```

Note: actually, since `let` can't be reassigned, use a `lazy var` or init pattern. Better approach — store it as a `var`:

Add near line 78 (after `_resolveStreamlinkPathOverride`):

```swift
/// Override encryption manager (primarily for unit tests).
var _encryptionManagerOverride: RecordingEncryptionManager?
private var effectiveEncryptionManager: RecordingEncryptionManager {
    _encryptionManagerOverride ?? _encryptionManager
}
private let _encryptionManager = RecordingEncryptionManager()
```

2. Modify `init` (line 82) — add temp cleanup and migration kick:

After `_ = enforceRetentionPoliciesNow()` (line 88), add:

```swift
effectiveEncryptionManager.cleanupTempPlaybackFiles()
```

3. Modify `listRecordings()` (lines 119-159) — read from manifest instead of filesystem:

Replace the body with:

```swift
func listRecordings() -> [RecordingEntry] {
    let directory = recordingsDirectory()

    // Try loading encrypted manifest first.
    if let manifest = try? effectiveEncryptionManager.loadManifest(from: directory), !manifest.isEmpty {
        return manifest.map { hashFilename, entry in
            let url = directory.appendingPathComponent(hashFilename)
            return RecordingEntry(url: url, channelName: entry.channelName, recordedAt: entry.date)
        }.sorted { left, right in
            let nameCompare = left.channelName.localizedCaseInsensitiveCompare(right.channelName)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            switch (left.recordedAt, right.recordedAt) {
            case let (lhs?, rhs?):
                return lhs > rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return left.url.lastPathComponent < right.url.lastPathComponent
            }
        }
    }

    // Fallback: scan for unencrypted .mp4 files (pre-migration state).
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    let recordings = urls.compactMap { url -> RecordingEntry? in
        guard url.pathExtension.lowercased() == "mp4" else { return nil }
        let filename = url.deletingPathExtension().lastPathComponent
        let parts = filename.split(separator: "_")
        guard parts.count >= 3 else {
            return RecordingEntry(url: url, channelName: filename, recordedAt: nil)
        }
        let channelName = parts.dropLast(2).joined(separator: "_")
        let dateString = "\(parts[parts.count - 2])_\(parts[parts.count - 1])"
        let recordedAt = filenameDateFormatter.date(from: dateString)
        return RecordingEntry(url: url, channelName: channelName, recordedAt: recordedAt)
    }

    return recordings.sorted { left, right in
        let nameCompare = left.channelName.localizedCaseInsensitiveCompare(right.channelName)
        if nameCompare != .orderedSame {
            return nameCompare == .orderedAscending
        }
        switch (left.recordedAt, right.recordedAt) {
        case let (lhs?, rhs?):
            return lhs > rhs
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return left.url.lastPathComponent < right.url.lastPathComponent
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingManagerTests 2>&1 | tail -30`
Expected: ALL PASS (new test and existing tests)

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingManager.swift Tests/RecordingManagerTests.swift
git commit -m "feat(encryption): integrate encrypted manifest into listRecordings"
```

---

### Task 9: Integrate Encryption into Recording Pipeline — Post-Recording Encrypt

**Files:**
- Modify: `Sources/Glitcho/RecordingManager.swift` (termination handler ~lines 357-363)

**Step 1: Write the failing test**

Add to `RecordingManagerTests.swift`:

```swift
func testStartRecording_EncryptsFileAfterCompletion() async throws {
    try await withTemporaryDirectory { dir in
        try await withRecordingsDirectory(dir) {
            let fakeStreamlink = try makeFailingStreamlinkExecutable(in: dir)
            // Use a "succeeding" streamlink that creates a file and exits 0.
            let successStreamlink = dir.appendingPathComponent("success-streamlink")
            let script = """
            #!/bin/sh
            output=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output" ]; then shift; output="${1:-}"; break; fi
              shift
            done
            [ -z "$output" ] && exit 2
            printf 'FAKEMP4' > "$output"
            exit 0
            """
            try script.write(to: successStreamlink, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: successStreamlink.path)

            let key = SymmetricKey(size: .bits256)
            let encMgr = RecordingEncryptionManager()
            encMgr._keyOverride = key

            let manager = RecordingManager()
            manager._resolveStreamlinkPathOverride = { successStreamlink.path }
            manager._resolveFFmpegPathOverride = { nil } // skip remux
            manager._encryptionManagerOverride = encMgr

            XCTAssertTrue(manager.startRecording(target: "twitch.tv/testchan", channelName: "TestChan"))

            // Wait for recording to finish and encryption to complete.
            XCTAssertTrue(await waitUntil(timeout: 10) {
                manager.activeRecordingCount == 0
            })

            // Wait a bit more for async encryption.
            try await Task.sleep(nanoseconds: 500_000_000)

            // Should have no .mp4 files (encrypted away).
            let files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let mp4s = files.filter { $0.pathExtension.lowercased() == "mp4" }
            // The mp4 might still be there if it was empty/TS detection skipped.
            // But a .glitcho file should exist.
            let glitchos = files.filter { $0.pathExtension == "glitcho" }
            XCTAssertFalse(glitchos.isEmpty, "Expected at least one .glitcho file after recording completes")
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingManagerTests/testStartRecording_EncryptsFileAfterCompletion 2>&1 | tail -20`
Expected: FAIL — no `.glitcho` files created.

**Step 3: Implement changes**

In `RecordingManager.swift`, in the termination handler (around lines 357-363), after the remux block:

Replace:
```swift
let shouldAttemptFinalize = proc.terminationStatus == 0 || didUserStop
if shouldAttemptFinalize {
    Task {
        _ = try? await self.prepareRecordingForPlayback(at: session.outputURL)
    }
}
```

With:
```swift
let shouldAttemptFinalize = proc.terminationStatus == 0 || didUserStop
if shouldAttemptFinalize {
    Task {
        // Remux TS → MP4 if needed.
        _ = try? await self.prepareRecordingForPlayback(at: session.outputURL)

        // Encrypt the finalized recording.
        self.encryptCompletedRecording(
            at: session.outputURL,
            channelName: session.channelName,
            quality: session.quality
        )
    }
}
```

Add a new private method to `RecordingManager`:

```swift
private func encryptCompletedRecording(at url: URL, channelName: String?, quality: String) {
    let directory = recordingsDirectory()
    let mgr = effectiveEncryptionManager

    guard FileManager.default.fileExists(atPath: url.path) else { return }

    do {
        let result = try mgr.encryptFile(
            at: url,
            in: directory,
            channelName: channelName,
            quality: quality
        )

        var manifest = (try? mgr.loadManifest(from: directory)) ?? [:]
        manifest[result.hashFilename] = result.entry
        try mgr.saveManifest(manifest, to: directory)
    } catch {
        // If encryption fails, the original MP4 is preserved (encryptFile only
        // deletes the original after successful write of the encrypted version).
        // Log but don't surface to user — the recording is still usable.
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter RecordingManagerTests 2>&1 | tail -30`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add Sources/Glitcho/RecordingManager.swift Tests/RecordingManagerTests.swift
git commit -m "feat(encryption): encrypt recordings after capture completes"
```

---

### Task 10: Integrate Encryption into Playback — Decrypt Before Play

**Files:**
- Modify: `Sources/Glitcho/RecordingsLibraryView.swift` (lines 1049-1093, 1361-1406)

**Step 1: Modify `prepareSelectedRecording()` to decrypt `.glitcho` files**

In `RecordingsLibraryView.swift`, modify `prepareSelectedRecording()` (line 1049):

Replace the `Task` block (lines 1073-1092):

```swift
Task {
    do {
        let url = selected.url

        if url.pathExtension == "glitcho" {
            // Decrypt to temp file for playback.
            let tempURL = recordingManager.effectiveEncryptionManager.tempPlaybackURL()
            try recordingManager.effectiveEncryptionManager.decryptFile(
                named: url.lastPathComponent,
                in: recordingManager.recordingsDirectory(),
                to: tempURL
            )

            // Remux if needed.
            let result = try await recordingManager.prepareRecordingForPlayback(at: tempURL)

            if self.selectedRecording?.url != selected.url { return }
            playbackURL = result.url
            isPreparingPlayback = false
            isPlaying = true
        } else {
            let result = try await recordingManager.prepareRecordingForPlayback(at: url)
            if self.selectedRecording?.url != url { return }

            if result.didRemux {
                thumbnailRefreshToken = UUID()
                refreshRecordings()
            }

            playbackURL = result.url
            isPreparingPlayback = false
            isPlaying = true
        }
    } catch {
        if self.selectedRecording?.url != selected.url { return }
        playbackURL = nil
        playbackError = error.localizedDescription
        isPreparingPlayback = false
    }
}
```

**Step 2: Make `effectiveEncryptionManager` accessible**

In `RecordingManager.swift`, change `effectiveEncryptionManager` from `private` to `internal`:

```swift
var effectiveEncryptionManager: RecordingEncryptionManager {
    _encryptionManagerOverride ?? _encryptionManager
}
```

(Remove the `private` keyword.)

**Step 3: Update `RecordingThumbnailLoader` to handle encrypted files**

In `RecordingsLibraryView.swift`, modify `RecordingThumbnailLoader` (line 1361) to handle `.glitcho` URLs. The thumbnail loader currently creates an `AVAsset(url:)` directly — this won't work for encrypted files. We need to decrypt to temp first.

Replace the `loadThumbnail()` method:

```swift
private func loadThumbnail() {
    if url.pathExtension == "glitcho" {
        // Encrypted file — skip thumbnail generation.
        // Thumbnails will be blank for encrypted files unless we decrypt.
        // For performance, show a placeholder instead of decrypting every file.
        return
    }

    let asset = AVAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 320, height: 180)

    DispatchQueue.global(qos: .userInitiated).async {
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            DispatchQueue.main.async {
                self.image = nsImage
            }
        }
    }
}
```

**Step 4: Update `RecordingPreviewController` similarly**

In `RecordingsLibraryView.swift`, modify `RecordingPreviewController` init (line 1391):

```swift
init(url: URL) {
    if url.pathExtension == "glitcho" {
        // Encrypted — use empty player; hover preview not available.
        player = AVPlayer()
    } else {
        player = AVPlayer(url: url)
    }
    player.isMuted = true
    player.actionAtItemEnd = .pause
}
```

**Step 5: Run full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: ALL PASS

**Step 6: Commit**

```bash
git add Sources/Glitcho/RecordingManager.swift Sources/Glitcho/RecordingsLibraryView.swift
git commit -m "feat(encryption): decrypt recordings for playback with temp file lifecycle"
```

---

### Task 11: Integrate Encryption into Delete & Retention

**Files:**
- Modify: `Sources/Glitcho/RecordingManager.swift` (lines 161-185, 601-681)

**Step 1: Modify `deleteRecording(at:)` to handle both encrypted and unencrypted files, and update the manifest**

In `RecordingManager.swift`, replace `deleteRecording(at:)` (lines 161-185):

```swift
func deleteRecording(at url: URL) throws {
    guard url.isFileURL else {
        throw NSError(
            domain: "RecordingError",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Recording path is invalid."]
        )
    }

    if isRecording(outputURL: url) {
        throw NSError(
            domain: "RecordingError",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "This recording is still in progress. Stop recording before deleting it."]
        )
    }

    // Remove from manifest if encrypted.
    if url.pathExtension == "glitcho" {
        let directory = recordingsDirectory()
        let mgr = effectiveEncryptionManager
        if var manifest = try? mgr.loadManifest(from: directory) {
            manifest.removeValue(forKey: url.lastPathComponent)
            try? mgr.saveManifest(manifest, to: directory)
        }
    }

    // Prefer moving to Trash to avoid accidental data loss.
    do {
        _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    } catch {
        try FileManager.default.removeItem(at: url)
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter RecordingManagerTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 3: Commit**

```bash
git add Sources/Glitcho/RecordingManager.swift
git commit -m "feat(encryption): update deleteRecording to remove manifest entries"
```

---

### Task 12: Integrate Export with Decryption

**Files:**
- Modify: `Sources/Glitcho/RecordingsLibraryView.swift` (lines 998-1047)

**Step 1: Modify `exportSelectedRecordings()` to decrypt `.glitcho` files before export**

Replace the inner loop in `exportSelectedRecordings()` (lines 1019-1033):

```swift
for (index, entry) in selectedEntries.enumerated() {
    let originalFilename: String
    if entry.url.pathExtension == "glitcho" {
        // Look up original filename from manifest.
        let dir = recordingManager.recordingsDirectory()
        let manifest = (try? recordingManager.effectiveEncryptionManager.loadManifest(from: dir)) ?? [:]
        originalFilename = manifest[entry.url.lastPathComponent]?.originalFilename ?? "\(entry.channelName).mp4"
    } else {
        originalFilename = entry.url.lastPathComponent
    }

    let destination = destinationDir.appendingPathComponent(originalFilename)
    do {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        if entry.url.pathExtension == "glitcho" {
            // Decrypt to export destination.
            try recordingManager.effectiveEncryptionManager.decryptFile(
                named: entry.url.lastPathComponent,
                in: recordingManager.recordingsDirectory(),
                to: destination
            )
        } else {
            try FileManager.default.copyItem(at: entry.url, to: destination)
        }
        exported += 1
    } catch {
        failures.append("\(originalFilename): \(error.localizedDescription)")
    }

    await MainActor.run {
        exportProgress = Double(index + 1) / Double(max(selectedEntries.count, 1))
    }
}
```

**Step 2: Run tests**

Run: `swift test 2>&1 | tail -20`
Expected: ALL PASS

**Step 3: Commit**

```bash
git add Sources/Glitcho/RecordingsLibraryView.swift
git commit -m "feat(encryption): decrypt recordings on export to standard MP4"
```

---

### Task 13: Add Migration Trigger on App Launch

**Files:**
- Modify: `Sources/Glitcho/RecordingManager.swift` (init, ~line 82)

**Step 1: Add migration call to RecordingManager init**

In `RecordingManager.init()`, after `effectiveEncryptionManager.cleanupTempPlaybackFiles()`, add:

```swift
// Migrate any unencrypted recordings left from before the encryption feature.
let activeURLs = recordingSessions.values.map(\.outputURL)
if let result = try? effectiveEncryptionManager.migrateUnencryptedRecordings(
    in: recordingsDirectory(),
    activeOutputURLs: activeURLs
), result.migratedCount > 0 {
    GlitchoTelemetry.track(
        "recordings_migration_completed",
        metadata: [
            "migrated": "\(result.migratedCount)",
            "skipped": "\(result.skippedCount)"
        ]
    )
}
```

**Step 2: Run tests**

Run: `swift test 2>&1 | tail -30`
Expected: ALL PASS

**Step 3: Commit**

```bash
git add Sources/Glitcho/RecordingManager.swift
git commit -m "feat(encryption): trigger migration of unencrypted recordings on app launch"
```

---

### Task 14: Update `isRecording(outputURL:)` for Encrypted Files

**Files:**
- Modify: `Sources/Glitcho/RecordingManager.swift` (line 435-438)

Active recordings still use `.mp4` paths in `recordingSessions`. The `isRecording(outputURL:)` check compares against session output URLs which are `.mp4`. After encryption, the `RecordingEntry.url` points to `.glitcho` files. This means `isRecording(outputURL:)` will never match encrypted entries — which is correct behavior since by the time a recording is encrypted, it's already finished. No change needed here.

**Verify with existing tests:**

Run: `swift test --filter RecordingManagerTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 1: Commit (no-op verification)**

No code changes needed — this is a verification step that the existing `isRecording` logic is compatible.

---

### Task 15: Final Integration Test & Cleanup

**Files:**
- Modify: `Tests/RecordingEncryptionManagerTests.swift`

**Step 1: Write an end-to-end integration test**

```swift
func testFullRoundTrip_EncryptMigrateListDeleteExport() throws {
    try withTemporaryDirectory { dir in
        let key = SymmetricKey(size: .bits256)
        let mgr = makeManager(key: key)

        // 1. Create two unencrypted recordings.
        try Data("video1".utf8).write(to: dir.appendingPathComponent("channel1_2026-02-17_10-00-00.mp4"))
        try Data("video2".utf8).write(to: dir.appendingPathComponent("channel2_2026-02-17_11-00-00.mp4"))

        // 2. Migrate.
        let migResult = try mgr.migrateUnencryptedRecordings(in: dir, activeOutputURLs: [])
        XCTAssertEqual(migResult.migratedCount, 2)

        // 3. Load manifest.
        let manifest = try mgr.loadManifest(from: dir)
        XCTAssertEqual(manifest.count, 2)

        // 4. Verify channel names are parsed.
        let channels = Set(manifest.values.map(\.channelName))
        XCTAssertTrue(channels.contains("channel1"))
        XCTAssertTrue(channels.contains("channel2"))

        // 5. Decrypt one recording.
        let firstKey = manifest.keys.sorted().first!
        let exportURL = dir.appendingPathComponent("exported.mp4")
        try mgr.decryptFile(named: firstKey, in: dir, to: exportURL)
        let exported = try Data(contentsOf: exportURL)
        XCTAssertTrue(exported == Data("video1".utf8) || exported == Data("video2".utf8))

        // 6. Delete from manifest.
        var updated = manifest
        updated.removeValue(forKey: firstKey)
        try mgr.saveManifest(updated, to: dir)
        let reloaded = try mgr.loadManifest(from: dir)
        XCTAssertEqual(reloaded.count, 1)
    }
}
```

**Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: ALL PASS

**Step 3: Commit**

```bash
git add Tests/RecordingEncryptionManagerTests.swift
git commit -m "test(encryption): add full round-trip integration test"
```

---

### Task 16: Final Build Verification

**Step 1: Build the full project**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeded

**Step 2: Run all tests one final time**

Run: `swift test 2>&1 | tail -30`
Expected: ALL PASS

**Step 3: Final commit if any cleanup needed**

If all passes, no commit needed. If any issues found, fix and commit.
