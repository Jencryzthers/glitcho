import XCTest
@testable import Glitcho

@MainActor
final class RecordingManagerTests: XCTestCase {
    private let recoveryDefaultsKey = "recordingRecoveryIntents.v1"

    private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    private func makeTransportStreamLikeData(byteCount: Int = 512, includeSyncAt188: Bool = true, includeSyncAt376: Bool = true) -> Data {
        var data = Data(repeating: 0, count: byteCount)
        if !data.isEmpty {
            data[0] = 0x47
        }
        if includeSyncAt188, data.count > 188 {
            data[188] = 0x47
        }
        if includeSyncAt376, data.count > 376 {
            data[376] = 0x47
        }
        return data
    }

    private func withRecordingsDirectory<T>(_ directory: URL, _ body: () async throws -> T) async throws -> T {
        let defaults = UserDefaults.standard
        let key = "recordingsDirectory"
        let previous = defaults.string(forKey: key)
        defaults.set(directory.path, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try await body()
    }

    private func withConcurrencyLimit<T>(_ limit: Int, _ body: () async throws -> T) async throws -> T {
        let defaults = UserDefaults.standard
        let key = "recordingConcurrencyLimit"
        let previous = defaults.object(forKey: key)
        defaults.set(limit, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try await body()
    }

    private func makeFakeStreamlinkExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fake-streamlink")
        let script = """
        #!/bin/sh
        set -eu

        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            output="${1:-}"
            break
          fi
          shift
        done

        if [ -z "$output" ]; then
          exit 2
        fi

        : > "$output"
        sleep 60
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func makeSlowTerminationStreamlinkExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("slow-stop-streamlink")
        let script = """
        #!/bin/sh
        set -eu

        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            output="${1:-}"
            break
          fi
          shift
        done

        if [ -z "$output" ]; then
          exit 2
        fi

        : > "$output"
        trap 'sleep 1; exit 0' TERM INT
        while true; do
          sleep 1
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func makeFailingStreamlinkExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("failing-streamlink")
        let script = """
        #!/bin/sh
        set -eu

        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            output="${1:-}"
            break
          fi
          shift
        done

        if [ -z "$output" ]; then
          exit 2
        fi

        : > "$output"
        echo "streamlink failed" 1>&2
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return condition()
    }

    private func assertEventuallyTrue(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let value = await waitUntil(
            timeout: timeout,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            condition: condition
        )
        XCTAssertTrue(value, file: file, line: line)
    }

    private func persistedRecoveryIntents() -> [RecordingManager.RecoveryIntent] {
        guard let data = UserDefaults.standard.data(forKey: recoveryDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RecordingManager.RecoveryIntent].self, from: data)) ?? []
    }

    func testPrepareRecordingForPlayback_RemuxesTransportStreamMP4UsingFFmpeg() async throws {
        try await withTemporaryDirectory { dir in
            let inputURL = dir.appendingPathComponent("input.mp4")
            try makeTransportStreamLikeData().write(to: inputURL)

            let argsLogURL = dir.appendingPathComponent("ffmpeg_args.txt")
            let fakeFFmpegURL = dir.appendingPathComponent("ffmpeg")

            let script = """
            #!/bin/sh
            set -eu
            printf '%s\n' \"$@\" > '\(argsLogURL.path)'
            out='' ; for arg in \"$@\"; do out=\"$arg\"; done
            printf 'REMUXED' > \"$out\"
            exit 0
            """
            try script.write(to: fakeFFmpegURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpegURL.path)

            let manager = RecordingManager()
            manager._resolveFFmpegPathOverride = { fakeFFmpegURL.path }

            let result = try await manager.prepareRecordingForPlayback(at: inputURL)
            XCTAssertEqual(result.url, inputURL)
            XCTAssertTrue(result.didRemux)

            let remuxed = try String(contentsOf: inputURL, encoding: .utf8)
            XCTAssertEqual(remuxed, "REMUXED")

            let args = try String(contentsOf: argsLogURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)

            XCTAssertEqual(args.count, 13)
            XCTAssertEqual(args[0], "-y")
            XCTAssertEqual(args[1], "-hide_banner")
            XCTAssertEqual(args[2], "-loglevel")
            XCTAssertEqual(args[3], "error")
            XCTAssertEqual(args[4], "-i")
            XCTAssertEqual(args[5], inputURL.path)
            XCTAssertEqual(args[6], "-c")
            XCTAssertEqual(args[7], "copy")
            XCTAssertEqual(args[8], "-movflags")
            XCTAssertEqual(args[9], "+faststart")
            XCTAssertEqual(args[10], "-bsf:a")
            XCTAssertEqual(args[11], "aac_adtstoasc")

            let outputPath = args[12]
            XCTAssertTrue(outputPath.hasSuffix(".mp4"))
            XCTAssertEqual(URL(fileURLWithPath: outputPath).deletingLastPathComponent(), dir)
            let outputName = URL(fileURLWithPath: outputPath).lastPathComponent
            XCTAssertTrue(outputName.hasPrefix("input.remux-"))
        }
    }

    func testPrepareRecordingForPlayback_ReturnsTransportStreamTempCopyWhenFFmpegNotFound() async throws {
        try await withTemporaryDirectory { dir in
            let inputURL = dir.appendingPathComponent("input.mp4")
            let tsData = makeTransportStreamLikeData()
            try tsData.write(to: inputURL)

            let manager = RecordingManager()
            manager._resolveFFmpegPathOverride = { nil }
            let result = try await manager.prepareRecordingForPlayback(at: inputURL)
            defer { try? FileManager.default.removeItem(at: result.url) }

            XCTAssertFalse(result.didRemux)
            XCTAssertEqual(result.url.pathExtension.lowercased(), "ts")
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
            XCTAssertEqual(try Data(contentsOf: result.url), tsData)
        }
    }

    func testPrepareRecordingForPlayback_ThrowsWhenFFmpegNotFoundAndFallbackDisabled() async throws {
        try await withTemporaryDirectory { dir in
            let inputURL = dir.appendingPathComponent("input.mp4")
            try makeTransportStreamLikeData().write(to: inputURL)

            let manager = RecordingManager()
            manager._resolveFFmpegPathOverride = { nil }

            do {
                _ = try await manager.prepareRecordingForPlayback(
                    at: inputURL,
                    allowTransportStreamFallback: false
                )
                XCTFail("Expected prepareRecordingForPlayback() to throw when ffmpeg is not found and fallback is disabled")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("FFmpeg was not found"))
            }
        }
    }

    func testPrepareRecordingForPlayback_DecryptsGlitchoAndFallsBackToTransportTempWhenFFmpegNotFound() async throws {
        try await withTemporaryDirectory { dir in
            let sourceURL = dir.appendingPathComponent("encrypted-source.mp4")
            let tsData = makeTransportStreamLikeData()
            try tsData.write(to: sourceURL)

            let encryption = RecordingEncryptionManager()
            let encrypted = try encryption.encryptFile(at: sourceURL, in: dir)
            let glitchoURL = dir.appendingPathComponent(encrypted.hashFilename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: glitchoURL.path))

            let manager = RecordingManager()
            manager._resolveFFmpegPathOverride = { nil }

            let result = try await manager.prepareRecordingForPlayback(at: glitchoURL)
            defer { try? FileManager.default.removeItem(at: result.url) }

            XCTAssertFalse(result.didRemux)
            XCTAssertEqual(result.url.pathExtension.lowercased(), "ts")
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
            XCTAssertEqual(try Data(contentsOf: result.url), tsData)
        }
    }

    func testPrepareRecordingForPlayback_DoesNotRequireFFmpegForNonTransportStreamMP4() async throws {
        try await withTemporaryDirectory { dir in
            let inputURL = dir.appendingPathComponent("input.mp4")
            var mp4LikeData = Data(repeating: 0, count: 32)
            mp4LikeData.replaceSubrange(4..<8, with: Data("ftyp".utf8))
            try mp4LikeData.write(to: inputURL)

            let manager = RecordingManager()
            manager._resolveFFmpegPathOverride = { nil }

            let result = try await manager.prepareRecordingForPlayback(at: inputURL)
            XCTAssertEqual(result.url, inputURL)
            XCTAssertFalse(result.didRemux)
            XCTAssertEqual(try Data(contentsOf: inputURL), mp4LikeData)
        }
    }

    func testIsTransportStreamFile_IdentifiesMPEGTSBySyncBytes() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("sample.mp4")
            try makeTransportStreamLikeData().write(to: url)

            let manager = RecordingManager()
            XCTAssertTrue(manager.isTransportStreamFile(at: url))
        }
    }

    func testIsTransportStreamFile_ReturnsFalseWhenSyncBytesDoNotRepeat() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("sample.mp4")
            try makeTransportStreamLikeData(includeSyncAt188: false).write(to: url)

            let manager = RecordingManager()
            XCTAssertFalse(manager.isTransportStreamFile(at: url))
        }
    }

    func testRunProcess_CapturesStdoutStderrAndExitCodeOnSuccess() async throws {
        let manager = RecordingManager()
        let output = try await manager.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "echo out; echo err 1>&2; exit 0"]
        )

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
    }

    func testRunProcess_ThrowsAndExposesOutputsOnFailure() async throws {
        let manager = RecordingManager()

        do {
            _ = try await manager.runProcess(
                executable: "/bin/sh",
                arguments: ["-c", "echo out; echo err 1>&2; exit 3"]
            )
            XCTFail("Expected runProcess() to throw on non-zero exit")
        } catch let error as RecordingManager.ProcessExecutionError {
            XCTAssertEqual(error.exitCode, 3)
            XCTAssertEqual(error.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
            XCTAssertEqual(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRecorderOrchestrator_TracksStateTransitionsAndConcurrencySetting() {
        let orchestrator = RecorderOrchestrator(maxConcurrentRecordings: 3, retryDelay: 90)

        XCTAssertEqual(orchestrator.maxConcurrentRecordings, 3)
        XCTAssertEqual(orchestrator.state(for: "streamera"), .idle)

        orchestrator.setQueued(for: "StreamerA")
        XCTAssertEqual(orchestrator.state(for: "streamera"), .queued)

        orchestrator.setRecording(for: "streamera")
        XCTAssertEqual(orchestrator.state(for: "streamera"), .recording)

        orchestrator.setStopping(for: "streamera")
        XCTAssertEqual(orchestrator.state(for: "streamera"), .stopping)

        orchestrator.setIdle(for: "streamera")
        XCTAssertEqual(orchestrator.state(for: "streamera"), .idle)
    }

    func testRecorderOrchestrator_ScheduleRetrySetsMetadataAndNextRetryTimestamp() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let orchestrator = RecorderOrchestrator(maxConcurrentRecordings: 2, retryDelay: 45)

        let nextRetryAt = orchestrator.scheduleRetry(for: "StreamerA", now: now, errorMessage: "boom")
        XCTAssertEqual(orchestrator.state(for: "streamera"), .retrying)

        guard let metadata = orchestrator.retryMetadata(for: "streamera") else {
            XCTFail("Expected retry metadata")
            return
        }

        XCTAssertEqual(metadata.retryCount, 1)
        XCTAssertEqual(metadata.lastFailureAt, now)
        XCTAssertEqual(metadata.nextRetryAt, now.addingTimeInterval(45))
        XCTAssertEqual(metadata.nextRetryAt, nextRetryAt)
        XCTAssertEqual(metadata.lastErrorMessage, "boom")
    }

    func testDeleteRecording_RemovesFile() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("sample.mp4")
            try Data("hello".utf8).write(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

            let manager = RecordingManager()
            try manager.deleteRecording(at: url)

            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testDeleteRecording_ThrowsWhenRecordingIsInProgress() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let fakeStreamlink = try makeFakeStreamlinkExecutable(in: dir)
                let manager = RecordingManager()
                manager._resolveStreamlinkPathOverride = { fakeStreamlink.path }

                let started = manager.startRecording(
                    target: "twitch.tv/streamer1",
                    channelName: "Streamer 1"
                )
                XCTAssertTrue(started)

                guard let outputURL = manager.lastOutputURL else {
                    XCTFail("Expected lastOutputURL after starting recording")
                    return
                }

                do {
                    try manager.deleteRecording(at: outputURL)
                    XCTFail("Expected deleteRecording() to throw when recording is in progress")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("still in progress"))
                }

                manager.stopRecording()
                await assertEventuallyTrue { manager.activeRecordingCount == 0 }
            }
        }
    }

    func testStartRecording_AllowsMultipleChannelsSimultaneously() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let fakeStreamlink = try makeFakeStreamlinkExecutable(in: dir)
                let manager = RecordingManager()
                manager._resolveStreamlinkPathOverride = { fakeStreamlink.path }

                XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamera", channelName: "Streamer A"))
                XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamerb", channelName: "Streamer B"))
                XCTAssertEqual(manager.activeRecordingCount, 2)
                XCTAssertTrue(manager.isRecording(channelLogin: "streamera"))
                XCTAssertTrue(manager.isRecording(channelLogin: "streamerb"))

                manager.stopRecording(channelLogin: "streamera")
                await assertEventuallyTrue {
                    manager.activeRecordingCount == 1 &&
                    !manager.isRecording(channelLogin: "streamera") &&
                    manager.isRecording(channelLogin: "streamerb")
                }

                manager.stopRecording()
                await assertEventuallyTrue { manager.activeRecordingCount == 0 }
            }
        }
    }

    func testToggleRecording_StopsOnlyMatchingChannel() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let fakeStreamlink = try makeFakeStreamlinkExecutable(in: dir)
                let manager = RecordingManager()
                manager._resolveStreamlinkPathOverride = { fakeStreamlink.path }

                XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamera", channelName: "Streamer A"))
                XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamerb", channelName: "Streamer B"))
                XCTAssertEqual(manager.activeRecordingCount, 2)

                manager.toggleRecording(target: "twitch.tv/streamera", channelName: "Streamer A")
                await assertEventuallyTrue {
                    manager.activeRecordingCount == 1 &&
                    !manager.isRecording(channelLogin: "streamera") &&
                    manager.isRecording(channelLogin: "streamerb")
                }

                manager.toggleRecording(target: "twitch.tv/streamerb", channelName: "Streamer B")
                await assertEventuallyTrue { manager.activeRecordingCount == 0 }
            }
        }
    }

    func testRecordingManager_QueuesWhenConcurrencyLimitReachedAndStartsWhenSlotFrees() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                try await withConcurrencyLimit(1) {
                    let fakeStreamlink = try makeFakeStreamlinkExecutable(in: dir)
                    let manager = RecordingManager()
                    manager._resolveStreamlinkPathOverride = { fakeStreamlink.path }

                    XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamera", channelName: "Streamer A"))
                    await assertEventuallyTrue { manager.isRecording(channelLogin: "streamera") }

                    XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamerb", channelName: "Streamer B"))
                    XCTAssertEqual(manager.recorderOrchestrator.state(for: "streamerb"), .queued)
                    XCTAssertFalse(manager.isRecording(channelLogin: "streamerb"))

                    manager.stopRecording(channelLogin: "streamera")

                    await assertEventuallyTrue {
                        manager.recorderOrchestrator.state(for: "streamerb") == .recording
                            && manager.isRecording(channelLogin: "streamerb")
                    }

                    manager.stopRecording()
                    await assertEventuallyTrue { manager.activeRecordingCount == 0 }
                }
            }
        }
    }

    func testRecordingManager_StopQueuedRecordingCancelsQueue() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                try await withConcurrencyLimit(1) {
                    let fakeStreamlink = try makeFakeStreamlinkExecutable(in: dir)
                    let manager = RecordingManager()
                    manager._resolveStreamlinkPathOverride = { fakeStreamlink.path }

                    XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamera", channelName: "Streamer A"))
                    await assertEventuallyTrue { manager.isRecording(channelLogin: "streamera") }

                    XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamerb", channelName: "Streamer B"))
                    XCTAssertEqual(manager.recorderOrchestrator.state(for: "streamerb"), .queued)

                    manager.stopRecording(channelLogin: "streamerb")
                    XCTAssertEqual(manager.recorderOrchestrator.state(for: "streamerb"), .idle)

                    manager.stopRecording(channelLogin: "streamera")
                    await assertEventuallyTrue {
                        manager.activeRecordingCount == 0
                            && !manager.isRecording(channelLogin: "streamerb")
                            && manager.recorderOrchestrator.state(for: "streamerb") == .idle
                    }
                }
            }
        }
    }

    func testRecordingManager_UpdatesOrchestratorStateOnStartAndStop() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let slowStopStreamlink = try makeSlowTerminationStreamlinkExecutable(in: dir)
                let manager = RecordingManager()
                manager._resolveStreamlinkPathOverride = { slowStopStreamlink.path }

                XCTAssertEqual(manager.recorderOrchestrator.state(for: "streamera"), .idle)
                XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamera", channelName: "Streamer A"))
                await assertEventuallyTrue {
                    manager.recorderOrchestrator.state(for: "streamera") == .recording
                }

                manager.stopRecording(channelLogin: "streamera")
                XCTAssertEqual(manager.recorderOrchestrator.state(for: "streamera"), .stopping)

                await assertEventuallyTrue {
                    manager.recorderOrchestrator.state(for: "streamera") == .idle
                }
                XCTAssertEqual(manager.activeRecordingCount, 0)
            }
        }
    }

    func testRecordingManager_SchedulesRetryMetadataAfterUnexpectedTermination() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let failingStreamlink = try makeFailingStreamlinkExecutable(in: dir)
                let manager = RecordingManager()
                manager._resolveStreamlinkPathOverride = { failingStreamlink.path }

                XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamera", channelName: "Streamer A"))
                await assertEventuallyTrue {
                    manager.recorderOrchestrator.state(for: "streamera") == .retrying
                }

                guard let metadata = manager.recorderOrchestrator.retryMetadata(for: "streamera") else {
                    XCTFail("Expected retry metadata after failure")
                    return
                }

                XCTAssertEqual(metadata.retryCount, 1)
                XCTAssertEqual(metadata.lastErrorMessage, "streamlink failed")
                XCTAssertNotNil(metadata.lastFailureAt)
                XCTAssertNotNil(metadata.nextRetryAt)

                if let lastFailureAt = metadata.lastFailureAt,
                   let nextRetryAt = metadata.nextRetryAt {
                    XCTAssertGreaterThan(nextRetryAt, lastFailureAt)
                }
            }
        }
    }

    func testConsumeRecoveryIntents_ReturnsPersistedValues() async throws {
        let defaults = UserDefaults.standard
        let intents = [
            RecordingManager.RecoveryIntent(
                target: "https://twitch.tv/streamera",
                channelLogin: "streamera",
                channelName: "Streamer A",
                quality: "best",
                capturedAt: Date()
            )
        ]
        defaults.set(try JSONEncoder().encode(intents), forKey: recoveryDefaultsKey)
        defer { defaults.removeObject(forKey: recoveryDefaultsKey) }

        let manager = RecordingManager()
        let restored = manager.consumeRecoveryIntents()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.channelLogin, "streamera")
        XCTAssertEqual(restored.first?.target, "https://twitch.tv/streamera")
    }

    func testStartRecording_PersistsRecoveryIntentAndClearsAfterStop() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let defaults = UserDefaults.standard
                defaults.removeObject(forKey: recoveryDefaultsKey)
                defer { defaults.removeObject(forKey: recoveryDefaultsKey) }

                let fakeStreamlink = try makeFakeStreamlinkExecutable(in: dir)
                let manager = RecordingManager()
                manager._resolveStreamlinkPathOverride = { fakeStreamlink.path }

                XCTAssertTrue(manager.startRecording(target: "twitch.tv/streamera", channelName: "Streamer A"))
                await assertEventuallyTrue { manager.activeRecordingCount == 1 }

                let persistedWhileActive = persistedRecoveryIntents()
                XCTAssertEqual(persistedWhileActive.count, 1)
                XCTAssertEqual(persistedWhileActive.first?.channelLogin, "streamera")

                manager.stopRecording()
                await assertEventuallyTrue { manager.activeRecordingCount == 0 }

                let persistedAfterStop = persistedRecoveryIntents()
                XCTAssertTrue(persistedAfterStop.isEmpty)
            }
        }
    }

    func testRenameRecording_RenamesPlaintextFile() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let original = dir.appendingPathComponent("old_name.mp4")
                try Data("payload".utf8).write(to: original)

                let manager = RecordingManager()
                let renamed = try manager.renameRecording(at: original, to: "new_name")

                XCTAssertEqual(renamed.lastPathComponent, "new_name.mp4")
                XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
            }
        }
    }

    func testRedownloadRecording_UsesSourceTargetWhenAvailable() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let fakeStreamlink = try makeFakeStreamlinkExecutable(in: dir)
                let sourceFile = dir.appendingPathComponent("source.mp4")
                try Data("dummy".utf8).write(to: sourceFile)

                let manager = RecordingManager()
                manager._resolveStreamlinkPathOverride = { fakeStreamlink.path }

                let entry = RecordingEntry(
                    url: sourceFile,
                    channelName: "Streamer A",
                    recordedAt: Date(),
                    fileTimestamp: Date(),
                    sourceType: .liveRecording,
                    sourceTarget: "twitch.tv/streamera"
                )

                XCTAssertTrue(manager.redownloadRecording(entry))
                await assertEventuallyTrue { manager.isRecording(channelLogin: "streamera") }
                manager.stopRecording()
                await assertEventuallyTrue { manager.activeRecordingCount == 0 }
            }
        }
    }

    func testPauseAndResumeDownloadTask_WithPersistedQueuedTask() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let fakeStreamlink = try makeFakeStreamlinkExecutable(in: dir)
                let manager = RecordingManager()
                manager._resolveStreamlinkPathOverride = { fakeStreamlink.path }

                let task = RecordingManager.DownloadTask(
                    id: "download-task-1",
                    target: "twitch.tv/streamera",
                    channelName: "Streamer A",
                    quality: "best",
                    captureType: .streamDownload,
                    outputURL: nil,
                    startedAt: Date(),
                    updatedAt: Date(),
                    progressFraction: 0.3,
                    bytesWritten: 1_024,
                    statusMessage: "Queued",
                    lastErrorMessage: nil,
                    retryCount: 0,
                    state: .queued
                )
                manager._replaceDownloadTasksForTesting([task])

                XCTAssertTrue(manager.pauseDownloadTask(id: "download-task-1"))
                guard let paused = manager._downloadTasksSnapshotForTesting().first else {
                    XCTFail("Missing paused task")
                    return
                }
                XCTAssertEqual(paused.state, .paused)

                XCTAssertTrue(manager.resumeDownloadTask(id: "download-task-1"))
                await assertEventuallyTrue { manager.isRecording(channelLogin: "streamera") }
                manager.stopRecording()
                await assertEventuallyTrue { manager.activeRecordingCount == 0 }
            }
        }
    }

    func testAutoRetryMarksFailedTaskQueuedImmediately() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "recordingDownloadAutoRetryEnabled")
        defaults.set(2, forKey: "recordingDownloadAutoRetryLimit")
        defaults.set(60, forKey: "recordingDownloadAutoRetryDelaySeconds")
        defer {
            defaults.removeObject(forKey: "recordingDownloadAutoRetryEnabled")
            defaults.removeObject(forKey: "recordingDownloadAutoRetryLimit")
            defaults.removeObject(forKey: "recordingDownloadAutoRetryDelaySeconds")
        }

        let manager = RecordingManager()
        let failedTask = RecordingManager.DownloadTask(
            id: "failed-task-1",
            target: "twitch.tv/streamerb",
            channelName: "Streamer B",
            quality: "best",
            captureType: .streamDownload,
            outputURL: nil,
            startedAt: Date(),
            updatedAt: Date(),
            progressFraction: nil,
            bytesWritten: 0,
            statusMessage: "Failed",
            lastErrorMessage: "network timeout",
            retryCount: 0,
            state: .failed
        )
        manager._replaceDownloadTasksForTesting([failedTask])

        manager._triggerAutoRetryForTesting(id: "failed-task-1")
        guard let queued = manager._downloadTasksSnapshotForTesting().first(where: { $0.id == "failed-task-1" }) else {
            XCTFail("Missing queued retry task")
            return
        }
        XCTAssertEqual(queued.state, .queued)
        XCTAssertEqual(queued.retryCount, 1)
        XCTAssertTrue((queued.statusMessage ?? "").contains("Auto-retry"))

        manager._cancelAutoRetryForTesting(id: "failed-task-1")
    }

    func testDuplicateRecordingGroupsAndCleanup() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let manager = RecordingManager()
                let folder = dir.appendingPathComponent("dups", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                let fileA = dir.appendingPathComponent("a.mp4")
                let fileB = folder.appendingPathComponent("b.mp4")
                let fileC = dir.appendingPathComponent("c.mp4")
                let blob = Data(repeating: 0xAA, count: 2048)
                try blob.write(to: fileA)
                try blob.write(to: fileB)
                try Data(repeating: 0xBB, count: 1024).write(to: fileC)

                let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
                let entries = [
                    RecordingEntry(url: fileA, channelName: "Streamer", recordedAt: capturedAt, fileTimestamp: capturedAt, sourceType: .liveRecording, sourceTarget: nil),
                    RecordingEntry(url: fileB, channelName: "Streamer", recordedAt: capturedAt, fileTimestamp: capturedAt, sourceType: .liveRecording, sourceTarget: nil),
                    RecordingEntry(url: fileC, channelName: "Streamer", recordedAt: capturedAt.addingTimeInterval(60), fileTimestamp: capturedAt.addingTimeInterval(60), sourceType: .liveRecording, sourceTarget: nil)
                ]

                let groups = manager.duplicateRecordingGroups(in: entries)
                XCTAssertEqual(groups.count, 1)
                XCTAssertEqual(groups.first?.items.count, 2)

                let result = manager.cleanupDuplicateRecordings(in: entries)
                XCTAssertEqual(result.removedCount, 1)
                XCTAssertTrue(result.failedMessages.isEmpty)

                let remaining = [fileA, fileB].filter { FileManager.default.fileExists(atPath: $0.path) }
                XCTAssertEqual(remaining.count, 1)
            }
        }
    }

    func testScanAndRepairIntegrity_RemovesOrphanManifestAndThumbnail() async throws {
        try await withTemporaryDirectory { dir in
            try await withRecordingsDirectory(dir) {
                let manager = RecordingManager()
                let encryption = RecordingEncryptionManager()

                let existingHash = "exists-\(UUID().uuidString).glitcho"
                let encryptedNoManifestHash = "encrypted-only-\(UUID().uuidString).glitcho"
                let orphanHash = "orphan-\(UUID().uuidString).glitcho"
                let orphanThumbHash = "thumb-orphan-\(UUID().uuidString).glitcho"

                let existingURL = dir.appendingPathComponent(existingHash)
                try Data([0x00, 0x01, 0x02, 0x03]).write(to: existingURL)
                let encryptedNoManifestURL = dir.appendingPathComponent(encryptedNoManifestHash)
                try Data([0x10, 0x11, 0x12, 0x13]).write(to: encryptedNoManifestURL)

                let emptyURL = dir.appendingPathComponent("empty.mp4")
                try Data().write(to: emptyURL)

                let manifest: [String: RecordingManifestEntry] = [
                    existingHash: RecordingManifestEntry(
                        channelName: "Existing",
                        date: Date(),
                        quality: "best",
                        originalFilename: "existing.mp4",
                        sourceType: .liveRecording,
                        sourceTarget: "twitch.tv/existing"
                    ),
                    orphanHash: RecordingManifestEntry(
                        channelName: "Orphan",
                        date: Date(),
                        quality: "best",
                        originalFilename: "orphan.mp4",
                        sourceType: .liveRecording,
                        sourceTarget: "twitch.tv/orphan"
                    )
                ]
                try encryption.saveManifestSerialized(manifest, to: dir)
                try FileManager.default.createDirectory(
                    at: RecordingEncryptionManager.thumbnailCacheDirectory,
                    withIntermediateDirectories: true
                )
                try Data().write(to: RecordingEncryptionManager.thumbnailURL(for: existingHash))
                try Data("thumb".utf8).write(to: RecordingEncryptionManager.thumbnailURL(for: orphanHash))
                try Data("thumb".utf8).write(to: RecordingEncryptionManager.thumbnailURL(for: orphanThumbHash))

                let report = manager.scanLibraryIntegrity()
                XCTAssertEqual(report.issueCount, 2)
                XCTAssertTrue(report.orphanedManifestEntries.contains(orphanHash))
                XCTAssertTrue(report.missingThumbnailEntries.contains(existingHash))
                XCTAssertTrue(report.missingThumbnailEntries.contains(encryptedNoManifestHash))
                XCTAssertTrue(report.orphanedThumbnailEntries.contains(orphanHash))
                XCTAssertTrue(report.orphanedThumbnailEntries.contains(orphanThumbHash))
                XCTAssertTrue(report.unreadableFiles.contains(where: { $0.lastPathComponent == "empty.mp4" }))

                let repair = manager.repairLibraryIntegrity(report)
                XCTAssertGreaterThanOrEqual(repair.removedManifestEntries, 1)
                XCTAssertGreaterThanOrEqual(repair.removedOrphanedThumbnails, 2)

                let after = manager.scanLibraryIntegrity()
                XCTAssertFalse(after.orphanedManifestEntries.contains(orphanHash))
                XCTAssertFalse(after.orphanedThumbnailEntries.contains(orphanHash))
                XCTAssertFalse(after.orphanedThumbnailEntries.contains(orphanThumbHash))
            }
        }
    }
}
