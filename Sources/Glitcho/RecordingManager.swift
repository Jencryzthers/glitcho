import Foundation

#if canImport(SwiftUI)

final class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var activeChannel: String?
    @Published var lastOutputURL: URL?
    @Published var errorMessage: String?
    @Published var activeChannelLogin: String?
    @Published var activeChannelName: String?

    private var process: Process?
    private var userInitiatedStop = false

    deinit {
        stopRecording()
    }

    func recordingsDirectory() -> URL {
        if let saved = UserDefaults.standard.string(forKey: "recordingsDirectory"),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: saved)
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return (downloads ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Glitcho Recordings", isDirectory: true)
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
            errorMessage = "Streamlink is not installed. Please install it or update the path in Settings."
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let safeChannel = (normalizedName?.isEmpty == false ? normalizedName : resolvedChannelLogin ?? "twitch")
            .replacingOccurrences(of: " ", with: "_")
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
            DispatchQueue.main.async {
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
}

#endif
