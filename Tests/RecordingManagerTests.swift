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

    func testPrepareRecordingForPlayback_ThrowsWhenFFmpegNotFound() async throws {
        try await withTemporaryDirectory { dir in
            let inputURL = dir.appendingPathComponent("input.mp4")
            try makeTransportStreamLikeData().write(to: inputURL)

            let manager = RecordingManager()
            manager._resolveFFmpegPathOverride = { nil }

            do {
                _ = try await manager.prepareRecordingForPlayback(at: inputURL)
                XCTFail("Expected prepareRecordingForPlayback() to throw when ffmpeg is not found")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("FFmpeg was not found"))
            }
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
                XCTAssertTrue(await waitUntil { manager.activeRecordingCount == 0 })
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
                XCTAssertTrue(await waitUntil {
                    manager.activeRecordingCount == 1 &&
                    !manager.isRecording(channelLogin: "streamera") &&
                    manager.isRecording(channelLogin: "streamerb")
                })

                manager.stopRecording()
                XCTAssertTrue(await waitUntil { manager.activeRecordingCount == 0 })
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
                XCTAssertTrue(await waitUntil {
                    manager.activeRecordingCount == 1 &&
                    !manager.isRecording(channelLogin: "streamera") &&
                    manager.isRecording(channelLogin: "streamerb")
                })

                manager.toggleRecording(target: "twitch.tv/streamerb", channelName: "Streamer B")
                XCTAssertTrue(await waitUntil { manager.activeRecordingCount == 0 })
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
                XCTAssertTrue(await waitUntil { manager.activeRecordingCount == 1 })

                let persistedWhileActive = persistedRecoveryIntents()
                XCTAssertEqual(persistedWhileActive.count, 1)
                XCTAssertEqual(persistedWhileActive.first?.channelLogin, "streamera")

                manager.stopRecording()
                XCTAssertTrue(await waitUntil { manager.activeRecordingCount == 0 })

                let persistedAfterStop = persistedRecoveryIntents()
                XCTAssertTrue(persistedAfterStop.isEmpty)
            }
        }
    }
}
