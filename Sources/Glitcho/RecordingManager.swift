import Foundation

#if canImport(SwiftUI)

final class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var lastOutputURL: URL?
    @Published var errorMessage: String?
    @Published var isInstalling = false
    @Published var installStatus: String?
    @Published var installError: String?

    private var process: Process?

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

        guard let streamlinkPath = resolveStreamlinkPath() else {
            errorMessage = "Streamlink is not installed. Use Settings > Recording to download it."
            return
        }

        let directory = recordingsDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Unable to create recordings folder: \(error.localizedDescription)"
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let safeChannel = (channelName ?? "twitch").replacingOccurrences(of: " ", with: "_")
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
                if proc.terminationStatus != 0 {
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
            isRecording = true
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        process?.terminate()
        process = nil
        isRecording = false
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
