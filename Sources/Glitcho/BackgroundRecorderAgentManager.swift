#if canImport(SwiftUI)
import Foundation
import Darwin

struct BackgroundRecorderAgentChannel: Codable, Equatable {
    let login: String
    let displayName: String?
}

struct BackgroundRecorderAgentConfig: Codable, Equatable {
    let version: Int
    let enabled: Bool
    let streamlinkPath: String?
    let recordingsDirectory: String
    let quality: String
    let pollIntervalSeconds: Double
    let channels: [BackgroundRecorderAgentChannel]
    let manualRecordings: [BackgroundRecorderAgentChannel]?
}

@MainActor
final class BackgroundRecorderAgentManager: ObservableObject {
    static let launchAgentLabel = "com.glitcho.recorder-agent"

    private var lastConfigData: Data?
    private var lastEffectiveEnabled: Bool?

    private var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Glitcho", isDirectory: true)
            .appendingPathComponent("BackgroundRecorder", isDirectory: true)
    }

    private var installedHelperPath: URL {
        appSupportDirectory.appendingPathComponent("GlitchoRecorderAgent")
    }

    private var configPath: URL {
        appSupportDirectory.appendingPathComponent("config.json")
    }

    private var logsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    private var launchAgentPlistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.launchAgentLabel).plist")
    }

    private var launchAgentStdoutPath: URL {
        logsDirectory.appendingPathComponent("agent.stdout.log")
    }

    private var launchAgentStderrPath: URL {
        logsDirectory.appendingPathComponent("agent.stderr.log")
    }

    private let manualRecordingsDefaultsKey = "backgroundRecorder.manualRecordings.v1"
    
    private var manualRecordings: [BackgroundRecorderAgentChannel] {
        get {
            guard let data = UserDefaults.standard.data(forKey: manualRecordingsDefaultsKey),
                  let decoded = try? JSONDecoder().decode([BackgroundRecorderAgentChannel].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(encoded, forKey: manualRecordingsDefaultsKey)
            }
        }
    }
    
    func addManualRecording(login: String, displayName: String?) {
        let channel = BackgroundRecorderAgentChannel(login: login.lowercased(), displayName: displayName)
        var recordings = manualRecordings
        if !recordings.contains(where: { $0.login == channel.login }) {
            recordings.append(channel)
            manualRecordings = recordings
        }
    }
    
    func removeManualRecording(login: String) {
        let normalized = login.lowercased()
        var recordings = manualRecordings
        recordings.removeAll { $0.login == normalized }
        manualRecordings = recordings
    }
    
    func sync(
        enabled: Bool,
        channels: [BackgroundRecorderAgentChannel],
        streamlinkPath: String?,
        recordingsDirectory: String,
        quality: String = "best"
    ) {
        do {
            let normalizedChannels = deduplicatedChannels(channels)
            let normalizedManual = deduplicatedChannels(manualRecordings)
            let effectiveEnabled = enabled && !normalizedChannels.isEmpty
            let hasManualRecordings = !normalizedManual.isEmpty
            let shouldBeRunning = effectiveEnabled || hasManualRecordings

            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            try installHelperBinaryIfNeeded()

            let config = BackgroundRecorderAgentConfig(
                version: 1,
                enabled: effectiveEnabled,
                streamlinkPath: normalizedPath(streamlinkPath),
                recordingsDirectory: recordingsDirectory,
                quality: quality,
                pollIntervalSeconds: 25,
                channels: normalizedChannels,
                manualRecordings: normalizedManual
            )

            let configData = try JSONEncoder().encode(config)
            if configData != lastConfigData || !FileManager.default.fileExists(atPath: configPath.path) {
                try configData.write(to: configPath, options: .atomic)
                lastConfigData = configData
            }

            try writeLaunchAgentPlist()

            if shouldBeRunning {
                if lastEffectiveEnabled != true {
                    try ensureAgentRunning()
                }
            } else if lastEffectiveEnabled != false {
                stopAgent()
            }
            lastEffectiveEnabled = shouldBeRunning
        } catch {
            print("[BackgroundRecorderAgent] Sync failed: \(error.localizedDescription)")
        }
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func deduplicatedChannels(_ channels: [BackgroundRecorderAgentChannel]) -> [BackgroundRecorderAgentChannel] {
        var seen = Set<String>()
        return channels.compactMap { channel in
            let login = channel.login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !login.isEmpty else { return nil }
            guard seen.insert(login).inserted else { return nil }
            let trimmedName = channel.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BackgroundRecorderAgentChannel(
                login: login,
                displayName: (trimmedName?.isEmpty == false) ? trimmedName : nil
            )
        }
        .sorted { lhs, rhs in
            lhs.login.localizedCaseInsensitiveCompare(rhs.login) == .orderedAscending
        }
    }

    private func bundledHelperPath() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("GlitchoRecorderAgent")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private func installHelperBinaryIfNeeded() throws {
        guard let bundledPath = bundledHelperPath() else {
            throw NSError(
                domain: "BackgroundRecorderAgent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled recorder agent binary is missing."]
            )
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: installedHelperPath.path) {
            let bundledData = try Data(contentsOf: bundledPath)
            let installedData = try Data(contentsOf: installedHelperPath)
            if bundledData == installedData {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHelperPath.path)
                return
            }
            try fileManager.removeItem(at: installedHelperPath)
        }

        try fileManager.copyItem(at: bundledPath, to: installedHelperPath)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHelperPath.path)
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func writeLaunchAgentPlist() throws {
        try FileManager.default.createDirectory(
            at: launchAgentPlistPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let helper = xmlEscaped(installedHelperPath.path)
        let config = xmlEscaped(configPath.path)
        let stdout = xmlEscaped(launchAgentStdoutPath.path)
        let stderr = xmlEscaped(launchAgentStderrPath.path)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helper)</string>
                <string>--config</string>
                <string>\(config)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(stdout)</string>
            <key>StandardErrorPath</key>
            <string>\(stderr)</string>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """

        try plist.write(to: launchAgentPlistPath, atomically: true, encoding: .utf8)
    }

    private func launchctlTarget() -> String {
        "gui/\(getuid())"
    }

    private func runLaunchctl(_ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 && !allowFailure {
            let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? "launchctl exited with \(process.terminationStatus)" : stderr
            throw NSError(
                domain: "BackgroundRecorderAgent",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func ensureAgentRunning() throws {
        let target = launchctlTarget()
        let plistPath = launchAgentPlistPath.path
        let label = "\(target)/\(Self.launchAgentLabel)"

        // Bootstrap may fail if already loaded; kickstart still refreshes if present.
        try runLaunchctl(["bootstrap", target, plistPath], allowFailure: true)
        try runLaunchctl(["enable", label], allowFailure: true)
        try runLaunchctl(["kickstart", "-k", label], allowFailure: true)
    }

    private func stopAgent() {
        let target = launchctlTarget()
        let plistPath = launchAgentPlistPath.path
        try? runLaunchctl(["bootout", target, plistPath], allowFailure: true)
    }
}

#endif
