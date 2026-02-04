import Foundation

#if canImport(SwiftUI)

@MainActor
final class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var activeChannel: String?
    @Published var activeChannelLogin: String?
    @Published var activeChannelName: String?
    @Published var lastOutputURL: URL?
    @Published var errorMessage: String?

    @Published var isInstalling = false
    @Published var installStatus: String?
    @Published var installError: String?

    private var process: Process?
    private var userInitiatedStop = false
    private let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()


    func recordingsDirectory() -> URL {
        if let saved = UserDefaults.standard.string(forKey: "recordingsDirectory"),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: saved)
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return (downloads ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Glitcho Recordings", isDirectory: true)
    }

    func listRecordings() -> [RecordingEntry] {
        let directory = recordingsDirectory()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let recordings = urls.compactMap { url -> RecordingEntry? in
            guard url.pathExtension.lowercased() == "mp4" else { return nil }
            let filename = url.deletingPathExtension().lastPathComponent
            let parts = filename.split(separator: "_")
            guard parts.count >= 3 else {
                return RecordingEntry(url: url, channelName: filename, recordedAt: nil)
            }

            let channelName = parts.dropLast(2).joined(separator: "_")
            let dateString = "\(parts[parts.count - 2])_\(parts[parts.count - 1])"
            let recordedAt = filenameDateFormatter.date(from: dateString)
            return RecordingEntry(url: url, channelName: channelName, recordedAt: recordedAt)
        }

        return recordings.sorted { left, right in
            let nameCompare = left.channelName.localizedCaseInsensitiveCompare(right.channelName)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            switch (left.recordedAt, right.recordedAt) {
            case let (lhs?, rhs?):
                return lhs > rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return left.url.lastPathComponent < right.url.lastPathComponent
            }
        }
    }
    func toggleRecording(target: String, channelName: String?, quality: String = "best") {
        if isRecording {
            stopRecording()
        } else {
            startRecording(target: target, channelName: channelName, quality: quality)
        }
    }

    func startRecording(target: String, channelName: String?, quality: String = "best") {
        guard !isRecording else { return }
        errorMessage = nil
        userInitiatedStop = false

        guard let streamlinkPath = resolveStreamlinkPath() else {
            errorMessage = "Streamlink is not installed. Use Settings > Recording to download it or set a custom path."
            return
        }

        let directory = recordingsDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Unable to create recordings folder: \(error.localizedDescription)"
            return
        }

        let resolvedChannelLogin = channelLogin(from: target)
        let normalizedName = channelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = filenameDateFormatter.string(from: Date())
        let safeChannelBase = (normalizedName?.isEmpty == false ? normalizedName! : (resolvedChannelLogin ?? "twitch"))
        let safeChannel = safeChannelBase.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeChannel)_\(timestamp).mp4"
        let outputURL = directory.appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: streamlinkPath)
        process.arguments = [
            resolvedTarget(from: target),
            quality,
            "--twitch-disable-ads",
            "--twitch-low-latency",
            "--output",
            outputURL.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.activeChannel = nil
                self.activeChannelLogin = nil
                self.activeChannelName = nil
                let didUserStop = self.userInitiatedStop
                self.userInitiatedStop = false
                if proc.terminationStatus != 0 && !didUserStop {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.errorMessage = message?.isEmpty == false ? message : "Recording stopped unexpectedly."
                }
                self.process = nil

                // Streamlink outputs MPEG-TS data even when the filename ends with .mp4.
                // Remux to a real MP4 so AVPlayer can play it.
                let shouldAttemptFinalize = proc.terminationStatus == 0 || didUserStop
                if shouldAttemptFinalize {
                    Task {
                        _ = try? await self.prepareRecordingForPlayback(at: outputURL)
                    }
                }
            }
        }

        do {
            try process.run()
            self.process = process
            lastOutputURL = outputURL
            activeChannel = channelName
            isRecording = true
            activeChannelLogin = resolvedChannelLogin
            activeChannelName = normalizedName?.isEmpty == false ? normalizedName : resolvedChannelLogin
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        userInitiatedStop = process != nil
        process?.terminate()
        process = nil
        isRecording = false
        activeChannel = nil
        activeChannelLogin = nil
        activeChannelName = nil
    }

    /// Ensures the given recording file is playable by AVPlayer.
    ///
    /// Streamlink writes MPEG transport stream data to disk by default. Even if the filename
    /// ends with `.mp4`, the file may actually be `.ts` data and will fail to play in AVPlayer.
    /// This method detects that case and remuxes the file in-place using ffmpeg.
    func prepareRecordingForPlayback(at url: URL) async throws -> (url: URL, didRemux: Bool) {
        guard url.isFileURL else { return (url, false) }
        let pathExt = url.pathExtension.lowercased()
        guard pathExt == "mp4" else { return (url, false) }

        // If the file already looks like a transport stream, remux it.
        guard isTransportStreamFile(at: url) else { return (url, false) }

        guard let ffmpegPath = resolveFFmpegPath() else {
            throw NSError(
                domain: "RecordingError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "FFmpeg was not found. Set it in Settings → Recording, or install ffmpeg (e.g. via Homebrew)."]
            )
        }

        let tempURL = uniqueTemporaryMP4URL(for: url)
        do {
            _ = try await runProcess(
                executable: ffmpegPath,
                arguments: [
                    "-y",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-i",
                    url.path,
                    "-c",
                    "copy",
                    "-movflags",
                    "+faststart",
                    "-bsf:a",
                    "aac_adtstoasc",
                    tempURL.path
                ]
            )

            // Atomically replace the original file with the remuxed MP4.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
            return (url, true)
        } catch {
            // Best-effort cleanup.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func resolveFFmpegPath() -> String? {
        let raw = UserDefaults.standard.string(forKey: "ffmpegPath") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        return resolveExecutable(named: "ffmpeg")
    }

    private func isTransportStreamFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 512),
              !data.isEmpty else {
            return false
        }

        func byte(at offset: Int) -> UInt8? {
            guard offset >= 0, offset < data.count else { return nil }
            return data[data.index(data.startIndex, offsetBy: offset)]
        }

        // MPEG-TS packets start with a sync byte 0x47 every 188 bytes.
        guard byte(at: 0) == 0x47 else { return false }
        if let b188 = byte(at: 188), b188 != 0x47 { return false }
        if let b376 = byte(at: 376), b376 != 0x47 { return false }
        return true
    }

    private func uniqueTemporaryMP4URL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let name = "\(base).remux-\(UUID().uuidString).mp4"
        return directory.appendingPathComponent(name)
    }

    private func resolvedTarget(from target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private func resolveStreamlinkPath() -> String? {
        let candidates = [
            UserDefaults.standard.string(forKey: "streamlinkPath"),
            bundledStreamlinkPath(),
            "/opt/homebrew/bin/streamlink",
            "/usr/local/bin/streamlink",
            "/usr/bin/streamlink"
        ]

        for candidate in candidates {
            guard let path = candidate, !path.isEmpty else { continue }
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func channelLogin(from target: String) -> String? {
        let resolved = resolvedTarget(from: target)
        guard let url = URL(string: resolved) else { return nil }
        guard let host = url.host?.lowercased(), host.contains("twitch.tv") else { return nil }
        let parts = url.path.split(separator: "/")
        guard let first = parts.first, !first.isEmpty else { return nil }
        return String(first).lowercased()
    }

    func installStreamlink() async {
        guard !isInstalling else { return }

        isInstalling = true
        installError = nil
        installStatus = "Preparing Streamlink installer..."

        defer {
            isInstalling = false
        }

        if let detected = resolveStreamlinkPath() {
            // Make the detected path explicit in Settings (so users can see what will be used).
            UserDefaults.standard.set(detected, forKey: "streamlinkPath")
            installStatus = "Streamlink is already available."
            return
        }

        guard let pythonPath = resolvePython3Path() else {
            installError = "Python 3 was not found. Install Streamlink with Homebrew (`brew install streamlink`) or set a custom Streamlink path."
            installStatus = nil
            return
        }

        do {
            let installDir = streamlinkInstallDirectory()
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

            let venvDir = installDir.appendingPathComponent("venv", isDirectory: true)
            if !FileManager.default.fileExists(atPath: venvDir.path) {
                installStatus = "Creating Python environment..."
                _ = try await runProcess(executable: pythonPath, arguments: ["-m", "venv", venvDir.path])
            }

            guard let venvPython = resolveVenvPython(at: venvDir) else {
                throw RecordingInstallError.missingBinary("python")
            }

            installStatus = "Preparing pip..."
            _ = try? await runProcess(executable: venvPython, arguments: ["-m", "ensurepip", "--upgrade"])

            let pipEnv: [String: String] = [
                "PIP_DISABLE_PIP_VERSION_CHECK": "1",
                "PIP_NO_INPUT": "1"
            ]

            installStatus = "Installing Streamlink..."
            _ = try? await runProcess(executable: venvPython, arguments: ["-m", "pip", "install", "--upgrade", "pip"], environment: pipEnv)
            _ = try await runProcess(executable: venvPython, arguments: ["-m", "pip", "install", "--upgrade", "streamlink"], environment: pipEnv)

            let streamlinkBinary = venvDir.appendingPathComponent("bin/streamlink").path
            guard FileManager.default.isExecutableFile(atPath: streamlinkBinary) else {
                throw RecordingInstallError.missingBinary("streamlink")
            }

            UserDefaults.standard.set(streamlinkBinary, forKey: "streamlinkPath")
            installStatus = "Streamlink installed."
        } catch {
            installError = error.localizedDescription
            installStatus = nil
        }
    }

    private func bundledStreamlinkPath() -> String? {
        Bundle.main.path(forResource: "streamlink", ofType: nil)
    }

    private func streamlinkInstallDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Glitcho", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("Streamlink", isDirectory: true)
    }

    private func resolvePython3Path() -> String? {
        resolveExecutable(named: "python3")
            ?? ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { path in
                FileManager.default.isExecutableFile(atPath: path)
            }
    }

    private func resolveVenvPython(at venvDir: URL) -> String? {
        let candidates = [
            venvDir.appendingPathComponent("bin/python3").path,
            venvDir.appendingPathComponent("bin/python").path
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func resolveExecutable(named name: String) -> String? {
        let fallbackPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathEntries = pathEnvironment.split(separator: ":").map(String.init)
        let searchPaths = pathEntries + fallbackPaths
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private struct ProcessOutput {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private struct ProcessExecutionError: LocalizedError {
        let executable: String
        let arguments: [String]
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var errorDescription: String? {
            let command = ([executable] + arguments).joined(separator: " ")
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return "Command failed (\(exitCode)): \(command)"
            }
            return "Command failed (\(exitCode)): \(command)\n\(message)"
        }
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, new in new })
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(decoding: stdoutData, as: UTF8.self)
                let stderr = String(decoding: stderrData, as: UTF8.self)
                let output = ProcessOutput(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus)

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(
                        throwing: ProcessExecutionError(
                            executable: executable,
                            arguments: arguments,
                            exitCode: proc.terminationStatus,
                            stdout: stdout,
                            stderr: stderr
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

#endif

private enum RecordingInstallError: LocalizedError {
    case missingBinary(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary(let name):
            return "Streamlink install failed: expected '\(name)' executable was not found."
        }
    }
}
