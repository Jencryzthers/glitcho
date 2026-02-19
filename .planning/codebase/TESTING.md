# Testing Patterns

**Analysis Date:** 2026-02-13

## Test Framework and Runner

- XCTest + SwiftPM test target (`GlitchoTests`)
- Standard command:
  - `swift test`
- Useful focused runs:
  - `swift test --filter RecordingManagerTests`
  - `swift test --filter ChannelVideosRoutingTests`
  - `swift test --filter MotionInterpolationHeuristicsTests`

## Current Test Files

- `RecordingManagerTests.swift`
- `RecordingFeatureVisibilityPolicyTests.swift`
- `NativeVideoPlayerGestureTests.swift`
- `NativeVideoPlayerPlaybackNudgeTests.swift`
- `ChannelVideosRoutingTests.swift`
- `ChannelAboutLinkIdentityTests.swift`
- `MotionInterpolationHeuristicsTests.swift`
- `MotionSmootheningCapabilityTests.swift`
- `GlitchoTests.swift`

## Coverage Focus Areas

### Recording
- Process execution error handling and remux preparation.
- Retention-related behavior and filesystem operations.
- Visibility/policy gating with license state.

### Playback/UI Logic
- Gesture and zoom/pan clamping behavior.
- Playback nudge behavior to avoid frozen-start regressions.
- Video route selection logic for channel pages.
- Stable identity generation for About links/images.

### Motion Pipeline
- Heuristic guardrails/fallback behavior.
- Capability checks across device/power/thermal conditions.

## Test Style Conventions

- Prefer deterministic unit tests over timer-based behavior.
- Use local temporary directories for file tests; avoid mutating real user paths.
- Fake external binaries with executable test scripts when validating process wiring.
- Keep assertions explicit about behavior and regressions, not just non-nil checks.

## Manual Validation Matrix (Required for Feature Work)

1. Playback:
   - open live channel
   - toggle fullscreen, PiP, chat collapse/popout
   - verify no stuck playback on feature toggles
2. Channel details:
   - about/videos/schedule tabs
   - online/offline channel transitions
   - confirm videos cards render consistently
3. Recording:
   - manual start/stop with confirmation
   - restart background recorder and stop-all flows
   - verify toast/status responses
4. Licensing:
   - valid key, invalid signature, offline grace behavior
5. Library:
   - search/sort/group/list-grid
   - multi-select delete/export
   - retention "run now" behavior
6. Pro video enhancements:
   - motion smoothening
   - 4K upscaler
   - image optimization settings
   - aspect crop mode switches

## Performance/Regression Validation

- Use `Scripts/profile_recording_runtime.sh` for baseline vs after comparisons:
  - process counts (`streamlink`, `ffmpeg`, `GlitchoRecorderAgent`)
  - app CPU/RSS peaks
- Keep sample duration and interval identical between comparison runs.

## Known Testing Gaps

- No automated full end-to-end Twitch UI session tests.
- No CI-enforced coverage gate in repo today.
- Activation server integration tests are mostly manual/script-driven rather than XCTest-driven.
