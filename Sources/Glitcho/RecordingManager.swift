import Foundation
import Darwin

#if canImport(SwiftUI)

@MainActor
final class RecordingManager: ObservableObject {
    struct RecoveryIntent: Codable, Equatable {
        let target: String
        let channelLogin: String?
        let channelName: String?
        let quality: String
        let capturedAt: Date
    }

    @Published var isRecording = false
    @Published var activeChannel: String?
    @Published var activeChannelLogin: String?
    @Published var activeChannelName: String?
    @Published var lastOutputURL: URL?
    @Published var errorMessage: String?
    @Published private(set) var activeRecordingCount = 0
    @Published private(set) var backgroundRecordingCount = 0

    @Published var isInstalling = false
    @Published var installStatus: String?
    @Published var installError: String?

    @Published var isInstallingFFmpeg = false
    @Published var ffmpegInstallStatus: String?
    @Published var ffmpegInstallError: String?

    let recorderOrchestrator: RecorderOrchestrator

    private struct RecordingSession {
        let key: String
        let target: String
        let login: String?
        let channelName: String?
        let quality: String
        let outputURL: URL
        let process: Process
        let startedAt: Date
        var userInitiatedStop: Bool
    }

    private struct BackgroundAgentActiveSession: Decodable {
        let login: String
        let pid: Int32
    }

    struct RetentionResult {
        let deletedCount: Int
        let failedCount: Int
    }

    private struct QueuedRecordingRequest {
        let target: String
        let channelName: String?
        let quality: String
    }

    private var recordingSessions: [String: RecordingSession] = [:]
    private var queuedRecordingRequestsByLogin: [String: QueuedRecordingRequest] = [:]
    private var backgroundRecordingLogins: Set<String> = []
    private var backgroundRecordingMonitor: Timer?
    private var pendingRecoveryIntents: [RecoveryIntent] = []
    private let recoveryDefaultsKey = "recordingRecoveryIntents.v1"

    private let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Override ffmpeg path resolution (primarily for unit tests).
    var _resolveFFmpegPathOverride: (() -> String?)?
    /// Override streamlink path resolution (primarily for unit tests).
    var _resolveStreamlinkPathOverride: (() -> String?)?

    /// Override encryption manager (primarily for unit tests).
    var _encryptionManagerOverride: RecordingEncryptionManager?
    private let _encryptionManager = RecordingEncryptionManager()
    var effectiveEncryptionManager: RecordingEncryptionManager {
        _encryptionManagerOverride ?? _encryptionManager
    }

    init(recorderOrchestrator: RecorderOrchestrator? = nil) {
        self.recorderOrchestrator = recorderOrchestrator ?? RecorderOrchestrator()
        syncOrchestratorConcurrencyLimit()
        pendingRecoveryIntents = loadPersistedRecoveryIntents()
        refreshBackgroundRecordingState()
        startBackgroundRecordingMonitor()
        _ = enforceRetentionPoliciesNow()
        effectiveEncryptionManager.cleanupTempPlaybackFiles()
        let activeURLs = recordingSessions.values.map(\.outputURL)
        if let migrationResult = try? effectiveEncryptionManager.migrateUnencryptedRecordings(
            in: recordingsDirectory(),
            activeOutputURLs: activeURLs
        ), migrationResult.migratedCount > 0 {
            GlitchoTelemetry.track(
                "recordings_migration_completed",
                metadata: [
                    "migrated": "\(migrationResult.migratedCount)",
                    "skipped": "\(migrationResult.skippedCount)"
                ]
            )
        }
    }

    deinit {
        backgroundRecordingMonitor?.invalidate()
    }

    func consumeRecoveryIntents() -> [RecoveryIntent] {
        return pendingRecoveryIntents
    }

    func clearPendingRecoveryIntent(channelLogin: String) {
        let normalized = channelLogin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        pendingRecoveryIntents.removeAll { intent in
            normalizedChannelLogin(intent.channelLogin) == normalized
        }
        persistRecoveryIntents(from: Array(recordingSessions.values))
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

        // Try loading encrypted manifest first.
        if let manifest = try? effectiveEncryptionManager.loadManifest(from: directory), !manifest.isEmpty {
            return manifest.map { hashFilename, entry in
                let url = directory.appendingPathComponent(hashFilename)
                return RecordingEntry(url: url, channelName: entry.channelName, recordedAt: entry.date)
            }.sorted { left, right in
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

        // Fallback: scan for unencrypted .mp4 files (pre-migration state).
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

    func deleteRecording(at url: URL) throws {
        guard url.isFileURL else {
            throw NSError(
                domain: "RecordingError",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Recording path is invalid."]
            )
        }

        if isRecording(outputURL: url) {
            throw NSError(
                domain: "RecordingError",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "This recording is still in progress. Stop recording before deleting it."]
            )
        }

        // Remove from manifest if encrypted.
        if url.pathExtension == "glitcho" {
            let directory = recordingsDirectory()
            let mgr = effectiveEncryptionManager
            if var manifest = try? mgr.loadManifest(from: directory) {
                manifest.removeValue(forKey: url.lastPathComponent)
                try? mgr.saveManifest(manifest, to: directory)
            }
        }

        // Prefer moving to Trash to avoid accidental data loss.
        do {
            _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: url)
        }
    }
    func toggleRecording(target: String, channelName: String?, quality: String = "best") {
        let resolvedChannelLogin = channelLogin(from: target)
        if let resolvedChannelLogin, isRecording(channelLogin: resolvedChannelLogin) {
            stopRecording(channelLogin: resolvedChannelLogin)
            return
        }

        let key = recordingKey(target: target, channelLogin: resolvedChannelLogin)
        if recordingSessions[key] != nil {
            stopRecording(forKey: key)
            return
        }

        _ = startRecording(target: target, channelName: channelName, quality: quality)
    }

    @discardableResult
    func startRecording(target: String, channelName: String?, quality: String = "best") -> Bool {
        errorMessage = nil

        if !LicenseManager.shared.canUseRecording {
            let message = "No license detected. Email j.christophe@devjc.net for a Pro license key."
            errorMessage = message
            GlitchoTelemetry.track("recording_start_blocked_unlicensed")
            return false
        }

        let resolvedChannelLogin = channelLogin(from: target)
        if let resolvedChannelLogin,
           isRecordingInBackgroundAgent(channelLogin: resolvedChannelLogin) {
            let message = "This channel is already being recorded by the background recorder."
            errorMessage = message
            recorderOrchestrator.setError(for: resolvedChannelLogin, errorMessage: message)
            GlitchoTelemetry.track(
                "recording_start_blocked_background_active",
                metadata: ["login": resolvedChannelLogin]
            )
            return false
        }
        let sessionKey = recordingKey(target: target, channelLogin: resolvedChannelLogin)
        guard recordingSessions[sessionKey] == nil else { return false }

        if let resolvedChannelLogin,
           maybeQueueRecordingRequest(
               login: resolvedChannelLogin,
               target: target,
               channelName: channelName,
               quality: quality
           ) {
            return true
        }

        guard let streamlinkPath = resolveStreamlinkPath() else {
            let message = "Streamlink is not installed. Use Settings > Recording to download it or set a custom path."
            errorMessage = message
            recorderOrchestrator.setError(for: resolvedChannelLogin, errorMessage: message)
            GlitchoTelemetry.track(
                "recording_start_failed_streamlink_missing",
                metadata: ["login": resolvedChannelLogin ?? "unknown"]
            )
            return false
        }

        let directory = recordingsDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            let message = "Unable to create recordings folder: \(error.localizedDescription)"
            errorMessage = message
            recorderOrchestrator.setError(for: resolvedChannelLogin, errorMessage: message)
            GlitchoTelemetry.track(
                "recording_start_failed_directory",
                metadata: [
                    "login": resolvedChannelLogin ?? "unknown",
                    "error": error.localizedDescription
                ]
            )
            return false
        }

        let normalizedName = channelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = normalizedName?.isEmpty == false ? normalizedName : resolvedChannelLogin
        let resolvedRecordingTarget = resolvedTarget(from: target)
        if let resolvedChannelLogin {
            clearPendingRecoveryIntent(channelLogin: resolvedChannelLogin)
        }
        let timestamp = filenameDateFormatter.string(from: Date())
        let safeChannelBase = displayName ?? "twitch"
        let safeChannel = safeChannelBase.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeChannel)_\(timestamp).mp4"
        let outputURL = directory.appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: streamlinkPath)
        process.arguments = [
            resolvedRecordingTarget,
            quality,
            "--twitch-disable-ads",
            "--twitch-low-latency",
            "--output",
            outputURL.path
        ]

        let errorPipe = Pipe()
        let stderrLogURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("stderr.log")
        let stderrFileDescriptor: Int32? = {
            if FileManager.default.createFile(atPath: stderrLogURL.path, contents: nil),
               let fileHandle = try? FileHandle(forWritingTo: stderrLogURL) {
                process.standardError = fileHandle
                return fileHandle.fileDescriptor
            }
            process.standardError = errorPipe
            return nil
        }()

        process.terminationHandler = { [weak self] proc in
            if let fileDescriptor = stderrFileDescriptor {
                _ = Darwin.close(fileDescriptor)
            }

            Task { @MainActor in
                guard let self else { return }
                guard let session = self.recordingSessions.removeValue(forKey: sessionKey) else { return }
                self.syncPublishedRecordingState()

                let didUserStop = session.userInitiatedStop
                var failureMessage: String?
                if proc.terminationStatus != 0 && !didUserStop {
                    let data: Data
                    if stderrFileDescriptor != nil,
                       let fileData = try? Data(contentsOf: stderrLogURL) {
                        data = fileData
                    } else {
                        data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    }
                    let message = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedMessage = message?.isEmpty == false ? message : "Recording stopped unexpectedly."
                    self.errorMessage = resolvedMessage
                    failureMessage = resolvedMessage
                }

                try? FileManager.default.removeItem(at: stderrLogURL)

                if let login = session.login {
                    if didUserStop || proc.terminationStatus == 0 {
                        self.recorderOrchestrator.setIdle(for: login)
                        GlitchoTelemetry.track(
                            "recording_stopped",
                            metadata: [
                                "login": login,
                                "status": "\(proc.terminationStatus)",
                                "user_initiated": didUserStop ? "true" : "false"
                            ]
                        )
                    } else {
                        self.recorderOrchestrator.setError(for: login, errorMessage: failureMessage)
                        _ = self.recorderOrchestrator.scheduleRetry(for: login, errorMessage: failureMessage)
                        GlitchoTelemetry.track(
                            "recording_failed_retry_scheduled",
                            metadata: [
                                "login": login,
                                "status": "\(proc.terminationStatus)",
                                "error": failureMessage ?? "unknown"
                            ]
                        )
                    }
                }

                // Streamlink outputs MPEG-TS data even when the filename ends with .mp4.
                // Remux to a real MP4 so AVPlayer can play it.
                let shouldAttemptFinalize = proc.terminationStatus == 0 || didUserStop
                if shouldAttemptFinalize {
                    Task {
                        _ = try? await self.prepareRecordingForPlayback(at: session.outputURL)
                        self.encryptCompletedRecording(
                            at: session.outputURL,
                            channelName: session.channelName,
                            quality: session.quality
                        )
                    }
                }

                _ = self.enforceRetentionPoliciesNow()
                self.processQueuedRecordingsIfPossible()
            }
        }

        if let resolvedChannelLogin {
            recorderOrchestrator.setQueued(for: resolvedChannelLogin)
        }
        recordingSessions[sessionKey] = RecordingSession(
            key: sessionKey,
            target: resolvedRecordingTarget,
            login: resolvedChannelLogin,
            channelName: displayName,
            quality: quality,
            outputURL: outputURL,
            process: process,
            startedAt: Date(),
            userInitiatedStop: false
        )
        syncPublishedRecordingState()

        do {
            try process.run()
            if let resolvedChannelLogin {
                recorderOrchestrator.setRecording(for: resolvedChannelLogin)
                GlitchoTelemetry.track(
                    "recording_started",
                    metadata: ["login": resolvedChannelLogin, "quality": quality]
                )
            }
            return true
        } catch {
            recordingSessions.removeValue(forKey: sessionKey)
            syncPublishedRecordingState()
            let message = "Failed to start recording: \(error.localizedDescription)"
            errorMessage = message
            recorderOrchestrator.setError(for: resolvedChannelLogin, errorMessage: message)
            _ = recorderOrchestrator.scheduleRetry(for: resolvedChannelLogin, errorMessage: message)
            GlitchoTelemetry.track(
                "recording_start_failed_launch",
                metadata: [
                    "login": resolvedChannelLogin ?? "unknown",
                    "error": error.localizedDescription
                ]
            )
            return false
        }
    }

    func stopRecording(channelLogin: String) {
        guard let normalized = normalizedChannelLogin(channelLogin) else { return }
        if cancelQueuedRecording(login: normalized) {
            return
        }
        stopRecording(forKey: loginKey(for: normalized))
    }

    func stopRecording() {
        clearQueuedRecordings()
        for key in Array(recordingSessions.keys) {
            stopRecording(forKey: key)
        }
    }

    func isRecording(channelLogin: String?) -> Bool {
        guard let channelLogin, let normalized = normalizedChannelLogin(channelLogin) else { return false }
        return recordingSessions[loginKey(for: normalized)] != nil
    }

    func isRecording(outputURL: URL) -> Bool {
        let normalizedURL = outputURL.standardizedFileURL
        return recordingSessions.values.contains { $0.outputURL.standardizedFileURL == normalizedURL }
    }

    func isRecordingAny(channelLogin: String?) -> Bool {
        isRecording(channelLogin: channelLogin) || isRecordingInBackgroundAgent(channelLogin: channelLogin)
    }

    func isRecordingInBackgroundAgent(channelLogin: String?) -> Bool {
        guard let channelLogin, let normalized = normalizedChannelLogin(channelLogin) else { return false }
        return backgroundRecordingLogins.contains(normalized)
    }

    func isAnyRecordingIncludingBackground() -> Bool {
        !recordingSessions.isEmpty || !backgroundRecordingLogins.isEmpty
    }

    func refreshBackgroundRecordingStateNow() {
        refreshBackgroundRecordingState()
    }

    func recordingCountIncludingBackground() -> Int {
        let localLogins = Set(recordingSessions.values.compactMap { normalizedChannelLogin($0.login) })
        let localWithoutLoginCount = recordingSessions.values.filter { normalizedChannelLogin($0.login) == nil }.count
        return localLogins.union(backgroundRecordingLogins).count + localWithoutLoginCount
    }

    func recordingBadgeChannelIncludingBackground() -> String? {
        if let activeChannel {
            return activeChannel
        }
        return backgroundRecordingLogins.sorted().first
    }

    func streamlinkPathForBackgroundAgent() -> String? {
        resolveStreamlinkPath()
    }

    private func encryptCompletedRecording(at url: URL, channelName: String?, quality: String) {
        let directory = recordingsDirectory()
        let mgr = effectiveEncryptionManager

        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let result = try mgr.encryptFile(
                at: url,
                in: directory,
                channelName: channelName,
                quality: quality
            )

            var manifest = (try? mgr.loadManifest(from: directory)) ?? [:]
            manifest[result.hashFilename] = result.entry
            try mgr.saveManifest(manifest, to: directory)
        } catch {
            // If encryption fails, the original MP4 is preserved.
        }
    }

    private func stopRecording(forKey key: String) {
        guard var session = recordingSessions[key] else { return }
        if !session.userInitiatedStop {
            session.userInitiatedStop = true
            recordingSessions[key] = session
        }
        recorderOrchestrator.setStopping(for: session.login)
        GlitchoTelemetry.track(
            "recording_stop_requested",
            metadata: ["login": session.login ?? "unknown"]
        )
        session.process.terminate()
    }

    private func configuredConcurrencyLimit() -> Int {
        let raw = UserDefaults.standard.integer(forKey: "recordingConcurrencyLimit")
        if raw <= 0 {
            return 2
        }
        return min(max(raw, 1), 12)
    }

    private func syncOrchestratorConcurrencyLimit() {
        recorderOrchestrator.maxConcurrentRecordings = configuredConcurrencyLimit()
    }

    private func maybeQueueRecordingRequest(
        login: String,
        target: String,
        channelName: String?,
        quality: String
    ) -> Bool {
        syncOrchestratorConcurrencyLimit()

        if queuedRecordingRequestsByLogin[login] != nil {
            // Keep queued requests idempotent while waiting for capacity.
            if activeRecordingCount < recorderOrchestrator.maxConcurrentRecordings {
                queuedRecordingRequestsByLogin.removeValue(forKey: login)
                recorderOrchestrator.removeFromQueue(login: login)
                return false
            }
            return true
        }

        guard activeRecordingCount >= recorderOrchestrator.maxConcurrentRecordings else {
            return false
        }

        queuedRecordingRequestsByLogin[login] = QueuedRecordingRequest(
            target: target,
            channelName: channelName,
            quality: quality
        )
        recorderOrchestrator.setQueued(for: login)
        GlitchoTelemetry.track(
            "recording_queued_concurrency_limit",
            metadata: [
                "login": login,
                "limit": "\(recorderOrchestrator.maxConcurrentRecordings)"
            ]
        )
        return true
    }

    private func cancelQueuedRecording(login: String) -> Bool {
        guard queuedRecordingRequestsByLogin.removeValue(forKey: login) != nil else {
            return false
        }
        recorderOrchestrator.removeFromQueue(login: login)
        recorderOrchestrator.setIdle(for: login)
        GlitchoTelemetry.track(
            "recording_queue_canceled",
            metadata: ["login": login]
        )
        return true
    }

    private func processQueuedRecordingsIfPossible() {
        syncOrchestratorConcurrencyLimit()
        guard activeRecordingCount < recorderOrchestrator.maxConcurrentRecordings else { return }

        while activeRecordingCount < recorderOrchestrator.maxConcurrentRecordings {
            guard let login = recorderOrchestrator.dequeueNextQueuedLogin() else { break }
            guard let request = queuedRecordingRequestsByLogin.removeValue(forKey: login) else {
                recorderOrchestrator.setIdle(for: login)
                continue
            }

            GlitchoTelemetry.track(
                "recording_queue_dequeued",
                metadata: ["login": login]
            )
            _ = startRecording(
                target: request.target,
                channelName: request.channelName,
                quality: request.quality
            )
        }
    }

    private func clearQueuedRecordings() {
        let queuedLogins = Array(queuedRecordingRequestsByLogin.keys)
        guard !queuedLogins.isEmpty else { return }

        for login in queuedLogins {
            recorderOrchestrator.removeFromQueue(login: login)
            recorderOrchestrator.setIdle(for: login)
        }
        queuedRecordingRequestsByLogin.removeAll()
        GlitchoTelemetry.track(
            "recording_queue_cleared",
            metadata: ["count": "\(queuedLogins.count)"]
        )
    }

    private func retentionMaxAgeDays() -> Int {
        max(0, UserDefaults.standard.integer(forKey: "recordingsRetentionMaxAgeDays"))
    }

    private func retentionKeepLastGlobal() -> Int {
        max(0, UserDefaults.standard.integer(forKey: "recordingsRetentionKeepLastGlobal"))
    }

    private func retentionKeepLastPerChannel() -> Int {
        max(0, UserDefaults.standard.integer(forKey: "recordingsRetentionKeepLastPerChannel"))
    }

    func enforceRetentionPoliciesNow() -> RetentionResult {
        let maxAgeDays = retentionMaxAgeDays()
        let keepGlobal = retentionKeepLastGlobal()
        let keepPerChannel = retentionKeepLastPerChannel()

        if maxAgeDays == 0, keepGlobal == 0, keepPerChannel == 0 {
            return RetentionResult(deletedCount: 0, failedCount: 0)
        }

        let entries = listRecordings()
        guard !entries.isEmpty else {
            return RetentionResult(deletedCount: 0, failedCount: 0)
        }

        var toDelete = Set<URL>()

        if maxAgeDays > 0 {
            let threshold = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
            for entry in entries {
                guard let recordedAt = entry.recordedAt else { continue }
                if recordedAt < threshold {
                    toDelete.insert(entry.url)
                }
            }
        }

        let newestFirst = entries.sorted { lhs, rhs in
            switch (lhs.recordedAt, rhs.recordedAt) {
            case let (l?, r?):
                return l > r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
        }

        if keepGlobal > 0, newestFirst.count > keepGlobal {
            for entry in newestFirst.dropFirst(keepGlobal) {
                toDelete.insert(entry.url)
            }
        }

        if keepPerChannel > 0 {
            let grouped = Dictionary(grouping: newestFirst, by: { $0.channelName })
            for entriesForChannel in grouped.values where entriesForChannel.count > keepPerChannel {
                for entry in entriesForChannel.dropFirst(keepPerChannel) {
                    toDelete.insert(entry.url)
                }
            }
        }

        var deletedCount = 0
        var failedCount = 0
        for url in toDelete {
            guard !isRecording(outputURL: url) else { continue }
            do {
                try deleteRecording(at: url)
                deletedCount += 1
            } catch {
                failedCount += 1
            }
        }

        if deletedCount > 0 || failedCount > 0 {
            GlitchoTelemetry.track(
                "recordings_retention_enforced",
                metadata: [
                    "deleted": "\(deletedCount)",
                    "failed": "\(failedCount)",
                    "max_age_days": "\(maxAgeDays)",
                    "keep_global": "\(keepGlobal)",
                    "keep_per_channel": "\(keepPerChannel)"
                ]
            )
        }

        return RetentionResult(deletedCount: deletedCount, failedCount: failedCount)
    }

    private func syncPublishedRecordingState() {
        let sessions = recordingSessions.values.sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }

        persistRecoveryIntents(from: sessions)

        activeRecordingCount = sessions.count
        isRecording = !sessions.isEmpty

        guard let primary = sessions.first else {
            activeChannel = nil
            activeChannelLogin = nil
            activeChannelName = nil
            lastOutputURL = nil
            return
        }

        activeChannel = primary.channelName ?? primary.login
        activeChannelLogin = primary.login
        activeChannelName = primary.channelName ?? primary.login
        lastOutputURL = primary.outputURL
    }

    private func normalizedChannelLogin(_ login: String?) -> String? {
        guard let login else { return nil }
        let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func loginKey(for login: String) -> String {
        "login:\(login)"
    }

    private func recordingKey(target: String, channelLogin: String?) -> String {
        if let normalizedLogin = normalizedChannelLogin(channelLogin) {
            return loginKey(for: normalizedLogin)
        }
        return "target:\(resolvedTarget(from: target).lowercased())"
    }

    private func recoveryIntentKey(for intent: RecoveryIntent) -> String {
        if let normalizedLogin = normalizedChannelLogin(intent.channelLogin) {
            return loginKey(for: normalizedLogin)
        }
        return "target:\(intent.target.lowercased())"
    }

    private func persistRecoveryIntents(from sessions: [RecordingSession]) {
        let activeIntents = sessions.map { session in
            RecoveryIntent(
                target: session.target,
                channelLogin: session.login,
                channelName: session.channelName,
                quality: session.quality,
                capturedAt: session.startedAt
            )
        }

        var byKey: [String: RecoveryIntent] = [:]
        for intent in activeIntents {
            byKey[recoveryIntentKey(for: intent)] = intent
        }
        for intent in pendingRecoveryIntents {
            let key = recoveryIntentKey(for: intent)
            if byKey[key] == nil {
                byKey[key] = intent
            }
        }
        let intents = byKey.values.sorted { lhs, rhs in
            lhs.capturedAt > rhs.capturedAt
        }

        if let data = try? JSONEncoder().encode(intents) {
            UserDefaults.standard.set(data, forKey: recoveryDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: recoveryDefaultsKey)
        }
    }

    private func loadPersistedRecoveryIntents() -> [RecoveryIntent] {
        guard let data = UserDefaults.standard.data(forKey: recoveryDefaultsKey) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([RecoveryIntent].self, from: data) else {
            return []
        }

        var seen = Set<String>()
        return decoded
            .sorted { lhs, rhs in lhs.capturedAt > rhs.capturedAt }
            .filter { intent in
                let key = recoveryIntentKey(for: intent)
                guard !key.isEmpty else { return false }
                return seen.insert(key).inserted
            }
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
        if let override = _resolveFFmpegPathOverride {
            return override()
        }

        let raw = UserDefaults.standard.string(forKey: "ffmpegPath") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        return Glitcho.resolveExecutable(named: "ffmpeg")
    }

    func isTransportStreamFile(at url: URL) -> Bool {
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
        if let override = _resolveStreamlinkPathOverride {
            return override()
        }

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

    private func backgroundAgentSessionsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Glitcho", isDirectory: true)
            .appendingPathComponent("BackgroundRecorder", isDirectory: true)
            .appendingPathComponent("ActiveSessions", isDirectory: true)
    }

    private func startBackgroundRecordingMonitor() {
        backgroundRecordingMonitor?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshBackgroundRecordingState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundRecordingMonitor = timer
    }

    private func refreshBackgroundRecordingState() {
        let logins = currentBackgroundRecordingLogins()
        if logins != backgroundRecordingLogins {
            backgroundRecordingLogins = logins
            backgroundRecordingCount = logins.count
        } else if backgroundRecordingCount != logins.count {
            backgroundRecordingCount = logins.count
        }
    }

    private func currentBackgroundRecordingLogins() -> Set<String> {
        let directory = backgroundAgentSessionsDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var logins = Set<String>()
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode(BackgroundAgentActiveSession.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let login = decoded.login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !login.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard isProcessAlive(decoded.pid) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            logins.insert(login)
        }

        return logins
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
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

    func installFFmpeg() async {
        guard !isInstallingFFmpeg else { return }

        isInstallingFFmpeg = true
        ffmpegInstallError = nil
        ffmpegInstallStatus = "Preparing FFmpeg installer..."

        defer {
            isInstallingFFmpeg = false
        }

        if let detected = resolveFFmpegPath() {
            // Make the detected path explicit in Settings (so users can see what will be used).
            UserDefaults.standard.set(detected, forKey: "ffmpegPath")
            ffmpegInstallStatus = "FFmpeg is already available."
            return
        }

        // Prefer Homebrew when available (best chance of matching the user's CPU architecture).
        if let brewPath = Glitcho.resolveExecutable(named: "brew") {
            do {
                ffmpegInstallStatus = "Installing FFmpeg with Homebrew..."
                _ = try await runProcess(executable: brewPath, arguments: ["install", "ffmpeg"])

                if let detected = resolveFFmpegPath() {
                    UserDefaults.standard.set(detected, forKey: "ffmpegPath")
                    ffmpegInstallStatus = "FFmpeg installed."
                    return
                }

                // Fall through to direct download if brew succeeded but ffmpeg is still not resolvable.
                ffmpegInstallStatus = "FFmpeg installed via Homebrew, but wasn't found in PATH. Downloading a standalone build..."
            } catch {
                // If brew fails (not installed / not configured), fall back to direct download.
                ffmpegInstallStatus = "Homebrew install failed. Downloading a standalone build..."
            }
        }

        func desiredFFmpegDownloadArch() -> String {
#if arch(arm64)
            return "arm64"
#else
            return "amd64"
#endif
        }

        func isZipFile(at url: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 4)) ?? Data()
            // ZIP files start with "PK" (0x50 0x4B). Allow empty check too.
            return data.count >= 2 && data[0] == 0x50 && data[1] == 0x4B
        }

        func sniffTextPrefix(at url: URL, maxBytes: Int = 2048) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
            guard !data.isEmpty else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        do {
            let installDir = ffmpegInstallDirectory()
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

            // evermeet.cx (previous source) now frequently returns an HTML error page instead of a ZIP.
            // Use Martin Riedl's build server which provides stable redirect URLs for automation.
            let arch = desiredFFmpegDownloadArch()
            let downloadURL = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/release/ffmpeg.zip")!
            let tempZip = installDir.appendingPathComponent("ffmpeg.zip")
            let extractDir = installDir.appendingPathComponent("extract", isDirectory: true)

            ffmpegInstallStatus = "Downloading FFmpeg..."
            let (downloadedURL, response) = try await URLSession.shared.download(from: downloadURL)

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw NSError(
                    domain: "RecordingError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "FFmpeg download failed (HTTP \(http.statusCode))."]
                )
            }

            // Replace any previous download.
            try? FileManager.default.removeItem(at: tempZip)
            try FileManager.default.moveItem(at: downloadedURL, to: tempZip)

            // Sanity check: ensure we actually downloaded a ZIP.
            guard isZipFile(at: tempZip) else {
                let prefix = sniffTextPrefix(at: tempZip) ?? "(unreadable)"
                try? FileManager.default.removeItem(at: tempZip)
                throw NSError(
                    domain: "RecordingError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "FFmpeg download did not return a ZIP archive. Received: \(prefix.prefix(400))"]
                )
            }

            // Fresh extract directory.
            try? FileManager.default.removeItem(at: extractDir)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            ffmpegInstallStatus = "Extracting FFmpeg..."
            do {
                _ = try await runProcess(executable: "/usr/bin/ditto", arguments: ["-x", "-k", tempZip.path, extractDir.path])
            } catch {
                // Fallback: some macOS configurations behave better with unzip.
                _ = try await runProcess(executable: "/usr/bin/unzip", arguments: ["-o", "-q", tempZip.path, "-d", extractDir.path])
            }

            guard let extractedBinary = findBinary(named: "ffmpeg", in: extractDir) else {
                throw RecordingFFmpegInstallError.missingBinary("ffmpeg")
            }

            let finalBinaryURL = installDir.appendingPathComponent("ffmpeg")
            try? FileManager.default.removeItem(at: finalBinaryURL)
            try FileManager.default.copyItem(at: extractedBinary, to: finalBinaryURL)

            // Make executable.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: finalBinaryURL.path)

            // Best-effort: remove quarantine if present.
            _ = try? await runProcess(executable: "/usr/bin/xattr", arguments: ["-d", "com.apple.quarantine", finalBinaryURL.path])

            UserDefaults.standard.set(finalBinaryURL.path, forKey: "ffmpegPath")
            ffmpegInstallStatus = "FFmpeg installed."

            // Cleanup.
            try? FileManager.default.removeItem(at: extractDir)
            try? FileManager.default.removeItem(at: tempZip)
        } catch {
            ffmpegInstallError = error.localizedDescription
            ffmpegInstallStatus = nil
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

    private func ffmpegInstallDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Glitcho", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("FFmpeg", isDirectory: true)
    }

    private func resolvePython3Path() -> String? {
        Glitcho.resolveExecutable(named: "python3")
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

    private func findBinary(named name: String, in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() {
            guard let url = item as? URL else { continue }
            guard url.lastPathComponent == name else { continue }
            return url
        }

        return nil
    }


    struct ProcessOutput {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    struct ProcessExecutionError: LocalizedError {
        let executable: String
        let arguments: [String]
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var errorDescription: String? {
            func shellQuoted(_ value: String) -> String {
                // For display only (not execution). Keep it simple and readable.
                if value.isEmpty { return "\"\"" }
                let needsQuotes = value.contains(where: { $0.isWhitespace }) || value.contains("\"")
                guard needsQuotes else { return value }
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }

            let command = ([executable] + arguments).map(shellQuoted).joined(separator: " ")
            let stderrMessage = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutMessage = stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            if !stderrMessage.isEmpty {
                return "Command failed (\(exitCode)): \(command)\n\(stderrMessage)"
            }
            if !stdoutMessage.isEmpty {
                return "Command failed (\(exitCode)): \(command)\n\(stdoutMessage)"
            }
            return "Command failed (\(exitCode)): \(command)"
        }
    }

    func runProcess(
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

private enum RecordingFFmpegInstallError: LocalizedError {
    case missingBinary(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary(let name):
            return "FFmpeg install failed: expected '\(name)' executable was not found."
        }
    }
}
