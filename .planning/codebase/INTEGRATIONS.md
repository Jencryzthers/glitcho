# External Integrations

**Analysis Date:** 2026-02-13

## Twitch Integration

- Primary external dependency: `https://www.twitch.tv`
- Mechanism:
  - Embedded `WKWebView` session for authentication and browsing state.
  - Injected JS/CSS for UI suppression + data extraction.
- Extracted data:
  - user/profile identity
  - followed/live channels
  - about/videos/schedule panel content
- Native player still depends on Twitch-derived stream targets resolved through Streamlink.

## Stream/Recording Toolchain

### Streamlink
- Used by:
  - native playback stream URL resolution
  - recording process spawning
- Path sources:
  - custom configured path
  - common system locations
  - PATH fallback

### FFmpeg (optional)
- Used for post-recording preparation/remux paths when needed.
- Path sources mirror Streamlink pattern (`ffmpegPath` + PATH fallbacks).

## Licensing / Activation Server

- Client integration:
  - `LicenseManager` validation request to `POST /license/validate`
  - optional P256 signature verification with configured public key
  - cached entitlement + offline grace behavior
- Local/server deployment assets:
  - `deploy/license-server/Dockerfile`
  - `deploy/license-server/docker-compose.yml`
  - `Scripts/start_activation_server.sh`
  - `Scripts/stop_activation_server.sh`
- Startup script also generates key material and prints Base64 raw public key for app settings.

## Companion API

- Local HTTP control interface:
  - host/port configurable in app settings
  - optional token auth
  - status + recording control model endpoints
- Modules:
  - `CompanionAPIServer`
  - `CompanionAPIClient`
  - `CompanionAPIModels`

## Update Checking

- External endpoint:
  - `https://api.github.com/repos/Jencryzthers/glitcho/releases/latest`
- Module:
  - `UpdateChecker`

## Local Storage and Secrets

- `UserDefaults`:
  - playback/motion settings
  - recording and retention settings
  - license/validation endpoint settings
  - allowlist/blocklist/channel-mode configuration
- Keychain helpers:
  - used for sensitive license-related persistence paths (`KeychainHelper`)
- Filesystem:
  - recordings
  - export targets
  - launch agent plist/logs
  - activation-server key store data

## Telemetry / Observability

- Local telemetry through `OSLog` abstraction (`Telemetry`).
- No external SaaS telemetry/analytics dependency is configured in this repo.

## Network Endpoints Summary

- Twitch web/app/CDN endpoints (`twitch.tv` + stream delivery hosts)
- GitHub releases API
- Optional user-provided activation server URL
- Optional companion API listeners (local network scoped by configuration)

## Current Integration Risks

- Twitch DOM changes can break scraper-driven native sections.
- Local activation server key mismatch causes signature validation failures.
- Misconfigured companion API exposure can widen control surface.
