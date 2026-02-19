# Coding Conventions

**Analysis Date:** 2026-02-13

## Naming and File Patterns

- Swift files: PascalCase (`RecordingManager.swift`, `LicenseManager.swift`)
- Types: PascalCase
- Members/functions: camelCase
- `View` suffix for reusable SwiftUI components
- `Manager`, `Store`, `Controller`, `Policy` suffixes indicate orchestration boundaries
- `@AppStorage` keys use dot-separated namespaces where possible (for player/video/motion settings)

## Architectural Conventions

- `@MainActor` is used for UI-affecting managers/stores where state is published to SwiftUI.
- Manager classes expose:
  - published state for UI (`@Published`)
  - explicit action functions (`start/stop/restart/validate/...`)
  - deterministic result payloads for user feedback (toast/status text)
- New user-facing features should include:
  - telemetry event (`Telemetry`)
  - explicit error handling path
  - visible UI feedback (toast/dialog/status)

## Player and Recording Conventions

- Keep native player identity stable; avoid tearing down `AVPlayer` instances on incidental layout changes.
- Fullscreen is requested via tokenized state to avoid repeated trigger loops.
- Recording actions with high impact (manual start/stop, stop-all, restart agent) should pass through confirmation flows.
- Auto-record decisions must pass policy filters:
  - recording scope mode
  - allowlist/blocklist
  - debounce/cooldown
  - concurrency gate

## Persistence Conventions

- Non-sensitive preferences: `UserDefaults`/`@AppStorage`
- Sensitive license material: keychain helpers and controlled storage paths
- Feature visibility should be controlled by `RecordingFeatureVisibilityPolicy` instead of ad hoc UI checks.

## Error Handling Conventions

- Throw typed errors where practical for recoverable process/file/network paths.
- Convert failure states into user-readable messages in view models/managers.
- Avoid silent `try?` for critical operations unless fallback is explicit and intentional.
- For process operations, capture stderr/stdout when possible for debugging context.

## Telemetry Conventions

- Use local structured telemetry (`Telemetry`) instead of ad hoc `print`.
- Include minimal structured metadata:
  - channel/mode identifiers
  - toggle state
  - fallback reason
  - action outcome
- Do not log secrets (license keys, auth tokens, full keychain payloads).

## Testing Conventions

- Unit tests live in `Tests/` with feature-focused files.
- Add tests for:
  - policy logic and routing choices
  - motion/interpolation heuristics
  - playback behavior regressions
  - identity/stability of parsed entities
- Prefer deterministic tests over timing-heavy waits.

## Documentation Conventions

- Keep `README.md`, `CHANGELOG.md`, and `docs/` aligned with shipped behavior.
- When major features change (licensing, recording, player controls), update docs in the same change set.
- Keep `.planning/codebase/*.md` snapshots current to reduce onboarding drift.
