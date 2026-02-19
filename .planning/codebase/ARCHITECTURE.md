# Architecture

**Analysis Date:** 2026-02-13

## Overview

Glitcho is a macOS-only SwiftUI app with a hybrid Twitch architecture:
- `WKWebView` for Twitch auth/session and scraped metadata.
- Native AVKit playback driven by Streamlink.
- A local recording/runtime subsystem with orchestration, retention, and background agent management.
- Optional Pro-licensed video enhancement and companion control APIs.

## Layered Design

### 1) App Shell and Navigation
- Files: `Sources/Glitcho/App.swift`, `Sources/Glitcho/ContentView.swift`
- Responsibilities:
  - Window setup (main/settings/about/chat)
  - Sidebar and route state
  - Global toasts, confirmation dialogs, recording action intents

### 2) Twitch Web Integration
- File: `Sources/Glitcho/WebViewStore.swift`
- Responsibilities:
  - Embedded Twitch web session
  - CSS/JS injection for UI cleanup and scraping
  - Following/profile scraping and live-channel synchronization
  - Native playback request emission

### 3) Native Playback and Channel Details
- File: `Sources/Glitcho/StreamlinkPlayer.swift`
- Responsibilities:
  - Streamlink URL resolution and `AVPlayer`/`AVPlayerView` ownership
  - Playback overlay controls (play/pause, volume, PiP, fullscreen, chat actions)
  - Fullscreen token flow that promotes native player fullscreen mode
  - Details panels (`About`, `Videos`, `Schedule`) rendered as native SwiftUI
  - Video routing fallback logic for online/offline parity

### 4) Recording Engine and Library
- Files: `Sources/Glitcho/RecordingManager.swift`, `Sources/Glitcho/RecorderOrchestrator.swift`, `Sources/Glitcho/RecordingsLibraryView.swift`, `Sources/Glitcho/AutoRecordMode.swift`
- Responsibilities:
  - Recording session/process lifecycle
  - Auto-record filtering (pinned/followed/custom allowlist + blocklist override)
  - Debounce/cooldown + concurrency caps
  - Retention policy enforcement (age/global/per-channel limits)
  - Library UI for search/sort/layout/grouping and bulk export/delete

### 5) Background Recorder Agent
- Files: `Sources/Glitcho/BackgroundRecorderAgentManager.swift`, product `GlitchoRecorderAgent`
- Responsibilities:
  - LaunchAgent provisioning/restart/stop
  - Deterministic control results + user-facing feedback wiring
  - Session restart/kill hooks from UI

### 6) Licensing and Entitlement Gating
- Files: `Sources/Glitcho/LicenseManager.swift`, `Sources/Glitcho/KeychainHelper.swift`, `Sources/Glitcho/RecordingFeatureVisibilityPolicy.swift`
- Responsibilities:
  - Server license validation (`POST /license/validate`)
  - Optional P256 response signature verification
  - Cached entitlement + offline grace behavior
  - UI visibility gating for recording/pro controls

### 7) Pro Video Enhancement Pipeline
- Files: `Sources/Glitcho/MotionInterpolation.swift`, `Sources/Glitcho/StreamlinkPlayer.swift`, `Sources/Glitcho/SettingsView.swift`
- Responsibilities:
  - Motion smoothening runtime (capability and fallback aware)
  - 4K upscaler toggle and aspect crop modes (`Source`, `21:9`, `32:9`)
  - Image optimization controls
  - Runtime diagnostics/status badge publication

### 8) Companion API
- Files: `Sources/Glitcho/CompanionAPIServer.swift`, `Sources/Glitcho/CompanionAPIClient.swift`, `Sources/Glitcho/CompanionAPIModels.swift`
- Responsibilities:
  - Local control/status endpoint hosting
  - Client integration for remote/automation workflows

### 9) Telemetry and Observability
- File: `Sources/Glitcho/Telemetry.swift`
- Responsibilities:
  - Structured local `OSLog` telemetry events for playback, recording, licensing, and motion runtime behavior

## Primary Runtime Flows

### A) Twitch Session and Following Sync
1. `WebViewStore` loads Twitch.
2. JS scrapers emit profile/following/live payloads via script handlers.
3. `ContentView` and sidebar react to published store state.

### B) Native Playback Start
1. A Twitch URL/user action maps to `NativePlaybackRequest`.
2. `StreamlinkPlayer` resolves media URL via Streamlink process.
3. `AVPlayer` begins playback with native controls + Glitcho overlay actions.

### C) Auto-record Decision
1. Live-channel updates feed `RecordingManager` candidate evaluation.
2. `AutoRecordMode`, allowlist, and blocklist policies are applied.
3. `RecorderOrchestrator`/manager queue and spawn sessions respecting concurrency/debounce/cooldown.

### D) Recording Finalization
1. Session stops (manual or process termination).
2. Optional post-processing/remux prep runs (FFmpeg path-dependent).
3. Retention enforcement may prune old entries.
4. Library view refreshes from filesystem index.

### E) Licensing
1. User enters key/server/public key in Settings.
2. `LicenseManager` validates and verifies signature (if configured).
3. Entitlement cache persists for offline grace.
4. UI feature policy updates instantly.

### F) Channel Details Native Rendering
1. About/Videos/Schedule stores load channel routes.
2. Scrapers parse payloads from Twitch pages/scripts.
3. SwiftUI cards render, including tappable linked images in About.

## Architectural Notes

- The app is macOS-focused; prior iOS/iPadOS scaffolding has been removed.
- Twitch DOM scraping remains a deliberate but fragile dependency.
- Process-heavy paths (Streamlink/FFmpeg/agent) are encapsulated behind manager/orchestrator abstractions to limit spawn storms and improve cleanup behavior.
- New features are expected to emit telemetry and user feedback surfaces (toast/status/confirmations).
