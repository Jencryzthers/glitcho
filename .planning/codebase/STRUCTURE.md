# Codebase Structure

**Analysis Date:** 2026-02-13

## Directory Layout

```text
glitcho/
├── Sources/
│   ├── Glitcho/                        # main app target
│   └── GlitchoRecorderAgent/           # helper executable target
├── Tests/                              # Glitcho test target
├── Scripts/                            # build + ops scripts
├── deploy/license-server/              # Dockerized activation server
├── docs/                               # user/dev documentation
├── .planning/codebase/                 # architecture/stack/testing notes
├── Package.swift
├── README.md
├── CHANGELOG.md
└── AGENTS.md
```

## Main Source Modules (`Sources/Glitcho`)

### App shell and windows
- `App.swift`
- `ContentView.swift`
- `WindowConfigurator.swift`
- `DetachedChatView.swift`

### Twitch/web bridge
- `WebViewStore.swift`

### Playback and channel details
- `StreamlinkPlayer.swift`
- `PictureInPictureController.swift`

### Recording subsystem
- `RecordingManager.swift`
- `RecorderOrchestrator.swift`
- `StreamlinkRecorder.swift`
- `AutoRecordMode.swift`
- `RecordingsLibraryView.swift`
- `RecordingFeatureVisibilityPolicy.swift`

### Licensing and pro gating
- `LicenseManager.swift`
- `KeychainHelper.swift`

### Motion/video enhancement
- `MotionInterpolation.swift`

### Companion API
- `CompanionAPIServer.swift`
- `CompanionAPIClient.swift`
- `CompanionAPIModels.swift`

### Support and utilities
- `NotificationManager.swift`
- `Telemetry.swift`
- `PinnedChannel.swift`
- `SharedUtilities.swift`
- `SidebarTint.swift`
- `UpdateChecker.swift`
- `UpdatePromptView.swift`
- `UpdateStatusView.swift`
- `Environment+NotificationManager.swift`
- `NonSwiftUIMain.swift` (legacy/compat entry scaffold)

## Tests (`Tests`)

- `RecordingManagerTests.swift`
- `RecordingFeatureVisibilityPolicyTests.swift`
- `NativeVideoPlayerGestureTests.swift`
- `NativeVideoPlayerPlaybackNudgeTests.swift`
- `ChannelVideosRoutingTests.swift`
- `ChannelAboutLinkIdentityTests.swift`
- `MotionInterpolationHeuristicsTests.swift`
- `MotionSmootheningCapabilityTests.swift`
- `GlitchoTests.swift`

## Scripts (`Scripts`)

- `make_app.sh` (package + app bundle creation)
- `start_activation_server.sh` (Docker activation service bootstrap + key generation)
- `stop_activation_server.sh` (activation service shutdown)
- `profile_recording_runtime.sh` (recording CPU/RAM/process profiling)
- `license_server_example.mjs` (reference validation service)
- `generate_icon.py`, `proxy_server.py` (utility scripts)

## Deployment Assets (`deploy/license-server`)

- `Dockerfile`
- `docker-compose.yml`
- `.env.example`
- `data/license-keys.example.json`
- Generated runtime artifacts under `data/` (private/public keys, key store copies)

## Docs (`docs`)

- `docs/licensing-server.md`
- `docs/perf/recording-profiling.md`
- `docs/plans/2026-02-12-dvr-phase0-kickoff.md`

## Scope Notes

- iOS/iPadOS app scaffolding and IPA scripts were removed.
- Source tree is now intentionally macOS-focused.
- App icons remain under `Resources/`.
