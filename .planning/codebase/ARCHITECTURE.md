# Architecture

**Analysis Date:** 2026-02-04

## Pattern Overview

**Overall:** SwiftUI-based macOS client with dual-layer web integration. The app bridges browser automation (WKWebView for Twitch) with native playback (AVPlayer via Streamlink).

**Key Characteristics:**
- Web-first approach for account management and navigation, but native-first for media playback
- DOM manipulation and JavaScript injection for UI customization and data extraction
- Process-based external tool management (Streamlink for streams, FFmpeg for remuxing)
- Observable state propagation through SwiftUI environment and AppStorage
- Separation of concerns: web layer handles login/browsing, native layer handles playback/recording

## Layers

**Presentation (SwiftUI Views):**
- Purpose: Render UI and handle user interactions
- Location: `Sources/Glitcho/` (all `.swift` files except utility/manager classes)
- Contains: ContentView, Sidebar, player views, settings dialogs, recordings library
- Depends on: RecordingManager, WebViewStore, UpdateChecker, NotificationManager
- Used by: App entry point, WindowGroup

**Web Integration Layer:**
- Purpose: Load Twitch in WKWebView, inject styling/scripts, extract profile/live list data
- Location: `Sources/Glitcho/WebViewStore.swift`
- Contains: WKWebView setup, JavaScript injection (12 separate user scripts), message handlers, navigation policy
- Depends on: WebKit, Foundation
- Used by: ContentView (for browsing), Sidebar (for following list and profile data)

**Playback Layer:**
- Purpose: Resolve stream URLs via Streamlink and play via AVPlayer
- Location: `Sources/Glitcho/StreamlinkPlayer.swift`
- Contains: StreamlinkManager (runs Streamlink process), NativeVideoPlayer (wraps AVPlayerViewController)
- Depends on: AVKit, Foundation, Process APIs
- Used by: ContentView (NativePlaybackRequest handling)

**Recording & File Management Layer:**
- Purpose: Record streams via Streamlink, manage file organization, remux MPEG-TS to MP4
- Location: `Sources/Glitcho/RecordingManager.swift`
- Contains: Recording orchestration, file management, Streamlink/FFmpeg installation logic, MPEG-TS detection
- Depends on: Foundation, Process APIs, UserDefaults
- Used by: ContentView, SettingsView

**Utility & Support:**
- Purpose: Notifications, update checking, UI helpers, environment configuration
- Location: Multiple files (UpdateChecker, NotificationManager, PictureInPictureController, etc.)
- Depends on: Notification framework, URLSession, various AppKit components
- Used by: App, ContentView, SettingsView

## Data Flow

**User Login & Profile Retrieval:**
1. User navigates to Twitch login page in WebView
2. JavaScript `profileScript` runs at document end, extracts user info from DOM/cookies/localStorage
3. Profile data sent via WKScriptMessageHandler to `WebViewStore.profileScript` message
4. `WebViewStore` publishes @Published properties: `isLoggedIn`, `profileName`, `profileLogin`, `profileAvatarURL`
5. Sidebar reads these Published properties and updates UI

**Live Channels Detection & Notifications:**
1. Background WKWebView loads `https://www.twitch.tv/following` on login
2. JavaScript `followedLiveScript` extracts live channel cards every 5 seconds
3. Data sent via WKScriptMessageHandler to `WebViewStore`
4. `WebViewStore` publishes `followedLive` array
5. ContentView observes change, calls `handleFollowedLiveChange()`:
   - Filters new live channels
   - Sends notifications if enabled
   - Triggers auto-recording if configured
6. Sidebar renders live channels with indicators

**Native Playback Trigger:**
1. User clicks channel in sidebar or navigates to channel URL in web view
2. URL change observed in WebViewStore (either through navigation or SPA route change)
3. `nativePlaybackRequestIfNeeded()` determines if URL is playable (channel root, VOD, clip)
4. Creates `NativePlaybackRequest` with `kind`, `streamlinkTarget`, `channelName`
5. Sets `shouldSwitchToNativePlayback` published property
6. ContentView observes change, switches `detailMode` to `.native`
7. `HybridTwitchView` renders with NativeVideoPlayer
8. NativeVideoPlayer creates StreamlinkManager task:
   - Calls `getStreamURL(target:quality:)` which spawns Streamlink process
   - Streamlink outputs direct HLS/DASH playlist URL
   - AVPlayerViewController displays video
9. User stops viewing, detail mode switches back to `.web`, WebView resumes normal playback

**Recording Session:**
1. User clicks record button or auto-record triggers
2. `RecordingManager.startRecording()` called with target and channel name
3. Verifies Streamlink availability, creates recordings directory
4. Spawns Process running: `streamlink [target] [quality] --twitch-disable-ads --output [file.mp4]`
5. Sets `isRecording = true`, displays recording badge
6. Process runs asynchronously; stderr piped for error handling
7. On process termination:
   - Sets `isRecording = false`
   - Calls `prepareRecordingForPlayback()` if successful
8. `prepareRecordingForPlayback()` checks if file is MPEG-TS (by sync byte pattern)
9. If needed, spawns FFmpeg: `ffmpeg -i [input.ts] -c copy -movflags +faststart [output.mp4]`
10. Atomically replaces original with remuxed MP4
11. Cleanup and error handling

**Recording Playback:**
1. RecordingsLibraryView reads recordings directory via `recordingManager.listRecordings()`
2. Parses filenames to extract channel name and timestamp
3. User selects recording to play
4. NativeVideoPlayer displays with AVPlayer (no Streamlink needed—local file)

## Key Abstractions

**NativePlaybackRequest:**
- Purpose: Encapsulates a request to play media (live channel, VOD, or clip)
- Location: `Sources/Glitcho/WebViewStore.swift` (struct definition)
- Pattern: Value type passed through @Published property changes
- Contains: `kind` (enum), `streamlinkTarget` (URL string), `channelName` (optional)

**PinnedChannel:**
- Purpose: Represents a user-pinned favorite channel with notification preferences
- Location: `Sources/Glitcho/PinnedChannel.swift`
- Pattern: Codable struct for persistence via JSON encoding in UserDefaults
- Contains: login, displayName, thumbnailURL, notifyEnabled, pinnedAt

**TwitchChannel:**
- Purpose: Represents a live channel extracted from web DOM
- Location: `Sources/Glitcho/WebViewStore.swift` (struct definition)
- Pattern: Lightweight value type, Identifiable for SwiftUI lists
- Contains: id (URL string), name, url, thumbnailURL

**RecordingEntry:**
- Purpose: Represents a single recorded file on disk
- Location: `Sources/Glitcho/RecordingManager.swift` (struct definition)
- Pattern: Parsed from filename; recordedAt optional for malformed names
- Contains: url, channelName, recordedAt (Date)

## Entry Points

**App Initialization:**
- Location: `Sources/Glitcho/App.swift`
- Triggers: macOS launches app
- Responsibilities: Create TwitchGlassApp, set up StateObjects (UpdateChecker, NotificationManager), configure window groups (main, settings, about, chat)

**Content View:**
- Location: `Sources/Glitcho/ContentView.swift`
- Triggers: App body renders WindowGroup
- Responsibilities: Manage overall UI layout (sidebar + detail split view), handle mode switching (web/native/recordings), coordinate state between components

**WebViewStore Initialization:**
- Location: `Sources/Glitcho/WebViewStore.swift` init
- Triggers: ContentView creates @StateObject
- Responsibilities: Set up WKWebView with config, inject all user scripts, configure message handlers, start background Following page loader, set up KVO observers for navigation

## Error Handling

**Strategy:** Multi-level fallback with user-facing messaging.

**Patterns:**
- **Streamlink Missing:** RecordingManager checks multiple paths (custom path, bundled, homebrew, usr/local, usr/bin); if all fail, shows error in UI with button to install or set custom path
- **FFmpeg Missing:** Similar fallback chain; remuxing fails gracefully with user notification
- **Recording Process Error:** Captures stderr from terminated process, displays error message with command context
- **Stream URL Resolution:** StreamlinkManager catches Process errors and throws localized NSError with stderr output
- **JavaScript Injection Errors:** Silent failures; if profile extraction fails, user remains unauthenticated visually but can still browse web view

## Cross-Cutting Concerns

**Logging:** Printf-style logging via `print()` and `debug()` statements; tagged logs like `[Streamlink]`, `[Enhanced Adblock]`, `[Purple Adblock]` in JavaScript. No external logging framework.

**Validation:**
- Channel login: normalized (lowercased, trimmed, `@` prefix removed)
- Recording filenames: sanitized spaces to underscores, validated against filesystem
- URLs: normalized to HTTPS, checked for Twitch domain before switching to native playback

**Authentication:**
- Handled entirely by Twitch web view (OAuth redirect flow)
- App never stores credentials; relies on WKWebView cookie/session management
- Logout clears all website data (WKWebsiteDataStore) and resets UI state

**Performance:**
- WKWebView runs on main thread (required by AppKit)
- Streamlink process runs on background queue or as async Process with completion handler
- Following list updates every 2 minutes via background timer
- JavaScript extraction (profile, following, ads) runs at document lifecycle points

**State Persistence:**
- User preferences via UserDefaults (@AppStorage): pinnedChannelsJSON, liveAlertsEnabled, sidebarTint, recordingsDirectory, paths to Streamlink/FFmpeg
- App-only state (temporary): currentPlaybackRequest, detailMode, showSettingsModal
- No network requests to backend; all data from Twitch web view

---

*Architecture analysis: 2026-02-04*
