# Coding Conventions

**Analysis Date:** 2026-02-04

## Naming Patterns

**Files:**
- PascalCase for all Swift source files: `RecordingManager.swift`, `NotificationManager.swift`, `StreamlinkRecorder.swift`
- One main class/struct per file
- View files follow the pattern `[ComponentName]View.swift`: `RecordingsLibraryView.swift`, `SettingsView.swift`, `UpdatePromptView.swift`
- Manager/Controller classes follow the pattern `[Name]Manager.swift` or `[Name]Controller.swift`

**Functions:**
- camelCase for function names: `requestAuthorization()`, `notifyChannelLive()`, `startRecording()`, `deleteRecording()`
- Private functions prefixed with `private func`: seen in `NotificationManager.swift`, `UpdateChecker.swift`
- Static utility functions use `static func`: `timestampString()` in `StreamlinkRecorder.swift`, `versionParts()` in `UpdateChecker.swift`
- Boolean-returning functions often use `is` prefix: `isTransportStreamFile()`, `isVersion()`, `isRecording`
- Action methods use verb-based names: `toggle()`, `attach()`, `detach()`, `startRecording()`, `stopRecording()`

**Variables:**
- camelCase for all property names
- Private properties explicitly marked: `private var process: Process?`, `private let fileManager = FileManager.default`
- Published properties for observable state: `@Published var isRecording = false`
- Computed properties for derived values: `private var currentYear: Int { ... }` in `App.swift`
- State properties use descriptive names: `userInitiatedStop`, `activeChannelLogin`, `lastOutputURL`

**Types:**
- PascalCase for class, struct, enum names: `RecordingManager`, `NotificationManager`, `UpdateChecker`
- Nested types follow parent naming: `UpdateInfo`, `StatusInfo` nested in `UpdateChecker`
- Enum cases use camelCase: `.notDirectory`, `.notWritable`
- Custom error enums inherit from `LocalizedError`: `RecorderError: LocalizedError`, `RecordingInstallError: LocalizedError`

## Code Style

**Formatting:**
- 4-space indentation (standard Swift)
- Blank lines separate logical sections within functions
- SwiftUI view bodies use clear indentation for ViewBuilder hierarchy
- Method parameters separated by commas with clear spacing

**Linting:**
- No detected linting configuration file (no .swiftlint.yml)
- Code appears to follow Apple Swift Style Guide conventions
- Consistent access modifier usage: `private`, `final` for classes that don't need inheritance

**Class/Struct Design:**
- Classes marked with `@MainActor` for thread-safe UI operations: `RecordingManager`, `NotificationManager`, `UpdateChecker`
- Final classes to prevent unintended subclassing: `final class RecordingManager`, `final class NotificationManager`
- ObservableObject protocol for state managers: `class RecordingManager: ObservableObject`

## Import Organization

**Order:**
1. Foundation framework imports first: `import Foundation`
2. Platform-specific imports: `import SwiftUI`, `import AppKit`, `import AVKit`, `import AVFoundation`
3. Standard library/conditional imports: `#if canImport(SwiftUI)`
4. Test imports in test files: `import XCTest`, `@testable import Glitcho`

**Path Aliases:**
- No path aliases detected (no custom import paths)
- Relative imports using Swift Package structure: `@testable import Glitcho` for testing

**Example from `NotificationManager.swift`:**
```swift
#if canImport(SwiftUI)
import AppKit
import Foundation
import UserNotifications
```

## Error Handling

**Patterns:**
- Custom LocalizedError enums for domain-specific errors:
  ```swift
  enum RecorderError: LocalizedError {
      case notDirectory(String)
      case notWritable(String)

      var errorDescription: String? {
          switch self {
          case .notDirectory(let path):
              return "Recordings path is not a directory: \(path)"
          case .notWritable(let path):
              return "Recordings folder is not writable: \(path)"
          }
      }
  }
  ```

- NSError construction with domain and localized descriptions for file operations:
  ```swift
  throw NSError(
      domain: "RecordingError",
      code: 10,
      userInfo: [NSLocalizedDescriptionKey: "Recording path is invalid."]
  )
  ```

- Try-catch with fallback patterns (graceful degradation):
  ```swift
  do {
      _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  } catch {
      // Fallback: if Trash isn't available for some reason, attempt a hard delete.
      try FileManager.default.removeItem(at: url)
  }
  ```

- Silent failures with optional unwrapping in non-critical operations:
  ```swift
  _ = try? await center.add(request)
  try? FileManager.default.removeItem(at: tempURL)
  ```

- Validation before operations:
  ```swift
  guard !isRecording else {
      errorMessage = "A recording is already in progress."
      return
  }
  ```

## Logging

**Framework:** No dedicated logging framework detected. Uses native print/console output and observable published properties for error messages.

**Patterns:**
- Error messages published via `@Published var errorMessage: String?` properties
- Status/progress tracking via `@Published var installStatus: String?` properties
- No console logging or dedicated logging library in use
- Errors surfaced to UI through published properties:
  ```swift
  guard let streamlinkPath = resolveStreamlinkPath() else {
      errorMessage = "Streamlink is not installed. Use Settings > Recording to download it or set a custom path."
      return
  }
  ```

## Comments

**When to Comment:**
- Documentation comments for public/important methods: seen in `RecordingManager.swift`
  ```swift
  /// Ensures the given recording file is playable by AVPlayer.
  ///
  /// Streamlink writes MPEG transport stream data to disk by default...
  func prepareRecordingForPlayback(at url: URL) async throws -> (url: URL, didRemux: Bool)
  ```

- Inline comments for complex logic, binary format parsing:
  ```swift
  // MPEG-TS packets start with a sync byte 0x47 every 188 bytes.
  // bounds: 200x100, zoom: 4 => maxX=300, maxY=150
  ```

- Clarification for non-obvious design decisions:
  ```swift
  // Prefer moving to Trash to avoid accidental data loss.
  ```

**JSDoc/TSDoc:**
- Three-slash documentation comments `///` for public APIs
- Parameter descriptions in multi-line doc comments
- Example from `RecordingManager.swift`:
  ```swift
  /// Override ffmpeg path resolution (primarily for unit tests).
  var _resolveFFmpegPathOverride: (() -> String?)?
  ```

## Function Design

**Size:**
- Functions typically 10-50 lines
- Complex operations broken into private helper methods
- Property accessors kept brief (< 10 lines)

**Parameters:**
- Named parameters with explicit types
- Default values for optional behavior: `startRecording(target: String, channelName: String?, quality: String = "best")`
- Tuples for multiple return values: `func prepareRecordingForPlayback() -> (url: URL, didRemux: Bool)`

**Return Values:**
- Explicit return types, no implicit returns
- Optional returns for fallible operations: `func resolveFFmpegPath() -> String?`
- Tuples for multiple related return values
- No generic success/failure wrappers; uses throwing functions with try-catch

## Module Design

**Exports:**
- No explicit public/internal distinction (Swift Package defaults to internal)
- All code is package-internal by default
- View components instantiated directly in parent views

**Barrel Files:**
- No barrel exports detected
- Each file exports a single primary type (class/struct)

**Observable Objects Pattern:**
- ObservableObject types: `RecordingManager`, `NotificationManager`, `UpdateChecker`, `StreamlinkManager`, `PictureInPictureController`
- These are passed via `@StateObject`, `@ObservedObject`, or `@Environment`
- Example usage in `App.swift`:
  ```swift
  @StateObject private var updateChecker = UpdateChecker()
  @StateObject private var notificationManager = NotificationManager()

  // Injected to subviews
  .environmentObject(updateChecker)
  .environment(\.notificationManager, notificationManager)
  ```

**Data Structures:**
- Immutable value types for data transfer: `UpdateInfo`, `StatusInfo`, `RecordingEntry`
- Structs with Equatable conformance for state comparison
- Nested types for related enums: `StatusInfo.Kind`

---

*Convention analysis: 2026-02-04*
