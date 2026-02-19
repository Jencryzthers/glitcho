# Codebase Concerns

**Analysis Date:** 2026-02-13

## High-Risk Areas

### Twitch DOM Coupling
- Files: `Sources/Glitcho/WebViewStore.swift`, `Sources/Glitcho/StreamlinkPlayer.swift` (scraper scripts)
- Risk:
  - Following/profile/about/videos/schedule extraction depends on Twitch markup and script selectors.
  - Twitch UI changes can silently degrade native sections.
- Mitigation in place:
  - Fallback scraping paths + route fallback in videos.
  - More stable IDs for about links/cards.
- Remaining gap:
  - No automated selector canary against live Twitch DOM.

### Process Lifecycle Complexity
- Files: `Sources/Glitcho/RecordingManager.swift`, `Sources/Glitcho/RecorderOrchestrator.swift`, `Sources/Glitcho/BackgroundRecorderAgentManager.swift`
- Risk:
  - Multiple process families (app, Streamlink, FFmpeg, launch agent helper).
  - Spawn/cleanup regressions can still create resource pressure.
- Mitigation in place:
  - Orchestrator metadata + concurrency controls + retention hooks.
  - Profiling script to monitor process counts and memory.
- Remaining gap:
  - Need broader integration tests for restart/kill idempotency across repeated cycles.

### Playback + Motion Processing State Coupling
- Files: `Sources/Glitcho/StreamlinkPlayer.swift`, `Sources/Glitcho/MotionInterpolation.swift`
- Risk:
  - Dynamic toggling of motion/upscale/image optimize can cause stalls if pipeline reconfiguration races playback state.
  - Fullscreen/overlay behavior crosses AppKit + SwiftUI boundaries.
- Mitigation in place:
  - Capability checks, fallback modes, runtime diagnostics.
  - Playback nudge tests added.
- Remaining gap:
  - More automated runtime stress tests around repeated mode toggles while live playback runs.

### Licensing UX/Availability Dependency
- Files: `Sources/Glitcho/LicenseManager.swift`, `Sources/Glitcho/SettingsView.swift`
- Risk:
  - Validation server downtime impacts fresh entitlement checks.
  - Public key mismatch causes signature failures and feature lockouts.
- Mitigation in place:
  - Offline grace with cached entitlement.
  - Optional compatibility mode when no public key is configured.
- Remaining gap:
  - Stronger anti-tamper hardening and stricter production-mode defaults.

## Security and Trust Concerns

- Local compatibility mode (`public key` unset) is convenient for dev, weaker for production trust.
- Binary path overrides (`streamlinkPath`, `ffmpegPath`) trust local executables; no binary integrity attestation.
- Companion API is local by default, but misconfiguration may expose controls beyond intended boundary if firewall/network settings are loose.

## Performance Concerns

- Large recording libraries still rely on filesystem scans and SwiftUI rendering of full lists/grids.
- Motion interpolation and image processing can exceed budget on lower-tier hardware.
- WebView scrapers + native details rendering can spike work when channel tabs are switched rapidly.

## Configuration Mismatch Concern

- `Package.swift` targets macOS 13, but `Scripts/make_app.sh` writes bundle minimum system version `26.0`.
- Impact:
  - Build artifact may refuse launch on systems that satisfy package compile target.
- Recommended action:
  - Align bundle `LSMinimumSystemVersion` with intended deployment target.

## Testing Gaps

- No end-to-end automated test covering full Twitch login -> live detect -> record -> library export lifecycle.
- Limited automation for activation server integration and signature validation failure matrices.
- No load-test harness for sustained auto-record across many channels.

## Recommended Next Mitigations

1. Add selector health telemetry and fallback-state UI for Twitch scrape degradation.
2. Add integration tests for repeated background-agent restart/stop-all flows.
3. Add automated stress scenario for mode toggles (motion/upscale/image optimize) during live playback.
4. Align platform minimum version declarations in build outputs.
5. Add a scripted canary that validates license server signature contract end-to-end.
