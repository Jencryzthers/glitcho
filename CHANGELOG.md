# Changelog - Glitcho

All notable user-visible changes are tracked here.

## Unreleased

### Added
- Collapsible streamer details section under the native player (`About / Videos / Schedule`) with persistent state.
- Overlay control toggle for collapsing/expanding the details section directly from the player toolbar.
- Separate Dockerized commerce website stack:
  - marketing/download pages
  - Stripe checkout (lifetime Pro)
  - magic-link customer portal for orders and activation key management
  - admin dashboard for orders, payments, and license revoke/reactivate controls
  - app-compatible `/license/validate` endpoint with P256 signing support
- New startup scripts for commerce stack:
  - `Scripts/start_commerce_site.sh`
  - `Scripts/stop_commerce_site.sh`

### Changed
- Collapsed details mode now lets the player consume full available vertical space.
- Removed the extra full-width translucent top overlay bar; compact controls pill remains.
- Native player fullscreen requests now use AVPlayer's fullscreen path (player-only fullscreen behavior).
- Overlay controls are now consistent between live playback and local recording playback.
- About panel rendering was hardened for repeated image-link URLs by generating stable unique link IDs.
- About panel image rendering now clamps and clips more aggressively to prevent card bleed/overlap.
- Motion smoothening UI now reports real target refresh (`60...120Hz` based on capability).
- Motion telemetry no longer hardcodes `60Hz` target values.
- Motion interpolation heuristics were tuned to reduce artifacts (coherence fallback + less aggressive warp/blur/sharpen).
- Runtime overlay badges were simplified (no interpolation budget warning text; cleaner 4K/FPS badge alignment).
- Commerce website scope simplified to promo/download/donation only (pricing/account/admin UI retired).

## 1.3.0 - 2026-02-13

### Added
- Pro license workflow in Settings:
  - License key entry
  - Validation server URL
  - Optional P256 public key verification
  - Validation status, expiry, and last-validated indicators
- Local entitlement cache with offline grace behavior in `LicenseManager`.
- Reference validation server + Docker hosting workflow:
  - `Scripts/license_server_example.mjs`
  - `Scripts/start_activation_server.sh`
  - `Scripts/stop_activation_server.sh`
  - `deploy/license-server/*`
- Recording orchestration foundation (`RecorderOrchestrator`) with per-channel states and retry metadata.
- Background recorder lifecycle controls with feedback:
  - Restart agent
  - Stop all recordings
- Companion API server/client support for remote control.
- Recording library upgrades:
  - list/grid modes
  - search/sort
  - grouping by streamer
  - multi-select bulk actions
  - bulk export progress/status
- Retention policy enforcement:
  - max age
  - keep last N (global/per channel)
- Native streamer detail tabs:
  - About
  - Videos
  - Schedule

### Changed
- Recording UI/settings visibility now respects license entitlement policy.
- Player overlay controls reorganized with compact defaults + overflow popover.
- Videos tab routing and loading behavior improved for offline/online parity.
- Pro video enhancement controls moved to settings and integrated with player state.

### Removed
- iOS/iPadOS scaffold and IPA build pipeline were removed from repository.

## 1.0.4

- Added live stream recording with Streamlink and in-player controls.
- Added recording settings for output folder and Streamlink management.

## 1.0.3

- Added pinned channels with per-channel notification toggles.
- Added settings window and improved sidebar UX.
- Added in-app update checking via GitHub releases.
- Added detached chat window support and PiP groundwork.

## 1.0.2

- Bundle versioning aligned with `Scripts/make_app.sh`.
- About window version display synced with app bundle metadata.
- Repository hygiene updates for build output exclusions.

## 1.0.0

- Initial macOS release with native shell around Twitch web experience.
