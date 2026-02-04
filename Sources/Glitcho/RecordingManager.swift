import Foundation

#if canImport(SwiftUI)

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
        installStatus = "Checking latest Streamlink release..."

        do {
            let asset = try await fetchLatestStreamlinkAsset()
            installStatus = "Downloading Streamlink..."
            let archiveURL = try await downloadAsset(from: asset.downloadURL, filename: asset.name)
            installStatus = "Installing Streamlink..."
            let binaryPath = try installArchive(at: archiveURL)
            UserDefaults.standard.set(binaryPath, forKey: "streamlinkPath")
            installStatus = "Streamlink installed."
        } catch {
            installError = error.localizedDescription
            installStatus = nil
        }

        isInstalling = false
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

    private func fetchLatestStreamlinkAsset() async throws -> StreamlinkAsset {
        let api = URL(string: "https://api.github.com/repos/streamlink/streamlink/releases/latest")!
        let (data, _) = try await URLSession.shared.data(from: api)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let assets = release.assets
        let preferred = preferredAssetMatch(from: assets)
        guard let asset = preferred else {
            throw RecordingInstallError.missingAsset
        }
        return StreamlinkAsset(name: asset.name, downloadURL: asset.browserDownloadURL)
    }

    private func preferredAssetMatch(from assets: [GitHubRelease.Asset]) -> GitHubRelease.Asset? {
        let suffix = ".zip"
        let isAppleSilicon = (ProcessInfo.processInfo.environment["PROCESSOR_ARCHITECTURE"] ?? "").contains("ARM")
        let preferArm = isAppleSilicon || (ProcessInfo.processInfo.machineArchitecture?.contains("arm") ?? false)
        let filtered = assets.filter { $0.name.hasSuffix(suffix) && $0.name.lowercased().contains("macos") }

        let priority = filtered.sorted { lhs, rhs in
            scoreAsset(lhs, preferArm: preferArm) > scoreAsset(rhs, preferArm: preferArm)
        }
        return priority.first
    }

    private func scoreAsset(_ asset: GitHubRelease.Asset, preferArm: Bool) -> Int {
        let name = asset.name.lowercased()
        var score = 0
        if name.contains("universal") { score += 4 }
        if preferArm, name.contains("arm") { score += 3 }
        if !preferArm, (name.contains("x86") || name.contains("intel")) { score += 3 }
        if name.contains("macos") || name.contains("osx") { score += 2 }
        return score
    }

    private func downloadAsset(from url: URL, filename: String) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecordingInstallError.downloadFailed
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func installArchive(at archiveURL: URL) throws -> String {
        let installDir = streamlinkInstallDirectory()
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archiveURL.path, "-d", installDir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecordingInstallError.unzipFailed
        }

        guard let binary = findStreamlinkBinary(in: installDir) else {
            throw RecordingInstallError.missingBinary
        }

        let finalPath = installDir.appendingPathComponent("streamlink")
        if FileManager.default.fileExists(atPath: finalPath.path) {
            try? FileManager.default.removeItem(at: finalPath)
        }
        try FileManager.default.copyItem(at: binary, to: finalPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: finalPath.path)
        return finalPath.path
    }

    private func findStreamlinkBinary(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == "streamlink" {
                return fileURL
            }
        }
        return nil
    }
}

#endif

private struct StreamlinkAsset {
    let name: String
    let downloadURL: URL
}

private enum RecordingInstallError: LocalizedError {
    case missingAsset
    case downloadFailed
    case unzipFailed
    case missingBinary

    var errorDescription: String? {
        switch self {
        case .missingAsset:
            return "Unable to find a macOS Streamlink download."
        case .downloadFailed:
            return "Failed to download Streamlink."
        case .unzipFailed:
            return "Failed to extract the Streamlink archive."
        case .missingBinary:
            return "Streamlink binary not found after extraction."
        }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let assets: [Asset]
}

private extension ProcessInfo {
    var machineArchitecture: String? {
        #if os(macOS)
        return (self.environment["HW_MACHINE"] ?? self.environment["PROCESSOR_ARCHITECTURE"])
        #else
        return self.environment["PROCESSOR_ARCHITECTURE"]
        #endif
    }
}
