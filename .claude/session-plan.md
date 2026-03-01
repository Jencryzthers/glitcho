# Session Plan

**Created:** 2026-03-01
**Intent Contract:** See `.claude/session-intent.md`

## What You'll End Up With
A release-ready Glitcho build with biometric privacy controls, protected-streamer filtering, encrypted recording handling improvements, and simplified recording controls.

## Execution Summary

### 1. Privacy Lock Foundation
- Add centralized privacy lock settings keys.
- Add unlock manager and hotkey monitor.
- Wire lock state into `ContentView` routing and sidebar visibility.

### 2. Protected Streamer Controls
- Add settings editor for protected streamers.
- Support import from existing record list and auto-add integration.
- Hide protected streamers from sidebar/recordings while locked.

### 3. Recording Security Enhancements
- Ensure recordings are encrypted at rest with hashed filenames.
- Keep thumbnails available in recording library for encrypted items.
- Decrypt only for explicit export and preserve friendly export filenames.
- Reduce repeated key prompts with keychain/LAContext reuse behavior.

### 4. UX Simplification
- Remove always-record mode and all context/settings controls tied to it.
- Remove scheduled recording feature (UI + manager APIs + runtime monitor).
- Clarify remaining recording context actions (allowlist/blocklist semantics).

### 5. Release Delivery
- Bump packaged app version/build.
- Update changelog and README.
- Build app, create release asset zip, commit, tag, push, and publish GitHub release.
