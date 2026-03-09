# DVR Phase 0 Kickoff Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stabilize the recording foundation and land user-facing safety controls needed before larger DVR expansion.

**Architecture:** Introduce a central recording orchestrator for state/retry metadata while preserving existing process launch behavior. Add explicit confirmation/feedback UX for high-impact recording controls and background service operations.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftPM, macOS 13+, Streamlink, optional FFmpeg.

## Task 1: Recorder Orchestration Foundation

**Files:**
- Create: `Sources/Glitcho/RecorderOrchestrator.swift`
- Modify: `Sources/Glitcho/RecordingManager.swift`
- Test: `Tests/RecordingManagerTests.swift`

**Steps:**
1. Add failing tests for state transitions and retry scheduling metadata.
2. Verify failure (`swift test --filter RecordingManagerTests`).
3. Implement minimal `RecorderOrchestrator` and wire `RecordingManager`.
4. Verify pass.

## Task 2: Confirmation + Feedback for Recording Controls

**Files:**
- Modify: `Sources/Glitcho/ContentView.swift`
- Modify: `Sources/Glitcho/SettingsView.swift`
- Modify: `Sources/Glitcho/StreamlinkPlayer.swift`

**Steps:**
1. Add deterministic state hooks for confirmation/feedback behavior.
2. Add confirmation dialogs for:
   - manual start/stop from player
   - restart background agent
   - stop all recordings
3. Add feedback surfaces (status text/toast + last restart metadata).
4. Verify build and UI behavior.

## Task 3: Integration + Validation

**Files:**
- Modify: `Sources/Glitcho/ContentView.swift`
- Modify: `Sources/Glitcho/RecordingManager.swift`
- Modify: `Sources/Glitcho/BackgroundRecorderAgentManager.swift`

**Steps:**
1. Integrate orchestrator state with existing recording workflows.
2. Validate no sync/refresh storms.
3. Validate no regressions in recording lifecycle behavior.

---

## Status Snapshot (2026-02-13)

### Completed in repo
- `RecorderOrchestrator` added and integrated with `RecordingManager` queue/retry/concurrency path.
- Confirmation and feedback flows added for restart/stop-all/manual recording controls.
- Recording library expanded (bulk delete/export, search/sort/layout/grouping).
- Retention enforcement integrated into manager/runtime policy.
- Pro licensing + validation server integration landed.
- Native About/Videos/Schedule panels and player overlay controls substantially expanded.

### Follow-up Focus
1. Expand orchestrator from metadata-first to full deterministic worker scheduling path.
2. Add stronger integration tests for background agent process lifecycle and kill/restart idempotency.
3. Add automated memory/perf regression gate using `Scripts/profile_recording_runtime.sh` outputs.
