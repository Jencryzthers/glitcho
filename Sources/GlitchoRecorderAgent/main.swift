import Foundation
import Darwin

struct AgentChannel: Codable, Equatable {
    let login: String
    let displayName: String?
}

struct AgentConfig: Codable, Equatable {
    let version: Int
    let enabled: Bool
    let streamlinkPath: String?
    let recordingsDirectory: String
    let quality: String
    let pollIntervalSeconds: Double
    let channels: [AgentChannel]
}

private struct RetryState {
    var attempts: Int
    var nextAttemptAt: Date
}

private struct RecordingSession {
    let process: Process
    let errorPipe: Pipe
    let startedAt: Date
    let outputURL: URL
}

private struct ActiveSessionLock: Codable {
    let login: String
    let pid: Int32
    let outputPath: String
    let startedAt: Date
}

final class RecorderAgent {
    private let configPath: URL
    private let activeSessionsDirectory: URL
    private var config = AgentConfig(
        version: 1,
        enabled: false,
        streamlinkPath: nil,
        recordingsDirectory: "",
        quality: "best",
        pollIntervalSeconds: 25,
        channels: []
    )

    private var configLastModifiedAt: Date?
    private var sessions: [String: RecordingSession] = [:]
    private var retryByLogin: [String: RetryState] = [:]

    private let defaultPollInterval: TimeInterval = 2

    init(configPath: URL) {
        self.configPath = configPath
        self.activeSessionsDirectory = configPath
            .deletingLastPathComponent()
            .appendingPathComponent("ActiveSessions", isDirectory: true)
    }

    func run() {
        print("[RecorderAgent] Starting. Config: \(configPath.path)")
        prepareActiveSessionsDirectory()
        clearActiveSessionLocks()

        while true {
            autoreleasepool {
                loadConfigIfNeeded()
                reapExitedProcesses()
                reconcileDesiredSessions()
            }
            Thread.sleep(forTimeInterval: defaultPollInterval)
        }
    }

    private func loadConfigIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath.path) else { return }

        guard let attrs = try? fm.attributesOfItem(atPath: configPath.path),
              let modifiedAt = attrs[.modificationDate] as? Date else {
            return
        }

        if let configLastModifiedAt, modifiedAt <= configLastModifiedAt {
            return
        }

        do {
            let data = try Data(contentsOf: configPath)
            let decoded = try JSONDecoder().decode(AgentConfig.self, from: data)
            config = decoded
            configLastModifiedAt = modifiedAt
            print("[RecorderAgent] Config updated. Enabled: \(decoded.enabled), channels: \(decoded.channels.count)")
        } catch {
            print("[RecorderAgent] Failed to load config: \(error.localizedDescription)")
        }
    }

    private func reapExitedProcesses() {
        for (login, session) in Array(sessions) {
            if session.process.isRunning { continue }

            let status = session.process.terminationStatus
            let stderrData = session.errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

            sessions.removeValue(forKey: login)
            removeActiveSessionLock(for: login)

            if status == 0 {
                retryByLogin[login] = RetryState(attempts: 0, nextAttemptAt: Date().addingTimeInterval(15))
                continue
            }

            let nextAttempt = nextRetryState(for: login)
            retryByLogin[login] = nextAttempt
            if stderr.isEmpty {
                print("[RecorderAgent] Recording failed for \(login) (status \(status)); retry at \(nextAttempt.nextAttemptAt)")
            } else {
                print("[RecorderAgent] Recording failed for \(login) (status \(status)): \(stderr)")
            }
        }
    }

    private func nextRetryState(for login: String) -> RetryState {
        let current = retryByLogin[login]?.attempts ?? 0
        let nextAttemptCount = min(current + 1, 8)
        let delay = min(pow(2, Double(max(nextAttemptCount - 1, 0))) * 10, 300)
        return RetryState(attempts: nextAttemptCount, nextAttemptAt: Date().addingTimeInterval(delay))
    }

    private func reconcileDesiredSessions() {
        let desiredChannels = normalizedChannels(from: config.channels)
        let desiredLogins = Set(desiredChannels.map(\.login))

        // Stop sessions no longer desired or when disabled.
        for (login, session) in sessions {
            if !config.enabled || !desiredLogins.contains(login) {
                session.process.terminate()
            }
        }

        guard config.enabled else { return }

        guard let streamlinkPath = resolveStreamlinkPath() else {
            print("[RecorderAgent] Streamlink path not found")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: config.recordingsDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            print("[RecorderAgent] Unable to create recordings directory: \(error.localizedDescription)")
            return
        }

        let now = Date()
        for channel in desiredChannels {
            let login = channel.login
            if let session = sessions[login], session.process.isRunning { continue }
            if let retry = retryByLogin[login], now < retry.nextAttemptAt { continue }

            do {
                try startRecording(channel: channel, streamlinkPath: streamlinkPath)
                retryByLogin[login] = RetryState(attempts: 0, nextAttemptAt: now.addingTimeInterval(max(10, config.pollIntervalSeconds)))
            } catch {
                let nextAttempt = nextRetryState(for: login)
                retryByLogin[login] = nextAttempt
                print("[RecorderAgent] Failed to start recording for \(login): \(error.localizedDescription)")
            }
        }
    }

    private func normalizedChannels(from channels: [AgentChannel]) -> [AgentChannel] {
        var seen = Set<String>()
        return channels.compactMap { channel in
            let login = channel.login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !login.isEmpty else { return nil }
            guard seen.insert(login).inserted else { return nil }
            let name = channel.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentChannel(login: login, displayName: (name?.isEmpty == false) ? name : nil)
        }
        .sorted { lhs, rhs in
            lhs.login.localizedCaseInsensitiveCompare(rhs.login) == .orderedAscending
        }
    }

    private func resolveStreamlinkPath() -> String? {
        if let configured = config.streamlinkPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }

        let candidates = [
            "/opt/homebrew/bin/streamlink",
            "/usr/local/bin/streamlink",
            "/usr/bin/streamlink"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func startRecording(channel: AgentChannel, streamlinkPath: String) throws {
        let display = channel.displayName?.isEmpty == false ? channel.displayName! : channel.login
        let safeName = display.replacingOccurrences(of: " ", with: "_")
        let timestamp = Self.filenameDateFormatter.string(from: Date())
        let outputURL = URL(fileURLWithPath: config.recordingsDirectory, isDirectory: true)
            .appendingPathComponent("\(safeName)_\(timestamp).mp4")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: streamlinkPath)
        process.arguments = [
            "https://twitch.tv/\(channel.login)",
            config.quality,
            "--twitch-disable-ads",
            "--twitch-low-latency",
            "--output",
            outputURL.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()

        sessions[channel.login] = RecordingSession(
            process: process,
            errorPipe: errorPipe,
            startedAt: Date(),
            outputURL: outputURL
        )
        writeActiveSessionLock(for: channel.login, pid: process.processIdentifier, outputURL: outputURL)
        print("[RecorderAgent] Started recording \(channel.login)")
    }

    private func prepareActiveSessionsDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: activeSessionsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("[RecorderAgent] Failed to prepare active sessions directory: \(error.localizedDescription)")
        }
    }

    private func clearActiveSessionLocks() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: activeSessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func lockFileURL(for login: String) -> URL {
        let safe = login
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/", with: "_")
        return activeSessionsDirectory.appendingPathComponent("\(safe).json")
    }

    private func writeActiveSessionLock(for login: String, pid: Int32, outputURL: URL) {
        let lock = ActiveSessionLock(
            login: login.lowercased(),
            pid: pid,
            outputPath: outputURL.path,
            startedAt: Date()
        )

        do {
            let data = try JSONEncoder().encode(lock)
            try data.write(to: lockFileURL(for: login), options: .atomic)
        } catch {
            print("[RecorderAgent] Failed to write active lock for \(login): \(error.localizedDescription)")
        }
    }

    private func removeActiveSessionLock(for login: String) {
        try? FileManager.default.removeItem(at: lockFileURL(for: login))
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

private func parseConfigPath(from arguments: [String]) -> String? {
    var iterator = arguments.makeIterator()
    while let current = iterator.next() {
        if current == "--config" {
            return iterator.next()
        }
    }
    return nil
}

guard let configPathArgument = parseConfigPath(from: Array(CommandLine.arguments.dropFirst())) else {
    fputs("Usage: GlitchoRecorderAgent --config <path>\n", stderr)
    exit(2)
}

let agent = RecorderAgent(configPath: URL(fileURLWithPath: configPathArgument))
agent.run()
