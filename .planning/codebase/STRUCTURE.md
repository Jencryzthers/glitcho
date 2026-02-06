# Codebase Structure

**Analysis Date:** 2026-02-04

## Directory Layout

```
glitcho/
├── Sources/
│   └── Glitcho/
│       ├── App.swift                      # Entry point, window config, about view
│       ├── ContentView.swift              # Main UI: sidebar + detail split, mode logic
│       ├── WebViewStore.swift             # WKWebView + JavaScript injection + data extraction
│       ├── StreamlinkPlayer.swift         # Streamlink process + AVPlayer wrapper
│       ├── RecordingManager.swift         # Recording orchestration + file management
│       ├── RecordingsLibraryView.swift    # Recordings browsing and playback UI
│       ├── SettingsView.swift             # Settings UI and configuration
│       ├── NotificationManager.swift      # macOS notification center integration
│       ├── UpdateChecker.swift            # GitHub release checking
│       ├── PictureInPictureController.swift # PiP support
│       ├── StreamlinkRecorder.swift       # (Legacy/utility) recording helper
│       ├── DetachedChatView.swift         # Floating chat window
│       ├── WindowConfigurator.swift       # Window chrome customization
│       ├── SidebarTint.swift              # Sidebar color theming
│       ├── PinnedChannel.swift            # Data model for pinned channels
│       ├── UpdatePromptView.swift         # Update notification UI
│       ├── UpdateStatusView.swift         # Update progress/status UI
│       ├── Environment+NotificationManager.swift  # Environment key injection
│       ├── NonSwiftUIMain.swift           # (Legacy) non-SwiftUI entry point
│       └── WebViewStore.swift             # (see above, large file)
├── Tests/
│   ├── GlitchoTests.swift
│   ├── NativeVideoPlayerGestureTests.swift
│   └── RecordingManagerTests.swift
├── Resources/
│   └── AppIcon.iconset/
│       └── (icon files at various resolutions)
├── Scripts/
│   └── make_app.sh                       # Build script
├── Build/
│   └── Glitcho.app                       # Generated app bundle
├── Package.swift                          # SPM manifest
├── CHANGELOG.md
├── README.md
└── AGENTS.md
```

## Directory Purposes

**Sources/Glitcho/:**
- Purpose: All application source code
- Contains: 19 Swift files, primarily SwiftUI Views and Manager classes
- Key files: App.swift (entry), ContentView.swift (main UI), WebViewStore.swift (web layer), StreamlinkPlayer.swift (playback), RecordingManager.swift (recording)

**Tests/:**
- Purpose: Unit and integration tests
- Contains: 3 test files covering RecordingManager, NativeVideoPlayer gestures, and smoke tests
- Key files: RecordingManagerTests.swift (most comprehensive)

**Resources/:**
- Purpose: Static assets
- Contains: AppIcon.iconset with app icons at multiple resolutions

**Scripts/:**
- Purpose: Build automation
- Contains: make_app.sh (compiles, creates app bundle, configures Info.plist)

**Build/:**
- Purpose: Build output (generated, not committed)
- Contains: Glitcho.app (final executable app bundle)

## Key File Locations

**Entry Points:**
- `Sources/Glitcho/App.swift`: @main app definition, creates TwitchGlassApp, sets up WindowGroup with ContentView
- `Sources/Glitcho/NonSwiftUIMain.swift`: Legacy non-SwiftUI entry point (not currently used)

**Configuration:**
- `Package.swift`: Swift package manifest, platforms, dependencies, target definitions
- `Scripts/make_app.sh`: Build configuration (APP_VERSION, APP_BUILD, LSMinimumSystemVersion)
- `Sources/Glitcho/SettingsView.swift`: User-facing settings for Streamlink/FFmpeg paths, recording directory, notification prefs

**Core Logic:**
- `Sources/Glitcho/ContentView.swift`: Main view controller logic, state management, mode switching (web/native/recordings)
- `Sources/Glitcho/WebViewStore.swift`: WKWebView setup, all JavaScript injection, message handling, Following/profile extraction
- `Sources/Glitcho/StreamlinkPlayer.swift`: Streamlink URL resolution, AVPlayer integration
- `Sources/Glitcho/RecordingManager.swift`: Recording control, file I/O, Streamlink/FFmpeg installation/invocation

**UI Components:**
- `Sources/Glitcho/RecordingsLibraryView.swift`: Recordings list, playback, deletion
- `Sources/Glitcho/NotificationManager.swift`: macOS notification delivery
- `Sources/Glitcho/UpdateChecker.swift`: GitHub API polling, update prompts
- `Sources/Glitcho/DetachedChatView.swift`: Floating chat window
- `Sources/Glitcho/UpdatePromptView.swift`, `UpdateStatusView.swift`: Update UI

**Data Models:**
- `Sources/Glitcho/PinnedChannel.swift`: Codable struct for pinned channels, persisted via JSON in UserDefaults
- `Sources/Glitcho/WebViewStore.swift`: TwitchChannel, NativePlaybackRequest, TwitchProfile (inline structs)

**Testing:**
- `Tests/RecordingManagerTests.swift`: Tests for RecordingManager methods (path resolution, file detection, process invocation)
- `Tests/NativeVideoPlayerGestureTests.swift`: Tests for gesture handling in video player
- `Tests/GlitchoTests.swift`: Smoke tests

## Naming Conventions

**Files:**
- PascalCase for all Swift files (e.g., `ContentView.swift`, `RecordingManager.swift`)
- Descriptive names indicating content type (View, Manager, Controller)
- No underscore separators; compound words are concatenated

**Directories:**
- `Sources/Glitcho`: All source code in one flat directory (no subdirectories)
- `Tests`: All tests at top level (no subdirectories)
- `Resources`: Asset folders with descriptive names (e.g., `AppIcon.iconset`)

**Swift Types (Classes, Structs, Enums):**
- PascalCase (e.g., `ContentView`, `RecordingManager`, `PinnedChannel`)
- Manager suffix for orchestrator classes (e.g., `RecordingManager`, `StreamlinkManager`)
- View suffix for SwiftUI views (e.g., `ContentView`, `SettingsView`)
- Controller suffix for AppKit controllers (e.g., `PictureInPictureController`)

**Properties & Methods:**
- camelCase for properties and methods
- Underscores for private properties indicating internal state: `_resolveFFmpegPathOverride`, `_webView`
- Function names are imperative verbs: `startRecording()`, `toggleRecording()`, `navigateTo()`

**Constants:**
- UPPER_SNAKE_CASE for module-level constants (in Scripts/make_app.sh): `APP_VERSION`, `APP_BUILD`
- camelCase for static properties inside types: `Self.safariUserAgent`, `Self.initialHideScript`

## Where to Add New Code

**New Feature (Playback Enhancement, e.g., Quality Selection):**
- Primary code: `Sources/Glitcho/StreamlinkPlayer.swift`
- UI: Add button/selector to `Sources/Glitcho/StreamlinkPlayer.swift` NativeVideoPlayer view or ContentView
- Tests: `Tests/VideoPlayerFeatureTests.swift` (new file if feature is substantial)

**New Component/Module (e.g., Chat Integration):**
- Implementation: `Sources/Glitcho/ChatIntegrationManager.swift` (new file)
- UI View: `Sources/Glitcho/ChatView.swift` (new file)
- State: Integrate into ContentView or create via @StateObject
- Tests: `Tests/ChatIntegrationTests.swift` (new file)

**Utilities (Helper Functions, Extensions):**
- Shared helpers: `Sources/Glitcho/Utilities.swift` (new file) or add as extensions to existing types
- Example: URL validation, string parsing helpers
- Keep in same file if used by only one type; extract to Utilities if used across multiple files

**Settings/Preferences:**
- New setting key: Add @AppStorage property to `Sources/Glitcho/SettingsView.swift`
- Default value: Store in @AppStorage declaration or UserDefaults.standard
- UI control: Add to `SettingsViewContent` or create new settings section in SettingsView

**New Window/Dialog:**
- Define: New View struct in `Sources/Glitcho/App.swift` or dedicated file (e.g., `Sources/Glitcho/AboutView.swift`)
- Register: Add Window or WindowGroup to TwitchGlassApp.body
- Integration: Create open button in existing view, pass through @Environment(\.openWindow)

## Special Directories

**Build/:**
- Purpose: Generated app bundle
- Generated: Yes (by Scripts/make_app.sh)
- Committed: No
- Management: Regenerated on each build; .gitignore should exclude

**.build/:**
- Purpose: SPM build cache
- Generated: Yes (by swift build)
- Committed: No
- Management: Ignored by .gitignore

**Resources/AppIcon.iconset/:**
- Purpose: App icon images at multiple resolutions (required by macOS)
- Contents: .png files at 16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024 (and @2x variants)
- Committed: Yes
- Management: Maintain resolution consistency; update when changing app appearance

## Code Organization Principles

1. **Single file per major type**: Each manager class (RecordingManager, StreamlinkManager, WebViewStore) is in its own file.

2. **View hierarchy in ContentView**: Main layout views (Sidebar, PinnedRow, FollowingRow, etc.) are defined inline within ContentView.swift or in dedicated small files.

3. **No subdirectories under Sources/Glitcho**: All Swift files are at the same level for simplicity. Flat structure works well for small-to-medium projects.

4. **Inline utilities in host file**: Helper methods are kept in the file that primarily uses them (e.g., `isTransportStreamFile()` in RecordingManager).

5. **Environment keys for global state**: Shared services like NotificationManager are injected via @Environment key (see `Environment+NotificationManager.swift`).

6. **Tests alongside source**: Test files are in Tests/ directory with clear naming to match source files (RecordingManagerTests.swift → RecordingManager.swift).

---

*Structure analysis: 2026-02-04*
