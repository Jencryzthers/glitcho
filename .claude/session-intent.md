# Session Intent Contract

**Created:** 2026-03-01
**Goal:** Ship privacy hardening and recording UX simplification release.

## Job Statement
Deliver a production-ready privacy + recording update that introduces biometric-gated visibility controls, protected streamer handling, encrypted recording-at-rest workflow, and removal of confusing legacy recording controls.

## Success Criteria
- Biometric lock can hide recordings/pinned/recent until authentication.
- Protected streamers are hidden from sidebar and recordings while locked.
- Recordings remain encrypted on disk with opaque filenames and are only readable after export.
- Touch ID/keychain prompting is minimized by reuse/caching behavior.
- Context recording actions are clearer and redundant "always record" behavior is removed.
- Scheduled recording feature is removed from UI and runtime.

## Boundaries
- Keep existing playback and auto-record scope behavior intact.
- Avoid user-visible references that leak protected data while locked.
- Preserve existing app architecture and SwiftUI integration style.

## Context
- Feature requests were driven by privacy-first workflow and reduced UI confusion.
- Release packaging, changelog, and docs must be updated with shipped behavior.
