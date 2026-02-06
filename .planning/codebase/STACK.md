# Technology Stack

**Analysis Date:** 2026-02-04

## Languages

**Primary:**
- Swift 5.9+ - All source code
- HTML/CSS/JavaScript - Embedded in WKWebView for Twitch styling and ad blocking

**Secondary:**
- Bash - Build scripts (`Scripts/make_app.sh`)

## Runtime

**Environment:**
- macOS 13.0+ (as specified in `LSMinimumSystemVersion` in `Package.swift`)
- Apple Silicon (arm64) and Intel (x86_64) architecture support

**Package Manager:**
- Swift Package Manager (SPM) - Native Swift dependency management
- Lockfile: Not used (no external package dependencies)

## Frameworks

**Core UI/App:**
- SwiftUI - Primary UI framework for the entire application
- AppKit - macOS-specific APIs for window management and app integration

**Playback & Media:**
- AVKit - Video player wrapper and display components
- AVFoundation - Low-level media framework for AVPlayer and AVPlayerLayer
- QuartzCore - Core Animation for layer transformations and visual effects

**Web Integration:**
- WebKit (WKWebView) - Embedded Twitch web browser with custom styling and JavaScript injection

**System Integration:**
- UserNotifications - Desktop notifications for recording status and channel notifications
- Foundation - Core framework for networking, file I/O, and utilities

**Build/Dev:**
- Swift Build System - Standard Swift package build tool
- Xcode Command Line Tools - Required for Swift compilation and code signing

## Key Dependencies

**No External Package Dependencies**
- The project has zero external dependencies beyond Apple frameworks
- All functionality is built using native macOS and Swift frameworks
- This is intentional for simplicity, security, and maintainability

**External Binaries Used:**
- Streamlink - Third-party CLI tool for Twitch stream URL extraction and media processing
  - Downloaded at runtime from Settings > Recording
  - Path resolution: `~/.streamlink/bin/streamlink` or system PATH
  - Custom path configurable via `UserDefaults` (key: `streamlinkPath`)

- FFmpeg - External tool for video transcoding and recording
  - Downloaded at runtime from Settings > Recording
  - Used by Streamlink for recording streams to MP4 format
  - Path resolution: system PATH or custom via `UserDefaults` (key: `ffmpegPath`)

## Configuration

**Environment:**
- Settings stored in `UserDefaults.standard` for user preferences:
  - `streamlinkPath` - Custom Streamlink binary location
  - `ffmpegPath` - Custom FFmpeg binary location
  - `recordingsDirectory` - Custom directory for saved recordings
  - `pinnedChannels` - Persisted channel bookmarks
  - Notification preferences for followed channels

**Build:**
- `Package.swift` - Swift Package manifest defining targets, platforms, and resources
- `Scripts/make_app.sh` - Build and packaging script
  - Creates `.app` bundle structure
  - Generates `Info.plist` with version and identifiers
  - Code signs the app bundle (ad-hoc signing)
  - Removes quarantine attributes for distribution

**Version Management:**
- Version: `APP_VERSION=1.0.4` in `Scripts/make_app.sh`
- Build: `APP_BUILD=104` in `Scripts/make_app.sh`
- Exposed in app via `CFBundleShortVersionString` and `CFBundleVersion`

## Platform Requirements

**Development:**
- Xcode Command Line Tools (includes Swift 5.9+)
- macOS 13.0 or later for building

**Production:**
- macOS 13.0 or later (Ventura or newer)
- Network access for:
  - Twitch streaming (requires internet connection)
  - GitHub API for update checking
  - FFmpeg/Streamlink downloads (first-time setup)

**macOS Features Used:**
- Window management (`WindowGroup`, `Window`)
- Visual effects (`VisualEffectView`, blur, vibrancy)
- Process execution via `Foundation.Process` for Streamlink/FFmpeg
- File system access for recordings directory
- Gesture handling via `NSGestureRecognizer` subclasses

## Build Output

- **Executable:** `Glitcho` (Swift binary)
- **App Bundle:** `Build/Glitcho.app` (macOS application bundle)
- **Code Signing:** Ad-hoc signing with `-` identity
- **Distribution:** ZIP-packaged `.app` bundle for releases

---

*Stack analysis: 2026-02-04*
