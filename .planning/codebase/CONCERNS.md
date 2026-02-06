# Codebase Concerns

**Analysis Date:** 2026-02-04

## Tech Debt

**Fragile DOM Scraping for Following List and Profile Data:**
- Issue: The app relies on DOM selectors to extract Twitch following list and profile information from WKWebView
- Files: `Sources/Glitcho/WebViewStore.swift` (JavaScript injection via followedLiveScript, profileScript)
- Impact: Any structural change to Twitch's DOM breaks the app's ability to display followed channels and profile data. Users see empty following lists until Twitch DOM matches expected selectors again
- Fix approach: Implement caching layer for scraped data; add version detection for Twitch DOM changes; consider using Twitch public API if available; add fallback UI when scraping fails

**Heavy Reliance on Streamlink for Stream Extraction:**
- Issue: Streaming functionality depends entirely on Streamlink CLI tool and its availability on user's PATH
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 125-330 for resolution), `Sources/Glitcho/StreamlinkPlayer.swift` (lines 88-100)
- Impact: If Streamlink breaks, becomes unavailable, or Twitch changes stream URL formats, the entire playback pipeline fails. Installation process requires Python 3 and venv
- Fix approach: Maintain bundled Streamlink binary (partially done); consider alternative stream URL extraction methods; implement robust fallback chain for executable resolution

**Process Execution Without Timeout Protection:**
- Issue: Process execution in `RecordingManager.runProcess()` and `StreamlinkPlayer.getStreamURL()` can block indefinitely if subprocess hangs
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 658-705), `Sources/Glitcho/StreamlinkPlayer.swift` (lines 22-81)
- Impact: Long-running streamlink queries or ffmpeg operations can freeze the UI (using DispatchQueue.global in StreamlinkPlayer) or create zombie processes if not properly cleaned up
- Fix approach: Add timeout parameters to Process execution; implement watchdog timers; add forceful termination on timeout; monitor process lifecycle

**Unvalidated File Handle Reads for Codec Detection:**
- Issue: `isTransportStreamFile()` reads raw file bytes to detect MPEG-TS format but doesn't validate file size or handle edge cases robustly
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 278-297)
- Impact: Corrupted or truncated recording files could cause detection to fail silently; edge case of very small files may not trigger detection correctly
- Fix approach: Add explicit file size checks before reading; add logging for detection results; improve edge case handling for files smaller than 512 bytes

**Manual Error Code Constants:**
- Issue: NSError creation uses hard-coded numeric codes (10, 11, 2, 3, 4, etc.) scattered across error handling
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 89-102, 224-228, 484-488, 499-503)
- Impact: Error codes are not centralized, making error routing fragile; no consistent error taxonomy
- Fix approach: Create centralized error enum with associated values; replace numeric codes with named error cases

## Known Bugs

**Recording Playback Preparation Race Condition:**
- Symptoms: In high CPU load scenarios, `prepareRecordingForPlayback()` may fail to detect TS->MP4 conversion is needed if file is still being written by streamlink
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 215-260), specifically line 221
- Trigger: Stop recording immediately after starting; attempt to play back within 1 second of stop
- Workaround: Wait a few seconds after stopping recording before playing; manually trigger FFmpeg remux
- Fix approach: Add retry logic with exponential backoff for file reading; implement file lock detection before attempting remux

**FFmpeg Installation Download Source Fragility:**
- Symptoms: FFmpeg download may fail with HTML error pages or timeouts from the build server
- Files: `Sources/Glitcho/RecordingManager.swift` (line 475), uses Martin Riedl's build server
- Trigger: Network issues or server downtime; architecture mismatch between build server and user CPU
- Workaround: Manually install FFmpeg via Homebrew and point Settings > Recording to it
- Fix approach: Add multiple fallback download sources; implement retry logic with exponential backoff; validate downloaded binary before extraction

**Channel Login Extraction From URL Can Return Nil:**
- Symptoms: Native player doesn't load when channel name cannot be extracted from URL
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 332-339)
- Trigger: Non-standard Twitch URLs; URLs without channel in path
- Workaround: Use standard twitch.tv/<channel> format
- Fix approach: Improve URL parsing; add fallback to accept channel name from UI instead of extracting from URL

## Security Considerations

**JavaScript Injection and DOM Manipulation:**
- Risk: Multiple custom JavaScript injections run in WKWebView context with access to Twitch DOM and user data
- Files: `Sources/Glitcho/WebViewStore.swift` (lines 90-98 add multiple user scripts)
- Current mitigation: Scripts are compiled as part of app; no dynamic script injection from network sources
- Recommendations: Document security review of each injected script (adBlockScript, hideChromeScript, followedLiveScript, profileScript); add CSP headers if possible; audit scraped data paths

**Subprocess Argument Construction Without Validation:**
- Risk: Process arguments are constructed from user input (channel names, file paths, URLs) without validation
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 148-155), `Sources/Glitcho/StreamlinkPlayer.swift` (lines 43-49)
- Current mitigation: Only shell metacharacters likely to appear in normal URLs/channel names
- Recommendations: Validate and sanitize channel names before using in streamlink args; add path traversal checks for file paths; document argument passing safety

**File Operations on User-Controlled Paths:**
- Risk: Recording directory path comes from user via NSOpenPanel; file operations trust this path
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 125-145, 299-304)
- Current mitigation: NSOpenPanel restricts to directories; FileManager validation checks
- Recommendations: Add explicit path validation before all FileManager operations; prevent symlink traversal; audit all paths before delete operations

**Executable Path Resolution with Multiple Fallbacks:**
- Risk: Streamlink/FFmpeg resolution checks multiple hardcoded paths including user PATH
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 314-330, 602-618), `Sources/Glitcho/StreamlinkPlayer.swift` (lines 113-129)
- Current mitigation: Only accepts files marked as executable by FileManager
- Recommendations: Implement integrity verification for downloaded binaries; add code signing verification for Homebrew installations; document trusted paths

## Performance Bottlenecks

**Synchronous File Enumeration for Recording List:**
- Problem: `listRecordings()` enumerates all files in recordings directory synchronously on main thread
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 45-85)
- Cause: Directory enumeration blocks UI if recordings folder contains many files or is on slow storage
- Improvement path: Move enumeration to background thread; implement pagination; add caching with file system observer for changes

**WebView Background Refresh Timer Without Backoff:**
- Problem: `loadFollowedLiveInBackground()` refreshes followed live channels at fixed intervals regardless of success/failure
- Files: `Sources/Glitcho/WebViewStore.swift` (lines 58, 103)
- Cause: No exponential backoff on failures; no adaptive rate limiting; continuous polling even when Twitch is unavailable
- Improvement path: Implement exponential backoff on failure; add network availability detection; use longer intervals with jitter; stop polling if app is backgrounded

**Large File Reads for Codec Detection Without Streaming:**
- Problem: `isTransportStreamFile()` reads entire first 512 bytes of file into memory
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 278-297)
- Cause: While 512 bytes is small, this is called on every recording selection without caching
- Improvement path: Cache detection result in RecordingEntry; implement lazy evaluation; skip check for known-good files

**Process Output Buffering Without Size Limits:**
- Problem: `runProcess()` collects all stdout/stderr into memory via Pipe
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 658-705)
- Cause: Large command outputs could fill memory; no streaming output handling
- Improvement path: Implement streaming output with line-based buffering; add memory limits; truncate very large outputs

## Fragile Areas

**StreamlinkPlayer Network I/O and Process Management:**
- Files: `Sources/Glitcho/StreamlinkPlayer.swift` (entire file, 2487 lines)
- Why fragile: Mixed blocking I/O on background thread (`waitUntilExit()` line 57) with async continuation pattern; Pipe reading happens synchronously after process termination; no proper cleanup if continuation is abandoned
- Safe modification: Extract process execution into separate async function with proper timeout; use proper async process API if available in Swift 5.9+; ensure all pipes are closed regardless of path
- Test coverage: `Tests/NativeVideoPlayerGestureTests.swift` covers gesture handling but NOT StreamlinkPlayer functionality; no tests for error scenarios or network failures

**RecordingManager Installation and Binary Download:**
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 341-402 for Streamlink, 404-542 for FFmpeg)
- Why fragile: Complex state machine with multiple points of failure; environment variable merging at line 673; ZIP file detection heuristics; file permission setting; quarantine attribute removal
- Safe modification: Break installStreamlink() and installFFmpeg() into smaller, testable functions; add integration tests for download/extract paths; validate ZIP files before extraction; add rollback on partial failure
- Test coverage: Some unit tests exist (`Tests/RecordingManagerTests.swift`) but installation functions are not tested; no tests for HTTP error scenarios

**WebViewStore JavaScript Injection and Message Handling:**
- Files: `Sources/Glitcho/WebViewStore.swift` (entire 1922-line file)
- Why fragile: DOM selectors hardcoded in JavaScript strings; message handler assumes specific message format without validation; background webview creation and cleanup not fully documented
- Safe modification: Extract selectors into constants or configuration; add strict validation in userContentController handler; document background webview lifecycle; add error handling for missing DOM elements
- Test coverage: No unit tests for WebViewStore; no tests for JavaScript message handling or DOM scraping

**Picture-in-Picture Window Management:**
- Files: `Sources/Glitcho/PictureInPictureController.swift` (68 lines, minimal code)
- Why fragile: NSWindow lifecycle not fully controlled; window release timing could cause crashes if parent view deallocates
- Safe modification: Use weak references for delegates; implement proper window delegate cleanup; test window closing scenarios
- Test coverage: No tests for PictureInPictureController

## Scaling Limits

**Recording Directory with Thousands of Files:**
- Current capacity: `listRecordings()` handles any count but UI performance degrades with >1000 files
- Limit: ScrollView and LazyVStack in RecordingsLibraryView become sluggish at ~2000+ recordings
- Scaling path: Implement pagination/infinite scroll; add filtering and search; move enumeration to background thread; implement SQLite-backed recording index instead of filesystem enumeration

**Concurrent Recording + Playback:**
- Current capacity: One concurrent recording allowed (isRecording state prevents multiple)
- Limit: Design prevents multiple simultaneous recordings
- Scaling path: If multi-record requested, refactor RecordingManager to track multiple Process instances; implement per-channel recording state

**Network Request Concurrency:**
- Current capacity: Single shared URLSession for update checks and Streamlink URL extraction
- Limit: No explicit concurrency limiting; could exceed reasonable HTTP connection pool under heavy load
- Scaling path: Implement URLSessionConfiguration with maxHTTPConnectionsPerHost; add request queue with max concurrent operations

## Dependencies at Risk

**Streamlink CLI Tool:**
- Risk: Entire streaming pipeline depends on Streamlink being installed and functional
- Impact: If Streamlink project is abandoned or changes output format, app breaks
- Migration plan: Evaluate alternative stream extraction tools (yt-dlp has Twitch support); implement native HLS/HTTP stream detection as fallback; consider official Twitch API if authentication added

**GitHub API for Update Checking:**
- Risk: UpdateChecker makes unauthenticated GitHub API requests; GitHub may rate-limit or change API
- Impact: Update checks fail silently; users unaware of new versions
- Migration plan: Add retry with backoff; cache update check results; implement fallback update notification method

**macOS 13+ Specific APIs:**
- Risk: Minimum target is macOS 13; some APIs may change in future macOS versions
- Impact: Future macOS updates could break PictureInPictureController or NSWindow handling
- Migration plan: Monitor macOS release notes; add feature availability checks; implement fallbacks for deprecated APIs

## Missing Critical Features

**No Persistent Cache for Recording Metadata:**
- Problem: Recording list is enumerated from disk on every view load; no metadata caching
- Blocks: Performance optimization; ability to add custom metadata (tags, descriptions)
- Recommendation: Implement local SQLite cache with file system watcher for invalidation

**No Graceful Degradation When DOM Changes:**
- Problem: Following list scraping fails silently when Twitch changes DOM selectors
- Blocks: Reliable operation across Twitch updates
- Recommendation: Add error reporting; implement adaptive selector detection; add fallback static page if DOM parsing fails

**Limited Error Messages for User Debugging:**
- Problem: Many errors are caught with `try?` and silently suppressed
- Blocks: Users cannot troubleshoot failures; no error telemetry
- Recommendation: Implement structured error logging; add user-facing error codes; implement debug mode with detailed output

**No Support for Clips or VODs via Native Player:**
- Problem: NativePlaybackRequest supports clip and vod kinds but UI/Streamlink integration is incomplete
- Blocks: Full feature parity with browser playback
- Recommendation: Complete Streamlink integration for clips/VODs; add UI for clip/VOD playback requests

## Test Coverage Gaps

**Untested Recording Remux Logic:**
- What's not tested: Error scenarios during FFmpeg remux; partial file remux; symlink handling in file replacement
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 215-260)
- Risk: Corrupted recordings could result if remux fails partway through
- Priority: High - affects user data integrity

**No Tests for StreamlinkPlayer Network Failures:**
- What's not tested: Network timeout behavior; malformed Streamlink output; process hanging
- Files: `Sources/Glitcho/StreamlinkPlayer.swift` (entire file)
- Risk: App could freeze or crash when Twitch network is unreachable
- Priority: High - affects core functionality

**Untested Installation Workflows:**
- What's not tested: Streamlink/FFmpeg installation with network failures; partial downloads; ZIP extraction edge cases
- Files: `Sources/Glitcho/RecordingManager.swift` (lines 341-542)
- Risk: Installation could leave system in broken state; no rollback on failure
- Priority: Medium - users can work around by manual install

**WebViewStore Message Handling Untested:**
- What's not tested: Malformed messages from JavaScript; missing DOM elements; message handler edge cases
- Files: `Sources/Glitcho/WebViewStore.swift` (lines 210-350 message handler)
- Risk: App could crash or data could be lost if message format changes
- Priority: Medium - affects user data (following list, profile)

**No E2E Tests for Complete Recording Workflow:**
- What's not tested: Start recording → stop → prepare → playback full chain
- Files: Multiple: RecordingManager, RecordingsLibraryView, NativeVideoPlayer
- Risk: Regressions in recording pipeline not caught by unit tests
- Priority: Medium - core feature

**Gesture Recognition Tests Incomplete:**
- What's not tested: Zoom pan interactions at edge cases; gesture interaction with video controls
- Files: `Tests/NativeVideoPlayerGestureTests.swift`, `Sources/Glitcho/StreamlinkPlayer.swift` (lines 179-400)
- Risk: Gesture handling could break with minor coordinate changes
- Priority: Low - visual feature, not critical to functionality

---

*Concerns audit: 2026-02-04*
