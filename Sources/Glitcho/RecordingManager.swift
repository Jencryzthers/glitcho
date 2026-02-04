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
    private let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

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
        let timestamp = filenameDateFormatter.string(from: Date())
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
