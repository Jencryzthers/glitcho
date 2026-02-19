# Technology Stack

**Analysis Date:** 2026-02-13

## Languages

- Swift 5.9+ (application and tests)
- JavaScript/CSS/HTML snippets (Twitch DOM scraping + style injection in `WKWebView`)
- Bash (build and operational scripts)
- Node.js (reference activation server and startup key tooling)

## Package and Runtime

- Swift Package Manager (`Package.swift`)
- Products:
  - `Glitcho` (macOS executable)
  - `GlitchoRecorderAgent` (helper executable)
- Declared platform target: macOS 13 (`Package.swift`)
- Bundle packaging script: `Scripts/make_app.sh`

Note:
- `Scripts/make_app.sh` currently writes `LSMinimumSystemVersion` as `26.0` in bundle `Info.plist`, which is stricter than package platform declaration.

## Apple Frameworks

- UI/App shell: `SwiftUI`, `AppKit`
- Web embedding/scraping: `WebKit`
- Playback/media: `AVKit`, `AVFoundation`, `CoreMedia`, `QuartzCore`
- Notifications: `UserNotifications`
- Core runtime: `Foundation`
- Security/persistence helpers: Security APIs via `KeychainHelper` abstraction
- Telemetry/logging: `OSLog`

## External Tooling

- `streamlink`:
  - Live playback URL resolution
  - Recording capture process
  - Configurable path from settings (`streamlinkPath`)
- `ffmpeg` (optional):
  - Recording post-processing/remux workflows
  - Configurable path from settings (`ffmpegPath`)
- Docker + Compose:
  - Local licensing activation service deployment (`deploy/license-server`)
- `openssl`, `node`, `curl`:
  - Required by activation server startup automation

## Persistence and Configuration

- `UserDefaults` / `@AppStorage` for UI and feature settings:
  - recording scope/allowlist/blocklist/debounce/cooldown/concurrency
  - retention policy
  - player/motion/upscale/aspect options
  - companion API config
- Keychain-backed helpers for sensitive license material paths.
- Filesystem storage for recordings and exported files.
- Local launchd plist + logs for background recorder agent.

## Build and Release

- Build/package:
  - `./Scripts/make_app.sh`
  - Produces `Build/Glitcho.app`
- App metadata in script:
  - `APP_VERSION=1.3.0`
  - `APP_BUILD=130`
- Ad-hoc codesign and quarantine removal are applied by script.

## Scope

- macOS only.
- iOS/iPadOS source scaffold and IPA build scripts are removed from repo.
