# Testing Patterns

**Analysis Date:** 2026-02-04

## Test Framework

**Runner:**
- XCTest (Apple's built-in testing framework)
- Swift Package Manager test target integration
- Config: `Package.swift` defines test target `GlitchoTests` with dependency on `Glitcho`

**Assertion Library:**
- XCTest assertions: `XCTAssertTrue()`, `XCTAssertEqual()`, `XCTAssertFalse()`, `XCTFail()`
- Accuracy assertions for floating-point comparisons: `XCTAssertEqual(value, expected, accuracy: 0.0001)`

**Run Commands:**
```bash
swift test                      # Run all tests
swift test --watch             # Watch mode (if supported by environment)
swift test --verbose           # Verbose output with details
```

## Test File Organization

**Location:**
- Tests co-located in `Tests/` directory at repository root, separate from source
- Test target: `Tests/GlitchoTests/` → tests for main `Glitcho` target
- Pattern: `Tests/[FileName].swift` mirrors source module structure

**Naming:**
- Test files named `[ModuleName]Tests.swift`: `NativeVideoPlayerGestureTests.swift`, `RecordingManagerTests.swift`
- Base test file: `GlitchoTests.swift` (placeholder for example tests)

**Structure:**
```
Tests/
├── GlitchoTests.swift              # Basic framework test
├── NativeVideoPlayerGestureTests.swift
└── RecordingManagerTests.swift
```

## Test Structure

**Suite Organization:**
- One test class per file: `final class NativeVideoPlayerGestureTests: XCTestCase`
- Test methods named `test[Feature]_[Behavior]`: `testApplyZoomAndPan_ClampsZoomAndPanWithinBounds()`
- Descriptive test names that explain what is being tested
- @MainActor annotation for UI/thread tests: `@MainActor final class NativeVideoPlayerGestureTests`

**Setup/Teardown Pattern:**
- Explicit setup in test methods rather than setUp() override
- Helper methods for test data generation: `withTemporaryDirectory()`, `makeTransportStreamLikeData()`
- defer blocks for cleanup: `defer { try? FileManager.default.removeItem(at: dir) }`

**Example from `NativeVideoPlayerGestureTests.swift`:**
```swift
@MainActor
final class NativeVideoPlayerGestureTests: XCTestCase {
    func testApplyZoomAndPan_ClampsZoomAndPanWithinBounds() {
        // Arrange: Set up test data and bindings
        var isPlayingValue = false
        var zoomValue: CGFloat = 10.0
        var panValue = CGSize(width: 500, height: -500)

        let isPlaying = Binding(get: { isPlayingValue }, set: { isPlayingValue = $0 })
        let zoom = Binding(get: { zoomValue }, set: { zoomValue = $0 })
        let pan = Binding(get: { panValue }, set: { panValue = $0 })

        // Create test objects
        let player = NativeVideoPlayer(
            url: URL(string: "https://example.com/video.mp4")!,
            isPlaying: isPlaying,
            pipController: nil,
            zoom: zoom,
            pan: pan,
            minZoom: 1.0,
            maxZoom: 4.0
        )

        let coordinator = NativeVideoPlayer.Coordinator(parent: player, pipController: nil)

        // Act
        let view = AVPlayerView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.wantsLayer = true
        view.layer?.bounds = CGRect(origin: .zero, size: view.bounds.size)

        let videoLayer = AVPlayerLayer()
        videoLayer.frame = view.bounds
        view.layer?.addSublayer(videoLayer)

        coordinator.applyZoomAndPan(to: view)

        // Assert
        let t = videoLayer.affineTransform()
        XCTAssertEqual(t.a, 4.0, accuracy: 0.0001)
        XCTAssertEqual(t.d, 4.0, accuracy: 0.0001)
        XCTAssertEqual(videoLayer.position.x, 400.0, accuracy: 0.0001)
        XCTAssertEqual(videoLayer.position.y, -100.0, accuracy: 0.0001)
    }
}
```

## Async Testing

**Pattern:**
- Test methods marked `async` for async code: `func testPrepareRecordingForPlayback_RemuxesTransportStreamMP4UsingFFmpeg() async throws`
- Try-catch for throwing async functions
- No explicit wait/expectation patterns; async/await syntax handles sequencing

**Example from `RecordingManagerTests.swift`:**
```swift
func testPrepareRecordingForPlayback_RemuxesTransportStreamMP4UsingFFmpeg() async throws {
    try await withTemporaryDirectory { dir in
        let inputURL = dir.appendingPathComponent("input.mp4")
        try makeTransportStreamLikeData().write(to: inputURL)

        let manager = RecordingManager()
        let result = try await manager.prepareRecordingForPlayback(at: inputURL)
        XCTAssertEqual(result.url, inputURL)
        XCTAssertTrue(result.didRemux)
    }
}
```

## Mocking

**Framework:** Manual mocking using closures and dependency injection.

**Patterns:**
- Override properties for testability: `manager._resolveFFmpegPathOverride = { fakeFFmpegURL.path }`
- Fake process execution using shell scripts in temporary directories
- Real file system operations in isolated temporary directories (not mocked)

**Example - Fake FFmpeg for testing:**
```swift
let fakeFFmpegURL = dir.appendingPathComponent("ffmpeg")

let script = """
#!/bin/sh
set -eu
printf '%s\n' \"$@\" > '\(argsLogURL.path)'
out='' ; for arg in \"$@\"; do out=\"$arg\"; done
printf 'REMUXED' > \"$out\"
exit 0
"""
try script.write(to: fakeFFmpegURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpegURL.path)

let manager = RecordingManager()
manager._resolveFFmpegPathOverride = { fakeFFmpegURL.path }
```

**What to Mock:**
- External executables (ffmpeg, streamlink) replaced with shell scripts
- File system paths isolated to temporary directories
- Optional resolution overrides for testing different paths

**What NOT to Mock:**
- FileManager operations (use real file system with isolated temp directories)
- Process execution (use real processes with fake binaries)
- URL operations and file I/O
- Time-based operations (sleep, delays) are allowed in tests

## Fixtures and Factories

**Test Data:**
- Helper method pattern for generating test data:
  ```swift
  private func makeTransportStreamLikeData(byteCount: Int = 512, includeSyncAt188: Bool = true, includeSyncAt376: Bool = true) -> Data {
      var data = Data(repeating: 0, count: byteCount)
      if !data.isEmpty {
          data[0] = 0x47
      }
      if includeSyncAt188, data.count > 188 {
          data[188] = 0x47
      }
      if includeSyncAt376, data.count > 376 {
          data[376] = 0x47
      }
      return data
  }
  ```

- Temporary directory helper for file-based tests:
  ```swift
  private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }
      return try await body(dir)
  }
  ```

**Location:**
- Helper methods defined as private methods on test class itself
- No separate fixtures directory or factory classes
- Inline fixture creation within test methods when minimal

## Coverage

**Requirements:** No coverage enforcement detected (no code coverage configuration in Package.swift or CI)

**View Coverage:**
- Run with coverage metrics via Xcode:
  ```bash
  swift test --enable-code-coverage
  xcov report --workspace Glitcho.xcworkspace --scheme Glitcho
  ```

## Test Types

**Unit Tests:**
- Scope: Individual methods and classes in isolation
- Approach: Direct instantiation, method calls, assertion of return values/state changes
- Examples: `NativeVideoPlayerGestureTests` tests gesture coordinate transformations; `RecordingManagerTests` tests file detection, process execution, deletion logic

**Integration Tests:**
- Scope: Multi-component interaction (RecordingManager with file system, process execution)
- Approach: Real file I/O, temporary directories, actual shell process invocation with fake binaries
- Example: `testPrepareRecordingForPlayback_RemuxesTransportStreamMP4UsingFFmpeg()` creates real files, runs a fake ffmpeg script, verifies arguments and output

**E2E Tests:**
- Framework: Not used
- Note: Desktop app testing via UI frameworks not evident in current test suite

## Error Testing

**Pattern:**
- Explicit error catching and verification:
  ```swift
  do {
      _ = try await manager.prepareRecordingForPlayback(at: inputURL)
      XCTFail("Expected prepareRecordingForPlayback() to throw when ffmpeg is not found")
  } catch {
      XCTAssertTrue(error.localizedDescription.contains("FFmpeg was not found"))
  }
  ```

- Error type inspection:
  ```swift
  do {
      _ = try await manager.runProcess(
          executable: "/bin/sh",
          arguments: ["-c", "echo out; echo err 1>&2; exit 3"]
      )
      XCTFail("Expected runProcess() to throw on non-zero exit")
  } catch let error as RecordingManager.ProcessExecutionError {
      XCTAssertEqual(error.exitCode, 3)
      XCTAssertEqual(error.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
      XCTAssertEqual(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
  } catch {
      XCTFail("Unexpected error type: \(error)")
  }
  ```

**Pattern Summary:**
- Success case: call method expecting it to succeed
- Failure case: wrap in do-catch, verify error type and message content

## Common Test Data

**File Operations:**
- Generated MP4-like data with MPEG-TS sync bytes at specified offsets
- Temporary directories with UUID-based isolation
- Shell script fake binaries for testing process execution

**Bindings & State:**
- SwiftUI Binding objects created inline for state testing
- Direct property mutation for observation testing
- @MainActor requirement for UI-thread operations

## Test Gaps

**Known Untested Areas:**
- View components themselves (`RecordingsLibraryView.swift`, `SettingsView.swift`, `ContentView.swift`)
- Stream decoding/playback logic in `StreamlinkPlayer.swift`
- WebView integration in `WebViewStore.swift`
- NotificationManager notification delivery
- UpdateChecker version comparison logic

---

*Testing analysis: 2026-02-04*
