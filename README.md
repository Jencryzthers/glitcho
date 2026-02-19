# Glitcho

Glitcho is a macOS-native Twitch client built with SwiftUI and AVKit. It combines a focused Twitch browsing experience with native playback, DVR-style recording controls, a background recorder agent, and license-gated Pro video enhancement features.

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

### Recording (Pro)
- License-gated recording with start/stop confirmation flows.
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

### Pro Video Enhancements
- Motion smoothening (target refresh based on display capability, up to 120Hz).
- 4K upscaler toggle.
- Image optimize pipeline and tuning controls (contrast, lighting, denoiser, neural clarity).
- Aspect crop modes (`Source`, `21:9`, `32:9`).

### Licensing and Entitlement
- Recording and Pro enhancement gating via license validation.
- Server-side validation endpoint (`POST /license/validate`).
- Local entitlement cache + offline grace fallback.
- Optional P256 signature verification (public key in app settings).
- Optional standalone promo website with:
  - Landing page with app screenshots
  - Download page and `.zip` distribution flow
  - Donation link (`paypal.me/jcproulx`)

### Companion API
- Local HTTP endpoint for remote automation/control.
- Optional bearer token auth.
- Endpoints include health/status and recording control APIs.

## Requirements

- macOS 13+ (Swift package target).
- Xcode Command Line Tools / Swift 5.9+.
- Network access for Twitch and optional license validation.
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
2. On first open, Glitcho shows a license popup with:
   - `Email for Pro license key` (opens mail app to contact support)
   - `I already have a key` (opens license settings flow)
3. Open `Settings`:
   - Configure `Streamlink` (and optionally `FFmpeg`).
   - Enter license key for recording/Pro features.
4. Pick channels from sidebar/following and start playback.

## Scripts

- `Scripts/make_app.sh`
  - Build and package `Glitcho.app` + bundled `GlitchoRecorderAgent`.
- `Scripts/start_activation_server.sh`
  - Boot Dockerized license validation server and generate public key output.
- `Scripts/stop_activation_server.sh`
  - Stop Dockerized license server.
- `Scripts/start_commerce_site.sh`
  - Boot Dockerized promo/download website (`/` + `/download` + `/license/validate` endpoint).
- `Scripts/stop_commerce_site.sh`
  - Stop Dockerized commerce website stack.
- `Scripts/license_server_example.mjs`
  - Reference standalone validation server implementation.
- `Scripts/profile_recording_runtime.sh`
  - Capture CPU/RAM/process-count baseline and after-fix recording metrics.

## Docs

- `docs/licensing-server.md` - license server deployment/validation reference.
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
- `Sources/Glitcho/LicenseManager.swift`
  - License key storage, validation, signature verification, offline grace.
- `Sources/Glitcho/CompanionAPIServer.swift`
  - Local automation API runtime.
- `Sources/Glitcho/MotionInterpolation.swift`
  - Motion/interpolation render path and runtime telemetry publication.

## Troubleshooting

- Stream not loading:
  - Verify channel is live.
  - Confirm `Streamlink` path in `Settings -> Recording Tools`.
- Recording unavailable:
  - Validate license in `Settings -> Pro License`.
- Recording playback conversion issues:
  - Configure `FFmpeg` binary in settings.
- Companion API not reachable:
  - Verify enabled state, port, and token in settings.
- License signature invalid:
  - Ensure app public key matches server signing key raw P256 public key (Base64).

## Privacy and Telemetry

- App telemetry uses local `OSLog` event logging (`GlitchoTelemetry`) for diagnostics.
- Twitch web content remains subject to Twitch policies.
- No third-party analytics SDK is bundled in this repo.

## Legal

Glitcho is unofficial and not affiliated with Twitch Interactive, Inc. or Amazon.com, Inc. Twitch trademarks/content remain property of their owners.

## License

MIT License for this codebase.
