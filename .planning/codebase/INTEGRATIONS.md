# External Integrations

**Analysis Date:** 2026-02-04

## APIs & External Services

**Twitch:**
- Primary service: Twitch video streaming platform
  - Integration: Embedded WKWebView loading `https://www.twitch.tv`
  - Authentication: Web-based OAuth (handled by Twitch web interface)
  - Data scraped: Channel information, followed channels list, user profile, notifications
  - JavaScript injection: Custom fetch override for ad blocking, DOM manipulation for UI simplification
  - Chat integration: `DetachedChatView` renders embedded chat in separate window

**GitHub API:**
- Release information for auto-updates
  - Endpoint: `https://api.github.com/repos/Jencryzthers/glitcho/releases/latest`
  - Implementation: `UpdateChecker` class in `Sources/Glitcho/UpdateChecker.swift`
  - Auth: User-Agent header with app version (`Glitcho/X.Y.Z`)
  - Polling: Once per app session (cached via `hasChecked` flag), or on-demand via Settings menu
  - Headers: Accept `application/vnd.github+json`

## Stream Processing

**Streamlink:**
- CLI tool for extracting HLS stream URLs and ad-blocking
  - Installation: Downloaded via `RecordingManager.installStreamlink()` to system
  - Default path resolution: `/opt/homebrew/bin/streamlink` (Homebrew) or system `$PATH`
  - Custom path: Configurable via Settings > Recording (stored in `UserDefaults` key `streamlinkPath`)
  - Command arguments:
    ```
    streamlink <target> <quality> --stream-url --twitch-disable-ads --twitch-low-latency
    ```
  - Used by: `StreamlinkManager` (URL extraction) and `StreamlinkRecorder` (recording)

**FFmpeg:**
- Video encoder for recording streams to MP4 format
  - Installation: Downloaded via `RecordingManager.installFFmpeg()` to system
  - Default path resolution: System `$PATH` lookup for `ffmpeg`
  - Custom path: Configurable via Settings > Recording (stored in `UserDefaults` key `ffmpegPath`)
  - Purpose: Transcoding and muxing stream data to playable MP4 files
  - Invoked by: Streamlink command pipeline during recordings

## Data Storage

**Recordings:**
- File storage: Local filesystem
  - Default location: `~/Downloads/Glitcho Recordings/`
  - Custom location: Configurable via Settings > Recording
  - Stored in: `UserDefaults` key `recordingsDirectory`
  - Format: MP4 (video/audio codec handled by Streamlink/FFmpeg)
  - Filename pattern: `{channel_name}_{YYYY-MM-dd_HH-mm-ss}.mp4`

**User Preferences:**
- Storage: `UserDefaults.standard` (macOS user defaults system)
  - Keys used:
    - `streamlinkPath` - Custom Streamlink binary path
    - `ffmpegPath` - Custom FFmpeg binary path
    - `recordingsDirectory` - Custom recordings directory path
    - `pinnedChannels` - Archived channel bookmarks (JSON-encoded `PinnedChannel` objects)
    - Channel-specific notification toggles

**Application Cache:**
- WKWebView data store: `WKWebsiteDataStore.default()`
  - Caches Twitch web content (cookies, localStorage, sessionStorage)
  - User login session persisted across app launches
  - Managed automatically by WebKit

## Playback Pipeline

**Native Playback:**
- Technology: AVPlayer with custom SwiftUI wrapper
  - URL source: Extracted via Streamlink from HLS playlists
  - Component: `NativeVideoPlayer` in `Sources/Glitcho/StreamlinkPlayer.swift`
  - Gesture support: Zoom, pan, fullscreen, picture-in-picture
  - Backend: QuartzCore (CATransaction) for layer manipulation

**Streaming Formats:**
- HLS (HTTP Live Streaming) - Primary format from Twitch
  - Qualities: Best, high, medium, low, audio only (Streamlink resolution options)
  - Low-latency mode: Enabled via `--twitch-low-latency` flag

## Authentication & Identity

**Authentication:**
- Method: Web-based OAuth via Twitch
  - Implementation: Handled entirely by WKWebView loading `https://www.twitch.tv`
  - Session persistence: WebKit data store maintains login session
  - No app-level token management

**User Profile:**
- Extraction: DOM scraping from Twitch web interface
  - Scraped fields: `profileName`, `profileLogin`, `profileAvatarURL`, `isLoggedIn`
  - Implementation: JavaScript injection in `WebViewStore.profileScript`
  - Communication: WKScriptMessageHandler with message name `"profile"`

## Webhooks & Callbacks

**Outgoing:**
- None. The app is read-only with respect to external services.

**Incoming:**
- None. No webhook receivers implemented.

**URL Schemes:**
- Custom chat windows: `ChatWindowContext` deep linking
- PayPal integration: `https://www.paypal.com/paypalme/jcproulx` (external link only)

## Monitoring & Observability

**Error Tracking:**
- None. No external error reporting service.
- Errors logged to console via `print()` statements

**Logs:**
- Destination: macOS console output (Console.app)
- Key log sources:
  - `[Streamlink]` prefix for stream extraction errors
  - `[RecordingManager]` prefix for recording status
  - Update checker status messages

## CI/CD & Deployment

**Hosting:**
- Distribution: GitHub Releases (manual publishing)
  - Repository: `Jencryzthers/glitcho`
  - Release format: ZIP-packaged `.app` bundle as `Glitcho-vX.Y.Z-macOS.zip`

**Build Pipeline:**
- No automated CI/CD
- Manual build via `Scripts/make_app.sh` on developer machine
- Ad-hoc code signing (no provisioning profiles or certificates required)

**Binary Downloads:**
- FFmpeg: Downloaded from system package managers or official source (triggered from Settings UI)
- Streamlink: Downloaded from system package managers or official source (triggered from Settings UI)
- Auto-update: Directs user to GitHub Releases page to download new versions

## Network Configuration

**Required Network Access:**
- `https://www.twitch.tv` - Twitch web application
- `https://api.github.com` - GitHub API for release information
- HLS stream URLs - Direct streaming from Twitch CDN
- Streamlink/FFmpeg downloads - First-time setup only (user-triggered)

**DNS Resolution:**
- Standard system DNS resolution via Foundation `URLSession`

**Certificates & TLS:**
- Uses system certificate trust anchors
- No custom certificate pinning

## Environment Configuration

**Critical Environment Variables:**
- None required for normal operation
- Optional: `$PATH` for Streamlink and FFmpeg discovery if not in default locations

**Secrets Location:**
- None. No API keys or secrets required.
- Twitch authentication handled by web OAuth (session in browser cookies)

**Configuration Files:**
- None. All settings via `UserDefaults` and UI

---

*Integration audit: 2026-02-04*
