# Glitcho

Glitcho is a macOS-native Twitch client built with SwiftUI and AVKit. It combines a focused Twitch browsing experience with native playback, DVR-style recording controls, a background recorder agent, and advanced video enhancement features.

You can also view more information : https://glitcho.devjc.net

## Scope

- macOS app (SwiftPM) only.
- iOS/iPadOS scaffold and IPA tooling have been removed from this repo.
- Includes a separate Docker-hosted promo website (`apps/commerce`) for app showcase, download, and donation.

## Core Features

### Playback and Streamer Experience
- Native player pipeline (`Streamlink` -> `AVPlayer`), with in-player overlay controls.
- Player zoom/pan, Picture in Picture, native player fullscreen, and chat collapse/popout controls.
- Shared overlay behavior for both live streams and local recording playback.
- Streamer details tabs with native rendering:
  - `About`
  - `Videos`
  - `Schedule`
- Collapsible details panel under the player (`About / Videos / Schedule`) with persistent state.
- About panel scraper converts hyperlink images to tappable native image cards.

### Recording
- Start/stop confirmation flows.
- Auto-record modes:
  - Only pinned
  - Only followed
  - Pinned + followed
  - Custom allowlist
- Blocklist override support.
- Debounce/cooldown and concurrency limit support.
- Background recorder LaunchAgent support with restart/kill controls and status feedback.

### Recordings Library
- Search, sort, list/grid, and optional grouping by streamer.
- Multi-select actions.
- Bulk delete with confirmation.
- Bulk export with progress and failure reporting.
- Retention policies:
  - Max age (days)
  - Keep last N globally
  - Keep last N per channel

### Video Enhancements
- Motion smoothening (target refresh based on display capability, up to 120Hz).
- 4K upscaler toggle.
- Image optimize pipeline and tuning controls (contrast, lighting, denoiser, neural clarity).
- Aspect crop modes (`Source`, `21:9`, `32:9`).

### Companion API
- Local HTTP endpoint for remote automation/control.
- Optional bearer token auth.
- Endpoints include health/status and recording control APIs.

## Preview Pictures

![promo-4-1280](https://github.com/user-attachments/assets/1fdea339-ca5f-4380-9906-cca97339ffae)
![promo-2-1280](https://github.com/user-attachments/assets/5ef17ec8-c136-411d-8e3a-b49f888571a4)
![promo-1-1280](https://github.com/user-attachments/assets/1deb5e3b-fb68-4fa4-a42b-3f1feeb5d63f)

## Requirements

- macOS 13+ (Swift package target).
- Xcode Command Line Tools / Swift 5.9+.
- Network access for Twitch.
- `Streamlink` for native playback/recording (installable from app settings).
- Optional `FFmpeg` for remuxing transport-stream recordings for playback.

## Build and Run

```bash
./Scripts/make_app.sh
open Build/Glitcho.app
```

Output app bundle:
- `Build/Glitcho.app`

## Install Release Build

1. Download latest zip release.
2. Unzip and move `Glitcho.app` to `/Applications`.
3. If Gatekeeper blocks launch:

```bash
xattr -dr com.apple.quarantine /Applications/Glitcho.app
```

## First-Run Setup

1. Launch app and sign in to Twitch.
2. Open `Settings`:
   - Configure `Streamlink` (and optionally `FFmpeg`).
3. Pick channels from sidebar/following and start playback.

## Scripts

- `Scripts/make_app.sh`
  - Build and package `Glitcho.app` + bundled `GlitchoRecorderAgent`.
- `Scripts/start_commerce_site.sh`
  - Boot Dockerized promo/download website (`/` + `/download`).
- `Scripts/stop_commerce_site.sh`
  - Stop Dockerized commerce website stack.
- `Scripts/profile_recording_runtime.sh`
  - Capture CPU/RAM/process-count baseline and after-fix recording metrics.

## Docs

- `docs/commerce-site.md` - commerce website setup, endpoints, and operations guide.
- `docs/perf/recording-profiling.md` - performance profiling workflow.
- `docs/plans/2026-02-12-dvr-phase0-kickoff.md` - DVR phase plan and status snapshot.

## High-Level Architecture

- `Sources/Glitcho/ContentView.swift`
  - Main split view, sidebar, routing, toasts, recording-control dialogs.
- `Sources/Glitcho/WebViewStore.swift`
  - Twitch web integration, DOM scraping, sidebar/live/profile synchronization.
- `Sources/Glitcho/StreamlinkPlayer.swift`
  - Native player, overlay controls, About/Videos/Schedule native rendering pipeline.
- `Sources/Glitcho/RecordingManager.swift`
  - Recording lifecycle, retention enforcement, Streamlink/FFmpeg tooling.
- `Sources/Glitcho/RecorderOrchestrator.swift`
  - Per-channel recording job states and retry metadata.
- `Sources/Glitcho/BackgroundRecorderAgentManager.swift`
  - LaunchAgent install/sync/restart/kill lifecycle.
- `Sources/Glitcho/RecordingsLibraryView.swift`
  - Recording library UI, bulk actions, export workflow.
- `Sources/Glitcho/CompanionAPIServer.swift`
  - Local automation API runtime.
- `Sources/Glitcho/MotionInterpolation.swift`
  - Motion/interpolation render path and runtime telemetry publication.

## Troubleshooting

- Stream not loading:
  - Verify channel is live.
  - Confirm `Streamlink` path in `Settings -> Recording Tools`.
- Recording playback conversion issues:
  - Configure `FFmpeg` binary in settings.
- Companion API not reachable:
  - Verify enabled state, port, and token in settings.

## Privacy and Telemetry

- App telemetry uses local `OSLog` event logging (`GlitchoTelemetry`) for diagnostics.
- Twitch web content remains subject to Twitch policies.
- No third-party analytics SDK is bundled in this repo.

## Legal

Glitcho is unofficial and not affiliated with Twitch Interactive, Inc. or Amazon.com, Inc. Twitch trademarks/content remain property of their owners.

## License

MIT License for this codebase.
