import Foundation
import Darwin
import UserNotifications

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

    enum DownloadTaskState: String, Codable, Hashable {
        case queued
        case running
        case completed
        case failed
        case paused
        case canceled
    }

    struct DownloadTask: Identifiable, Codable, Hashable {
        let id: String
        let target: String
        let channelName: String?
        let quality: String
        let captureType: RecordingCaptureType
        var outputURL: URL?
        var startedAt: Date?
        var updatedAt: Date
        var progressFraction: Double?
        var bytesWritten: Int64
        var statusMessage: String?
        var lastErrorMessage: String?
        var retryCount: Int
        var state: DownloadTaskState

        private enum CodingKeys: String, CodingKey {
            case id
            case target
            case channelName
            case quality
            case captureType
            case outputURL
            case startedAt
            case updatedAt
            case progressFraction
            case bytesWritten
            case statusMessage
            case lastErrorMessage
            case retryCount
            case state
        }

        init(
            id: String,
            target: String,
            channelName: String?,
            quality: String,
            captureType: RecordingCaptureType,
            outputURL: URL?,
            startedAt: Date?,
            updatedAt: Date,
            progressFraction: Double?,
            bytesWritten: Int64,
            statusMessage: String?,
            lastErrorMessage: String?,
            retryCount: Int,
            state: DownloadTaskState
        ) {
            self.id = id
            self.target = target
            self.channelName = channelName
            self.quality = quality
            self.captureType = captureType
            self.outputURL = outputURL
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.progressFraction = progressFraction
            self.bytesWritten = bytesWritten
            self.statusMessage = statusMessage
            self.lastErrorMessage = lastErrorMessage
            self.retryCount = retryCount
            self.state = state
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            target = try container.decode(String.self, forKey: .target)
            channelName = try container.decodeIfPresent(String.self, forKey: .channelName)
            quality = try container.decode(String.self, forKey: .quality)
            captureType = try container.decode(RecordingCaptureType.self, forKey: .captureType)
            outputURL = try container.decodeIfPresent(URL.self, forKey: .outputURL)
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            progressFraction = try container.decodeIfPresent(Double.self, forKey: .progressFraction)
            bytesWritten = try container.decodeIfPresent(Int64.self, forKey: .bytesWritten) ?? 0
            statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
            lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
            retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
            state = try container.decode(DownloadTaskState.self, forKey: .state)
        }

        var displayName: String {
            if let channelName, !channelName.isEmpty {
                return channelName
            }
            if let outputURL {
                return outputURL.deletingPathExtension().lastPathComponent
            }
            return target
        }

        var canResume: Bool {
            state == .failed || state == .canceled || state == .paused
        }
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

    @Published var autoStoppedRecordings: [String] = []
    @Published private(set) var downloadTasks: [DownloadTask] = []

    let recorderOrchestrator: RecorderOrchestrator
    private let recordingEncryptionManager = RecordingEncryptionManager()

    private struct RecordingSession {
        let key: String
        let target: String
        let login: String?
        let channelName: String?
        let captureType: RecordingCaptureType
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

    struct LibraryIntegrityReport {
        let scannedAt: Date
        let manifestEntryCount: Int
        let encryptedFileCount: Int
        let orphanedManifestEntries: [String]
        let missingThumbnailEntries: [String]
        let orphanedThumbnailEntries: [String]
        let unreadableFiles: [URL]

        var issueCount: Int {
            orphanedManifestEntries.count
                + unreadableFiles.count
        }
    }

    struct LibraryIntegrityRepairResult {
        let reportBefore: LibraryIntegrityReport
        let removedManifestEntries: Int
        let regeneratedThumbnails: Int
        let removedOrphanedThumbnails: Int
        let unresolvedUnreadableFiles: [URL]

        var changed: Bool {
            removedManifestEntries > 0
                || regeneratedThumbnails > 0
                || removedOrphanedThumbnails > 0
        }
    }

    struct DuplicateRecordingGroup {
        let key: String
        let items: [RecordingEntry]
        let wastedBytes: Int64
    }

    struct DuplicateCleanupResult {
        let removedCount: Int
        let failedMessages: [String]
    }

    private struct QueuedRecordingRequest {
        let target: String
        let channelName: String?
        let quality: String
        let captureType: RecordingCaptureType
    }

    private enum DownloadStopReason {
        case canceled
        case paused
    }

    private final class StreamlinkStderrCollector: @unchecked Sendable {
        var data = Data()
        var lineBuffer = ""
    }

    private var recordingSessions: [String: RecordingSession] = [:]
    private var queuedRecordingRequestsByLogin: [String: QueuedRecordingRequest] = [:]
    private var backgroundRecordingLogins: Set<String> = []
    private var backgroundRecordingMonitor: Timer?
    private var pendingRecoveryIntents: [RecoveryIntent] = []
    private let recoveryDefaultsKey = "recordingRecoveryIntents.v1"
    private let downloadTasksDefaultsKey = "recordingDownloadTasks.v1"
    private let downloadAutoRetryEnabledKey = "recordingDownloadAutoRetryEnabled"
    private let downloadAutoRetryLimitKey = "recordingDownloadAutoRetryLimit"
    private let downloadAutoRetryDelayKey = "recordingDownloadAutoRetryDelaySeconds"
    private var downloadStopReasons: [String: DownloadStopReason] = [:]
    private var scheduledDownloadRetryTasks: [String: Task<Void, Never>] = [:]


    private let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    private let downloadProgressPercentRegex = try! NSRegularExpression(pattern: #"([0-9]{1,3}(?:\.[0-9]+)?)%"#)
    private let downloadBytesRegex = try! NSRegularExpression(pattern: #"([0-9][0-9,]*)\s*bytes"#, options: [.caseInsensitive])

    /// Override ffmpeg path resolution (primarily for unit tests).
    var _resolveFFmpegPathOverride: (() -> String?)?
    /// Override streamlink path resolution (primarily for unit tests).
    var _resolveStreamlinkPathOverride: (() -> String?)?

    init(recorderOrchestrator: RecorderOrchestrator? = nil) {
        self.recorderOrchestrator = recorderOrchestrator ?? RecorderOrchestrator()
        syncOrchestratorConcurrencyLimit()
        pendingRecoveryIntents = loadPersistedRecoveryIntents()
        downloadTasks = loadPersistedDownloadTasks()
        normalizeDownloadTasksAfterLaunch()
        refreshBackgroundRecordingState()
        startBackgroundRecordingMonitor()
        recordingEncryptionManager.cleanupTempPlaybackFiles()
        schedulePlaintextMigrationIfNeeded()
    }

    deinit {
        backgroundRecordingMonitor?.invalidate()
        for task in scheduledDownloadRetryTasks.values {
            task.cancel()
        }
    }

    func consumeRecoveryIntents() -> [RecoveryIntent] {
        return pendingRecoveryIntents
    }

    private func schedulePlaintextMigrationIfNeeded() {
        let directory = recordingsDirectory()
        Task.detached(priority: .utility) {
            let manager = RecordingEncryptionManager()
            let result = try? manager.migrateUnencryptedRecordings(
                in: directory,
                activeOutputURLs: []
            )
            guard let result, result.migratedCount > 0 else { return }
            await MainActor.run {
                NotificationCenter.default.post(name: .recordingLibraryDidChange, object: nil)
            }
        }
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
        let encrypted = encryptedRecordingEntries(in: directory)
        let plaintext = Self.buildPlaintextRecordingEntries(
            directory: directory,
            dateFormatter: filenameDateFormatter
        )
        var merged: [RecordingEntry] = []
        var seen = Set<URL>()
        for entry in encrypted + plaintext {
            let standardized = entry.url.standardizedFileURL
            if seen.insert(standardized).inserted {
                merged.append(entry)
            }
        }
        return Self.sortEntries(merged)
    }

    /// Pure helper that builds plaintext recording entry list from .mp4 files on disk.
    private static func buildPlaintextRecordingEntries(
        directory: URL,
        dateFormatter: DateFormatter
    ) -> [RecordingEntry] {
        recordingFileURLs(in: directory).compactMap { url -> RecordingEntry? in
            guard url.pathExtension.lowercased() == "mp4" else { return nil }
            let filename = url.deletingPathExtension().lastPathComponent
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileTimestamp = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
            let parsed = parseRecordingFilename(filename, dateFormatter: dateFormatter)
            return RecordingEntry(
                url: url,
                channelName: parsed.channelName,
                recordedAt: parsed.recordedAt ?? fileTimestamp,
                fileTimestamp: fileTimestamp,
                sourceType: parsed.sourceType,
                sourceTarget: nil
            )
        }
    }

    private static func recordingFileURLs(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }
            if values?.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls
    }

    private static func parseRecordingFilename(
        _ filename: String,
        dateFormatter: DateFormatter
    ) -> (channelName: String, recordedAt: Date?, sourceType: RecordingCaptureType) {
        let parts = filename.split(separator: "_")
        guard parts.count >= 3 else {
            return (channelName: filename, recordedAt: nil, sourceType: .liveRecording)
        }

        let dateString = "\(parts[parts.count - 2])_\(parts[parts.count - 1])"
        let recordedAt = dateFormatter.date(from: dateString)

        let sourceType: RecordingCaptureType
        let channelParts: ArraySlice<Substring>
        if parts.count >= 4,
           let taggedType = RecordingCaptureType.fromFilenameTag(String(parts[parts.count - 3])) {
            sourceType = taggedType
            channelParts = parts.dropLast(3)
        } else {
            sourceType = .liveRecording
            channelParts = parts.dropLast(2)
        }

        let channelName = channelParts.joined(separator: "_")
        return (
            channelName: channelName.isEmpty ? filename : channelName,
            recordedAt: recordedAt,
            sourceType: sourceType
        )
    }

    private func encryptedRecordingEntries(in directory: URL) -> [RecordingEntry] {
        let encryptedURLsByHashFilename: [String: URL] = {
            let urls = Self.recordingFileURLs(in: directory)
            var map: [String: URL] = [:]
            for url in urls where url.pathExtension.lowercased() == "glitcho" {
                guard url.lastPathComponent != RecordingEncryptionManager.manifestFilename else { continue }
                map[url.lastPathComponent] = url
            }
            return map
        }()
        guard !encryptedURLsByHashFilename.isEmpty else {
            return []
        }

        let manifest = recordingEncryptionManager
            .loadManifestIfAvailableWithoutInteraction(from: directory) ?? [:]

        var entries: [RecordingEntry] = manifest.compactMap { hashFilename, entry in
            guard let url = encryptedURLsByHashFilename[hashFilename] else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileTimestamp = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
            return RecordingEntry(
                url: url,
                channelName: entry.channelName,
                recordedAt: entry.date,
                fileTimestamp: fileTimestamp,
                sourceType: entry.sourceType,
                sourceTarget: entry.sourceTarget
            )
        }

        // Fallback for orphaned encrypted files when manifest metadata cannot be loaded.
        // This keeps recordings visible and playable even if metadata is missing/corrupted.
        let known = Set(manifest.keys)
        for url in encryptedURLsByHashFilename.values {
            guard !known.contains(url.lastPathComponent) else { continue }

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fallbackDate = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
            entries.append(
                RecordingEntry(
                    url: url,
                    channelName: "Encrypted Recording",
                    recordedAt: fallbackDate,
                    fileTimestamp: fallbackDate,
                    sourceType: .liveRecording,
                    sourceTarget: nil
                )
            )
        }

        return entries
    }

    private static func sortEntries(_ entries: [RecordingEntry]) -> [RecordingEntry] {
        entries.sorted { left, right in
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

        let isEncryptedRecording = url.pathExtension.lowercased() == "glitcho"
        let encryptedHashFilename = isEncryptedRecording ? url.lastPathComponent : nil

        // Prefer moving to Trash to avoid accidental data loss.
        do {
            _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: url)
        }

        if let encryptedHashFilename {
            try removeEncryptedRecordingFromManifest(hashFilename: encryptedHashFilename)
            recordingEncryptionManager.cleanupOrphanedThumbnails(
                knownHashFilenames: currentEncryptedHashFilenames(in: recordingsDirectory())
            )
        }
    }

    private func removeEncryptedRecordingFromManifest(hashFilename: String) throws {
        let directory = recordingsDirectory()
        var manifest = try recordingEncryptionManager.loadManifestSerialized(from: directory)
        if manifest.removeValue(forKey: hashFilename) != nil {
            try recordingEncryptionManager.saveManifestSerialized(manifest, to: directory)
        }
    }

    private func currentEncryptedHashFilenames(in directory: URL) -> Set<String> {
        guard let manifest = recordingEncryptionManager
            .loadManifestIfAvailableWithoutInteraction(from: directory) else {
            return []
        }
        return Set(manifest.keys)
    }

    func displayFilename(for recordingURL: URL) -> String {
        if recordingURL.pathExtension.lowercased() == "glitcho",
           let manifest = recordingEncryptionManager
               .loadManifestIfAvailableWithoutInteraction(from: recordingsDirectory()),
           let entry = manifest[recordingURL.lastPathComponent] {
            return entry.originalFilename
        }
        return recordingURL.lastPathComponent
    }

    func recordingSourceTarget(for recordingURL: URL) -> String? {
        if recordingURL.pathExtension.lowercased() == "glitcho",
           let manifest = recordingEncryptionManager
               .loadManifestIfAvailableWithoutInteraction(from: recordingsDirectory()),
           let entry = manifest[recordingURL.lastPathComponent] {
            return entry.sourceTarget
        }
        return nil
    }

    @discardableResult
    func redownloadRecording(_ recording: RecordingEntry) -> Bool {
        let fallbackChannel = recording.channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTarget: String? = {
            if let sourceTarget = recording.sourceTarget?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sourceTarget.isEmpty {
                return sourceTarget
            }
            if let sourceTarget = recordingSourceTarget(for: recording.url)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !sourceTarget.isEmpty {
                return sourceTarget
            }
            if recording.sourceType == .liveRecording, !fallbackChannel.isEmpty {
                let loginLike = fallbackChannel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: " ", with: "")
                    .lowercased()
                return "twitch.tv/\(loginLike)"
            }
            return nil
        }()

        guard let resolvedTarget else {
            errorMessage = "Original source URL is unavailable for this recording."
            return false
        }

        let quality = "best"
        let channelName = fallbackChannel.isEmpty ? nil : fallbackChannel
        return startRecording(target: resolvedTarget, channelName: channelName, quality: quality)
    }

    @discardableResult
    func renameRecording(at sourceURL: URL, to requestedName: String) throws -> URL {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "RecordingError",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty."]
            )
        }

        if sourceURL.pathExtension.lowercased() == "glitcho" {
            let directory = recordingsDirectory()
            var manifest = try recordingEncryptionManager.loadManifestSerialized(from: directory)
            guard var entry = manifest[sourceURL.lastPathComponent] else {
                throw NSError(
                    domain: "RecordingError",
                    code: 31,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to find recording metadata."]
                )
            }
            let currentExt = (entry.originalFilename as NSString).pathExtension
            let ext = currentExt.isEmpty ? "mp4" : currentExt
            let safeStem = sanitizedFilenameComponent(from: trimmed) ?? "recording"
            entry = RecordingManifestEntry(
                channelName: entry.channelName,
                date: entry.date,
                quality: entry.quality,
                originalFilename: "\(safeStem).\(ext)",
                sourceType: entry.sourceType,
                sourceTarget: entry.sourceTarget
            )
            manifest[sourceURL.lastPathComponent] = entry
            try recordingEncryptionManager.saveManifestSerialized(manifest, to: directory)
            NotificationCenter.default.post(name: .recordingLibraryDidChange, object: nil)
            return sourceURL
        }

        let ext = sourceURL.pathExtension
        let safeStem = sanitizedFilenameComponent(from: trimmed) ?? "recording"
        let filename = ext.isEmpty ? safeStem : "\(safeStem).\(ext)"
        let destinationDir = sourceURL.deletingLastPathComponent()
        let destination = uniqueDestinationURL(in: destinationDir, preferredFilename: filename)
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        NotificationCenter.default.post(name: .recordingLibraryDidChange, object: nil)
        return destination
    }

    @discardableResult
    func exportRecording(at sourceURL: URL, to destinationDir: URL) throws -> URL {
        if sourceURL.pathExtension.lowercased() == "glitcho" {
            let fileDirectory = sourceURL.deletingLastPathComponent()
            let manifest = (try? recordingEncryptionManager.loadManifestSerialized(from: recordingsDirectory())) ?? [:]
            let fallbackName = sourceURL.deletingPathExtension().lastPathComponent + ".mp4"
            let originalFilename = manifest[sourceURL.lastPathComponent]?.originalFilename ?? fallbackName
            let destination = destinationDir.appendingPathComponent(originalFilename)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try recordingEncryptionManager.decryptFile(
                named: sourceURL.lastPathComponent,
                in: fileDirectory,
                to: destination
            )
            return destination
        }

        let destination = destinationDir.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func uniqueDestinationURL(in directory: URL, preferredFilename: String) -> URL {
        var candidate = directory.appendingPathComponent(preferredFilename)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let stem = (preferredFilename as NSString).deletingPathExtension
        let ext = (preferredFilename as NSString).pathExtension
        var index = 2
        while true {
            let numbered = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
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
    func startRecording(
        target: String,
        channelName: String?,
        quality: String = "best",
        processTargetOverride: String? = nil
    ) -> Bool {
        errorMessage = nil

        let resolvedRecordingTarget = resolvedTarget(from: target)
        let resolvedProcessTarget: String = {
            guard let processTargetOverride else { return resolvedRecordingTarget }
            return resolvedTarget(from: processTargetOverride)
        }()
        let captureType = RecordingCaptureType.infer(fromTarget: resolvedRecordingTarget)
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
        cancelScheduledDownloadRetry(for: sessionKey)
        downloadStopReasons.removeValue(forKey: sessionKey)

        if let resolvedChannelLogin,
           maybeQueueRecordingRequest(
               login: resolvedChannelLogin,
               target: target,
               channelName: channelName,
               quality: quality,
               captureType: captureType
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

        let rootDirectory = recordingsDirectory()
        let startedAt = Date()
        let directory = recordingOutputDirectory(
            rootDirectory: rootDirectory,
            displayName: channelName,
            login: resolvedChannelLogin,
            captureType: captureType,
            startedAt: startedAt
        )
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
        if let resolvedChannelLogin {
            clearPendingRecoveryIntent(channelLogin: resolvedChannelLogin)
        }
        let timestamp = filenameDateFormatter.string(from: startedAt)
        let safeChannel = sanitizedFilenameComponent(from: displayName)
            ?? sanitizedFilenameComponent(from: resolvedChannelLogin)
            ?? "twitch"
        let filename = "\(safeChannel)_\(captureType.filenameTag)_\(timestamp).mp4"
        let outputURL = directory.appendingPathComponent(filename)

        let process = Process()
        let processArguments: [String]
        if captureType.isDownload {
            guard let workerPath = resolveDownloadWorkerPath() else {
                let message = "Download worker is unavailable. Rebuild Glitcho so the bundled helper is installed."
                errorMessage = message
                recorderOrchestrator.setError(for: resolvedChannelLogin, errorMessage: message)
                GlitchoTelemetry.track(
                    "download_start_failed_worker_missing",
                    metadata: ["login": resolvedChannelLogin ?? "unknown"]
                )
                return false
            }
            process.executableURL = URL(fileURLWithPath: workerPath)
            processArguments = [
                "--run-download",
                "--target", resolvedProcessTarget,
                "--quality", quality,
                "--output", outputURL.path,
                "--streamlink-path", streamlinkPath
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: streamlinkPath)
            processArguments = [
                resolvedProcessTarget,
                quality,
                "--twitch-disable-ads",
                "--twitch-low-latency",
                "--output",
                outputURL.path
            ]
        }
        process.arguments = processArguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        let stderrQueue = DispatchQueue(label: "com.glitcho.recording.stderr.\(sessionKey)")
        let stderrCollector = StreamlinkStderrCollector()
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            stderrQueue.async {
                stderrCollector.data.append(data)
                guard captureType.isDownload else { return }
                let chunk = String(decoding: data, as: UTF8.self)
                stderrCollector.lineBuffer.append(chunk)
                let hasTrailingBreak = stderrCollector.lineBuffer.hasSuffix("\n") || stderrCollector.lineBuffer.hasSuffix("\r")
                var lines = stderrCollector.lineBuffer.components(separatedBy: .newlines)
                if !hasTrailingBreak, let tail = lines.popLast() {
                    stderrCollector.lineBuffer = tail
                } else {
                    stderrCollector.lineBuffer = ""
                }
                let nonEmptyLines = lines.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                guard !nonEmptyLines.isEmpty else { return }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for line in nonEmptyLines {
                        self.updateDownloadTaskProgress(
                            id: sessionKey,
                            line: line,
                            outputURL: outputURL
                        )
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let stderrText = stderrQueue.sync { () -> String in
                if !stderrCollector.lineBuffer.isEmpty {
                    stderrCollector.data.append(contentsOf: stderrCollector.lineBuffer.utf8)
                    stderrCollector.lineBuffer = ""
                }
                return String(data: stderrCollector.data, encoding: .utf8) ?? ""
            }

            Task { @MainActor in
                guard let self else { return }
                guard let session = self.recordingSessions.removeValue(forKey: sessionKey) else { return }
                self.syncPublishedRecordingState()

                let didUserStop = session.userInitiatedStop
                var failureMessage: String?
                if proc.terminationStatus != 0 && !didUserStop {
                    let message = stderrText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedMessage = message.isEmpty ? "Recording stopped unexpectedly." : message
                    self.errorMessage = resolvedMessage
                    failureMessage = resolvedMessage
                }

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
                        let displayLabel = session.channelName ?? login
                        let elapsed = Date().timeIntervalSince(session.startedAt)
                        let h = Int(elapsed) / 3600
                        let m = (Int(elapsed) % 3600) / 60
                        let s = Int(elapsed) % 60
                        let durationString = h > 0
                            ? String(format: "%d:%02d:%02d", h, m, s)
                            : String(format: "%d:%02d", m, s)
                        self.sendRecordingNotificationIfEnabled(
                            title: "Recording complete",
                            body: "@\(displayLabel) (\(durationString))"
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
                        let displayLabel = session.channelName ?? login
                        let reason = failureMessage ?? "Recording stopped unexpectedly."
                        self.sendRecordingNotificationIfEnabled(
                            title: "Recording failed",
                            body: "@\(displayLabel) — \(reason)"
                        )
                    }
                }

                if session.captureType.isDownload {
                    let stopReason = self.downloadStopReasons.removeValue(forKey: session.key)
                    let finalState: DownloadTaskState = {
                        if didUserStop {
                            switch stopReason {
                            case .paused:
                                return .paused
                            default:
                                return .canceled
                            }
                        }
                        if proc.terminationStatus == 0 { return .completed }
                        return .failed
                    }()
                    self.updateDownloadTaskFinalState(
                        id: session.key,
                        state: finalState,
                        statusMessage: failureMessage,
                        outputURL: session.outputURL
                    )
                    if finalState == .failed {
                        self.scheduleAutomaticDownloadRetryIfNeeded(id: session.key)
                    } else {
                        self.cancelScheduledDownloadRetry(for: session.key)
                    }
                }

                // Streamlink outputs MPEG-TS data even when the filename ends with .mp4.
                // Remux to a real MP4 so AVPlayer can play it.
                // Stream ended naturally (exit 0, not user-requested): treat as auto-stop.
                let streamEndedNaturally = proc.terminationStatus == 0 && !didUserStop
                let shouldAttemptFinalize: Bool
                if session.captureType.isDownload {
                    shouldAttemptFinalize = proc.terminationStatus == 0
                } else {
                    shouldAttemptFinalize = proc.terminationStatus == 0 || didUserStop
                }
                if shouldAttemptFinalize {
                    if session.captureType == .liveRecording && streamEndedNaturally {
                        if let login = session.login {
                            self.autoStoppedRecordings.append(login)
                        }
                        GlitchoTelemetry.track(
                            "recording_auto_stopped_stream_ended",
                            metadata: ["login": session.login ?? "unknown"]
                        )
                    }
                    await self.secureRecordedOutputIfNeeded(session: session)
                } else if session.captureType.isDownload {
                    try? FileManager.default.removeItem(at: session.outputURL)
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
            captureType: captureType,
            quality: quality,
            outputURL: outputURL,
            process: process,
            startedAt: startedAt,
            userInitiatedStop: false
        )

        if captureType.isDownload {
            upsertDownloadTask(
                id: sessionKey,
                target: resolvedRecordingTarget,
                channelName: displayName ?? resolvedChannelLogin,
                quality: quality,
                captureType: captureType,
                outputURL: outputURL,
                state: .running,
                startedAt: startedAt,
                progressFraction: nil,
                bytesWritten: 0,
                statusMessage: nil,
                lastErrorMessage: nil
            )
        }
        syncPublishedRecordingState()

        do {
            try process.run()
            if let resolvedChannelLogin {
                recorderOrchestrator.setRecording(for: resolvedChannelLogin)
                GlitchoTelemetry.track(
                    "recording_started",
                    metadata: ["login": resolvedChannelLogin, "quality": quality]
                )
                let displayLabel = displayName ?? resolvedChannelLogin
                sendRecordingNotificationIfEnabled(
                    title: "Recording started",
                    body: "@\(displayLabel)"
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
            if captureType.isDownload {
                updateDownloadTaskFinalState(
                    id: sessionKey,
                    state: .failed,
                    statusMessage: message,
                    outputURL: outputURL
                )
                scheduleAutomaticDownloadRetryIfNeeded(id: sessionKey)
            }
            GlitchoTelemetry.track(
                "recording_start_failed_launch",
                metadata: [
                    "login": resolvedChannelLogin ?? "unknown",
                    "error": error.localizedDescription
                ]
            )
            if let login = resolvedChannelLogin {
                let displayLabel = displayName ?? login
                sendRecordingNotificationIfEnabled(
                    title: "Recording failed",
                    body: "@\(displayLabel) — \(message)"
                )
            }
            return false
        }
    }

    private func secureRecordedOutputIfNeeded(session: RecordingSession) async {
        let startedAt = Date()
        func elapsedMs() -> String {
            String(Int(Date().timeIntervalSince(startedAt) * 1000))
        }

        do {
            let prepared = try await prepareRecordingForPlayback(
                at: session.outputURL,
                allowTransportStreamFallback: false
            )
            let outputURL = prepared.url
            guard outputURL.pathExtension.lowercased() == "mp4" else { return }

            let destinationDirectory = outputURL.deletingLastPathComponent()
            let manifestDirectory = recordingsDirectory()
            let encrypted = try recordingEncryptionManager.encryptFile(
                at: outputURL,
                in: destinationDirectory,
                channelName: session.channelName,
                quality: session.quality,
                date: session.startedAt,
                sourceType: session.captureType,
                sourceTarget: session.target
            )
            try recordingEncryptionManager.upsertManifestEntry(
                encrypted.entry,
                hashFilename: encrypted.hashFilename,
                in: manifestDirectory
            )
            NotificationCenter.default.post(name: .recordingLibraryDidChange, object: nil)
            GlitchoTelemetry.track(
                "recording_secure_finalize_completed",
                metadata: [
                    "login": session.login ?? "unknown",
                    "capture_type": session.captureType.rawValue,
                    "container": "glitcho_obf_v2",
                    "elapsed_ms": elapsedMs()
                ]
            )
        } catch {
            errorMessage = "Could not secure \(session.captureType.actionLabel.lowercased()): \(error.localizedDescription)"
            GlitchoTelemetry.track(
                "recording_secure_finalize_failed",
                metadata: [
                    "login": session.login ?? "unknown",
                    "error": error.localizedDescription,
                    "elapsed_ms": elapsedMs()
                ]
            )
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

    @discardableResult
    func cancelDownloadTask(id: String) -> Bool {
        if let session = recordingSessions[id], session.captureType.isDownload {
            downloadStopReasons[id] = .canceled
            stopRecording(forKey: id)
            return true
        }
        guard let index = downloadTasks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if downloadTasks[index].state == .running || downloadTasks[index].state == .queued {
            downloadTasks[index].state = .canceled
            downloadTasks[index].updatedAt = Date()
            downloadTasks[index].statusMessage = "Canceled."
            persistDownloadTasks()
            return true
        }
        return false
    }

    @discardableResult
    func pauseDownloadTask(id: String) -> Bool {
        if let session = recordingSessions[id], session.captureType.isDownload {
            downloadStopReasons[id] = .paused
            stopRecording(forKey: id)
            return true
        }
        guard let index = downloadTasks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if downloadTasks[index].state == .running || downloadTasks[index].state == .queued {
            downloadTasks[index].state = .paused
            downloadTasks[index].updatedAt = Date()
            downloadTasks[index].progressFraction = nil
            downloadTasks[index].statusMessage = "Paused."
            persistDownloadTasks()
            return true
        }
        return false
    }

    @discardableResult
    func resumeDownloadTask(id: String) -> Bool {
        guard let task = downloadTasks.first(where: { $0.id == id }),
              task.canResume else {
            return false
        }
        cancelScheduledDownloadRetry(for: id)
        return startRecording(
            target: task.target,
            channelName: task.channelName,
            quality: task.quality
        )
    }

    @discardableResult
    func removeDownloadTask(id: String) -> Bool {
        if let session = recordingSessions[id], session.captureType.isDownload {
            stopRecording(forKey: id)
        }
        cancelScheduledDownloadRetry(for: id)
        downloadStopReasons.removeValue(forKey: id)
        guard let index = downloadTasks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        downloadTasks.remove(at: index)
        persistDownloadTasks()
        return true
    }

    func pauseAllDownloadTasks() {
        let activeIDs = downloadTasks
            .filter { $0.state == .running || $0.state == .queued }
            .map(\.id)
        for id in activeIDs {
            _ = pauseDownloadTask(id: id)
        }
    }

    func resumeAllDownloadTasks() {
        let resumableIDs = downloadTasks
            .filter(\.canResume)
            .map(\.id)
        for id in resumableIDs {
            _ = resumeDownloadTask(id: id)
        }
    }

    @discardableResult
    func retryFailedDownloadTasks() -> Int {
        let failedIDs = downloadTasks
            .filter { $0.state == .failed }
            .map(\.id)
        for id in failedIDs {
            _ = resumeDownloadTask(id: id)
        }
        return failedIDs.count
    }

    @discardableResult
    func clearCompletedDownloadTasks() -> Int {
        let removable = downloadTasks
            .filter { $0.state == .completed || $0.state == .canceled }
            .map(\.id)
        for id in removable {
            _ = removeDownloadTask(id: id)
        }
        return removable.count
    }

    @discardableResult
    func cancelActiveDownloadTasks() -> Int {
        let active = downloadTasks
            .filter { $0.state == .running || $0.state == .queued }
            .map(\.id)
        for id in active {
            _ = cancelDownloadTask(id: id)
        }
        return active.count
    }

    private func upsertDownloadTask(
        id: String,
        target: String,
        channelName: String?,
        quality: String,
        captureType: RecordingCaptureType,
        outputURL: URL?,
        state: DownloadTaskState,
        startedAt: Date?,
        progressFraction: Double?,
        bytesWritten: Int64,
        statusMessage: String?,
        lastErrorMessage: String?
    ) {
        if let index = downloadTasks.firstIndex(where: { $0.id == id }) {
            var existing = downloadTasks[index]
            existing.outputURL = outputURL ?? existing.outputURL
            existing.startedAt = startedAt ?? existing.startedAt
            existing.updatedAt = Date()
            existing.progressFraction = progressFraction ?? existing.progressFraction
            existing.bytesWritten = max(bytesWritten, existing.bytesWritten)
            if let statusMessage {
                existing.statusMessage = statusMessage
            } else if state == .running || state == .queued {
                existing.statusMessage = nil
            }
            if let lastErrorMessage {
                existing.lastErrorMessage = lastErrorMessage
            } else if state == .running || state == .queued || state == .completed {
                existing.lastErrorMessage = nil
            }
            if state == .completed {
                existing.retryCount = 0
            }
            existing.state = state
            downloadTasks[index] = existing
        } else {
            downloadTasks.append(
                DownloadTask(
                    id: id,
                    target: target,
                    channelName: channelName,
                    quality: quality,
                    captureType: captureType,
                    outputURL: outputURL,
                    startedAt: startedAt,
                    updatedAt: Date(),
                    progressFraction: progressFraction,
                    bytesWritten: bytesWritten,
                    statusMessage: statusMessage,
                    lastErrorMessage: lastErrorMessage,
                    retryCount: 0,
                    state: state
                )
            )
        }

        downloadTasks.sort { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
        if downloadTasks.count > 120 {
            downloadTasks = Array(downloadTasks.prefix(120))
        }
        persistDownloadTasks()
    }

    private func updateDownloadTaskProgress(id: String, line: String, outputURL: URL) {
        guard let index = downloadTasks.firstIndex(where: { $0.id == id }) else { return }
        var task = downloadTasks[index]
        guard task.state == .running || task.state == .queued else { return }

        if let fraction = parseDownloadProgressFraction(from: line) {
            task.progressFraction = fraction
        }
        if let bytes = parseDownloadBytes(from: line) {
            task.bytesWritten = max(task.bytesWritten, bytes)
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileBytes = (attrs?[.size] as? Int64) ?? 0
            task.bytesWritten = max(task.bytesWritten, fileBytes)
        }
        task.statusMessage = line
        task.lastErrorMessage = nil
        task.updatedAt = Date()
        task.state = .running
        downloadTasks[index] = task
        downloadTasks.sort { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
        persistDownloadTasks()
    }

    private func updateDownloadTaskFinalState(
        id: String,
        state: DownloadTaskState,
        statusMessage: String?,
        outputURL: URL?
    ) {
        guard let index = downloadTasks.firstIndex(where: { $0.id == id }) else { return }
        var task = downloadTasks[index]
        if let outputURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let fileBytes = attrs[.size] as? Int64 {
            task.bytesWritten = max(task.bytesWritten, fileBytes)
        }
        task.state = state
        task.updatedAt = Date()
        task.statusMessage = statusMessage ?? task.statusMessage
        if state == .completed {
            task.progressFraction = 1.0
            task.lastErrorMessage = nil
            task.retryCount = 0
        } else if state == .failed {
            let errorText = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            task.lastErrorMessage = (errorText?.isEmpty == false) ? errorText : task.statusMessage
        } else if state == .paused {
            task.progressFraction = nil
        }
        downloadTasks[index] = task
        downloadTasks.sort { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
        persistDownloadTasks()
    }

    private func parseDownloadProgressFraction(from line: String) -> Double? {
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = downloadProgressPercentRegex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: line),
              let value = Double(line[valueRange]) else {
            return nil
        }
        return min(max(value / 100.0, 0), 1)
    }

    private func parseDownloadBytes(from line: String) -> Int64? {
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = downloadBytesRegex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        let raw = String(line[valueRange]).replacingOccurrences(of: ",", with: "")
        return Int64(raw)
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

    func recordingStartTime(channelLogin: String?) -> Date? {
        guard let channelLogin, let normalized = normalizedChannelLogin(channelLogin) else { return nil }
        return recordingSessions[loginKey(for: normalized)]?.startedAt
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

    // MARK: - Notification Support

    func requestNotificationPermission() {
        if NSClassFromString("XCTestCase") != nil {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendRecordingNotificationIfEnabled(title: String, body: String) {
        guard UserDefaults.standard.object(forKey: "recordingNotificationsEnabled") as? Bool ?? true else { return }
        sendNotification(title: title, body: body)
    }

    func sendNotification(title: String, body: String) {
        // Test host processes do not have a valid application bundle for
        // UserNotifications, which can throw NSInternalInconsistencyException.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundleURL.path.contains("/Contents/Developer/usr/bin") {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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
        quality: String,
        captureType: RecordingCaptureType
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
            quality: quality,
            captureType: captureType
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
        enforceRetentionPolicies(on: listRecordings())
    }

    func enforceRetentionPolicies(on entries: [RecordingEntry]) -> RetentionResult {
        let maxAgeDays = retentionMaxAgeDays()
        let keepGlobal = retentionKeepLastGlobal()
        let keepPerChannel = retentionKeepLastPerChannel()

        if maxAgeDays == 0, keepGlobal == 0, keepPerChannel == 0 {
            return RetentionResult(deletedCount: 0, failedCount: 0)
        }

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

    func scanLibraryIntegrity() -> LibraryIntegrityReport {
        let directory = recordingsDirectory()
        let allFiles = Self.recordingFileURLs(in: directory)
        let encryptedFiles = allFiles.filter {
            $0.pathExtension.lowercased() == "glitcho"
                && $0.lastPathComponent != RecordingEncryptionManager.manifestFilename
        }
        let encryptedHashFilenames = Set(encryptedFiles.map(\.lastPathComponent))

        let manifest = recordingEncryptionManager.loadManifestIfAvailableWithoutInteraction(from: directory)
            ?? (try? recordingEncryptionManager.loadManifestSerialized(from: directory))
            ?? [:]
        let manifestHashFilenames = Set(manifest.keys)

        let orphanedManifestEntries = manifestHashFilenames
            .subtracting(encryptedHashFilenames)
            .sorted()
        let missingThumbnailEntries = encryptedHashFilenames
            .filter { hashFilename in
                let thumbURL = RecordingEncryptionManager.thumbnailURL(for: hashFilename)
                guard FileManager.default.isReadableFile(atPath: thumbURL.path) else {
                    return true
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: thumbURL.path)
                let size = (attrs?[.size] as? Int64) ?? 0
                return size <= 0
            }
            .sorted()

        let orphanedThumbnailEntries: [String] = {
            let thumbnailsDir = RecordingEncryptionManager.thumbnailCacheDirectory
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: thumbnailsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return files
                .filter { $0.pathExtension.lowercased() == "thumb" }
                .map { $0.deletingPathExtension().lastPathComponent }
                .filter { hashFilename in
                    !encryptedHashFilenames.contains(hashFilename)
                }
                .sorted()
        }()

        let unreadableFiles = allFiles.filter { url in
            guard url.lastPathComponent != RecordingEncryptionManager.manifestFilename else {
                return false
            }
            let path = url.path
            guard FileManager.default.isReadableFile(atPath: path) else { return true }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? Int64) ?? 0
            return size <= 0
        }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return LibraryIntegrityReport(
            scannedAt: Date(),
            manifestEntryCount: manifest.count,
            encryptedFileCount: encryptedFiles.count,
            orphanedManifestEntries: orphanedManifestEntries,
            missingThumbnailEntries: missingThumbnailEntries,
            orphanedThumbnailEntries: orphanedThumbnailEntries,
            unreadableFiles: unreadableFiles
        )
    }

    func repairLibraryIntegrity(_ baseline: LibraryIntegrityReport? = nil) -> LibraryIntegrityRepairResult {
        let report = baseline ?? scanLibraryIntegrity()
        let directory = recordingsDirectory()

        var removedManifestEntries = 0
        var regeneratedThumbnails = 0
        var removedOrphanedThumbnails = 0

        do {
            var manifest = try recordingEncryptionManager.loadManifestSerialized(from: directory)
            for hashFilename in report.orphanedManifestEntries {
                if manifest.removeValue(forKey: hashFilename) != nil {
                    removedManifestEntries += 1
                }
            }
            if removedManifestEntries > 0 {
                try recordingEncryptionManager.saveManifestSerialized(manifest, to: directory)
            }
        } catch {
            // Keep repair best-effort; unresolved issues remain in the returned report.
        }

        for hashFilename in report.missingThumbnailEntries {
            do {
                try recordingEncryptionManager.regenerateThumbnailSidecar(
                    for: hashFilename,
                    in: directory
                )
                regeneratedThumbnails += 1
            } catch {
                continue
            }
        }

        for hashFilename in report.orphanedThumbnailEntries {
            let thumbURL = RecordingEncryptionManager.thumbnailURL(for: hashFilename)
            guard FileManager.default.fileExists(atPath: thumbURL.path) else { continue }
            do {
                try FileManager.default.removeItem(at: thumbURL)
                removedOrphanedThumbnails += 1
            } catch {
                continue
            }
        }

        let result = LibraryIntegrityRepairResult(
            reportBefore: report,
            removedManifestEntries: removedManifestEntries,
            regeneratedThumbnails: regeneratedThumbnails,
            removedOrphanedThumbnails: removedOrphanedThumbnails,
            unresolvedUnreadableFiles: report.unreadableFiles
        )

        if result.changed {
            NotificationCenter.default.post(name: .recordingLibraryDidChange, object: nil)
        }
        return result
    }

    func duplicateRecordingGroups(in entries: [RecordingEntry]? = nil) -> [DuplicateRecordingGroup] {
        let sourceEntries = entries ?? listRecordings()
        var buckets: [String: [RecordingEntry]] = [:]

        for entry in sourceEntries {
            let channel = entry.channelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !channel.isEmpty else { continue }
            guard let capturedAt = entry.recordedAt ?? entry.fileTimestamp else { continue }
            let size = fileSizeBytes(for: entry.url)
            guard size > 0 else { continue }
            let timestamp = Int(capturedAt.timeIntervalSince1970)
            let key = "\(channel)|\(timestamp)|\(size)"
            buckets[key, default: []].append(entry)
        }

        let groups = buckets.compactMap { key, values -> DuplicateRecordingGroup? in
            guard values.count > 1 else { return nil }
            let sorted = values.sorted { lhs, rhs in
                let leftDate = lhs.recordedAt ?? lhs.fileTimestamp ?? Date.distantPast
                let rightDate = rhs.recordedAt ?? rhs.fileTimestamp ?? Date.distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return fileSizeBytes(for: lhs.url) > fileSizeBytes(for: rhs.url)
            }
            let wasted = sorted.dropFirst().reduce(Int64(0)) { partial, entry in
                partial + fileSizeBytes(for: entry.url)
            }
            return DuplicateRecordingGroup(key: key, items: sorted, wastedBytes: wasted)
        }

        return groups.sorted { lhs, rhs in lhs.wastedBytes > rhs.wastedBytes }
    }

    func cleanupDuplicateRecordings(in entries: [RecordingEntry]? = nil) -> DuplicateCleanupResult {
        let groups = duplicateRecordingGroups(in: entries)
        guard !groups.isEmpty else {
            return DuplicateCleanupResult(removedCount: 0, failedMessages: [])
        }

        var removedCount = 0
        var failedMessages: [String] = []
        for group in groups {
            for duplicate in group.items.dropFirst() {
                do {
                    try deleteRecording(at: duplicate.url)
                    removedCount += 1
                } catch {
                    failedMessages.append("\(duplicate.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return DuplicateCleanupResult(removedCount: removedCount, failedMessages: failedMessages)
    }

    private func fileSizeBytes(for url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
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

    private func loadPersistedDownloadTasks() -> [DownloadTask] {
        guard let data = UserDefaults.standard.data(forKey: downloadTasksDefaultsKey),
              let decoded = try? JSONDecoder().decode([DownloadTask].self, from: data) else {
            return []
        }
        var unique: [String: DownloadTask] = [:]
        for task in decoded {
            if let existing = unique[task.id] {
                unique[task.id] = (task.updatedAt > existing.updatedAt) ? task : existing
            } else {
                unique[task.id] = task
            }
        }
        return unique.values.sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
    }

    private func persistDownloadTasks() {
        if downloadTasks.isEmpty {
            UserDefaults.standard.removeObject(forKey: downloadTasksDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(downloadTasks) {
            UserDefaults.standard.set(data, forKey: downloadTasksDefaultsKey)
        }
    }

    private func normalizeDownloadTasksAfterLaunch() {
        guard !downloadTasks.isEmpty else { return }
        let now = Date()
        for index in downloadTasks.indices {
            if downloadTasks[index].state == .running || downloadTasks[index].state == .queued {
                downloadTasks[index].state = .paused
                downloadTasks[index].updatedAt = now
                let existing = downloadTasks[index].statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                if existing?.isEmpty ?? true {
                    downloadTasks[index].statusMessage = "Paused after app relaunch."
                } else {
                    downloadTasks[index].statusMessage = "\(existing ?? "") (paused after relaunch)"
                }
            }
        }
        downloadTasks.sort { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
        persistDownloadTasks()
    }

    private func downloadAutoRetryEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: downloadAutoRetryEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: downloadAutoRetryEnabledKey)
    }

    private func downloadAutoRetryLimit() -> Int {
        if UserDefaults.standard.object(forKey: downloadAutoRetryLimitKey) == nil {
            return 2
        }
        return min(max(UserDefaults.standard.integer(forKey: downloadAutoRetryLimitKey), 0), 8)
    }

    private func downloadAutoRetryDelaySeconds() -> TimeInterval {
        if UserDefaults.standard.object(forKey: downloadAutoRetryDelayKey) == nil {
            return 15
        }
        let raw = UserDefaults.standard.integer(forKey: downloadAutoRetryDelayKey)
        return TimeInterval(min(max(raw, 3), 300))
    }

    private func cancelScheduledDownloadRetry(for id: String) {
        if let task = scheduledDownloadRetryTasks.removeValue(forKey: id) {
            task.cancel()
        }
    }

    private func scheduleAutomaticDownloadRetryIfNeeded(id: String) {
        guard downloadAutoRetryEnabled(),
              let index = downloadTasks.firstIndex(where: { $0.id == id }) else {
            return
        }

        var task = downloadTasks[index]
        guard task.state == .failed else { return }

        let limit = downloadAutoRetryLimit()
        guard task.retryCount < limit else { return }

        cancelScheduledDownloadRetry(for: id)

        task.retryCount += 1
        let delay = downloadAutoRetryDelaySeconds()
        task.state = .queued
        let lastError = task.lastErrorMessage ?? "Unknown failure"
        task.statusMessage = "Auto-retry \(task.retryCount)/\(limit) in \(Int(delay))s: \(lastError)"
        task.updatedAt = Date()
        downloadTasks[index] = task
        persistDownloadTasks()

        let retryTask = Task { [weak self] in
            let nanos = UInt64(max(1, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.scheduledDownloadRetryTasks.removeValue(forKey: id)
            guard let refreshed = self.downloadTasks.first(where: { $0.id == id }),
                  refreshed.state == .queued,
                  self.recordingSessions[id] == nil else {
                return
            }
            let didStart = self.startRecording(
                target: refreshed.target,
                channelName: refreshed.channelName,
                quality: refreshed.quality
            )
            if !didStart {
                self.updateDownloadTaskFinalState(
                    id: id,
                    state: .failed,
                    statusMessage: self.errorMessage ?? "Unable to resume download.",
                    outputURL: refreshed.outputURL
                )
            }
        }
        scheduledDownloadRetryTasks[id] = retryTask
    }

    private func recordingOutputDirectory(
        rootDirectory: URL,
        displayName: String?,
        login: String?,
        captureType: RecordingCaptureType,
        startedAt: Date
    ) -> URL {
        _ = displayName
        _ = login
        _ = captureType
        _ = startedAt
        return rootDirectory
    }

#if DEBUG
    func _replaceDownloadTasksForTesting(_ tasks: [DownloadTask]) {
        downloadTasks = tasks
        persistDownloadTasks()
    }

    func _downloadTasksSnapshotForTesting() -> [DownloadTask] {
        downloadTasks
    }

    func _triggerAutoRetryForTesting(id: String) {
        scheduleAutomaticDownloadRetryIfNeeded(id: id)
    }

    func _cancelAutoRetryForTesting(id: String) {
        cancelScheduledDownloadRetry(for: id)
    }
#endif

    /// Ensures the given recording file is playable by AVPlayer.
    ///
    /// Streamlink writes MPEG transport stream data to disk by default. Even if the filename
    /// ends with `.mp4`, the file may actually be `.ts` data and will fail to play in AVPlayer.
    /// This method detects that case and remuxes the file in-place using ffmpeg.
    ///
    /// When `allowTransportStreamFallback` is true and ffmpeg is unavailable, Glitcho creates
    /// a temporary `.ts` copy for playback so the recording can still be opened.
    func prepareRecordingForPlayback(
        at url: URL,
        allowTransportStreamFallback: Bool = true
    ) async throws -> (url: URL, didRemux: Bool) {
        let startedAt = Date()
        func elapsedMs() -> String {
            String(Int(Date().timeIntervalSince(startedAt) * 1000))
        }

        guard url.isFileURL else { return (url, false) }
        let pathExt = url.pathExtension.lowercased()
        if pathExt == "glitcho" {
            let directory = url.deletingLastPathComponent()
            let hashFilename = url.lastPathComponent
            let tempURL = recordingEncryptionManager.tempPlaybackURL()
            try recordingEncryptionManager.decryptFile(
                named: hashFilename,
                in: directory,
                to: tempURL
            )
            guard isTransportStreamFile(at: tempURL) else {
                GlitchoTelemetry.track(
                    "recording_playback_prepare_completed",
                    metadata: [
                        "source_ext": pathExt,
                        "operation": "decrypt_temp",
                        "did_remux": "false",
                        "elapsed_ms": elapsedMs()
                    ]
                )
                return (tempURL, false)
            }

            guard let ffmpegPath = resolveFFmpegPath() else {
                if allowTransportStreamFallback {
                    let transportTempURL = recordingEncryptionManager.tempTransportPlaybackURL()
                    do {
                        try await copyTransportStreamForPlaybackToTemp(sourceURL: tempURL, tempURL: transportTempURL)
                        try? FileManager.default.removeItem(at: tempURL)
                        GlitchoTelemetry.track(
                            "recording_playback_prepare_completed",
                            metadata: [
                                "source_ext": pathExt,
                                "operation": "decrypt_transport_passthrough_temp",
                                "did_remux": "false",
                                "elapsed_ms": elapsedMs()
                            ]
                        )
                        return (transportTempURL, false)
                    } catch {
                        GlitchoTelemetry.track(
                            "recording_playback_prepare_failed",
                            metadata: [
                                "source_ext": pathExt,
                                "operation": "decrypt_transport_passthrough_temp",
                                "error": error.localizedDescription,
                                "elapsed_ms": elapsedMs()
                            ]
                        )
                    }
                }

                GlitchoTelemetry.track(
                    "recording_playback_prepare_failed",
                    metadata: [
                        "source_ext": pathExt,
                        "operation": "decrypt_remux",
                        "error": "ffmpeg_not_found",
                        "elapsed_ms": elapsedMs()
                    ]
                )
                throw NSError(
                    domain: "RecordingError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "FFmpeg was not found. Set it in Settings → Recording, or install ffmpeg (e.g. via Homebrew)."]
                )
            }

            let remuxTempURL = uniqueTemporaryMP4URL(for: tempURL)
            do {
                let didRemux = try await _remuxIfNeeded(url: tempURL, ffmpegPath: ffmpegPath, tempURL: remuxTempURL)
                GlitchoTelemetry.track(
                    "recording_playback_prepare_completed",
                    metadata: [
                        "source_ext": pathExt,
                        "operation": didRemux ? "decrypt_remux" : "decrypt_temp",
                        "did_remux": didRemux ? "true" : "false",
                        "elapsed_ms": elapsedMs()
                    ]
                )
                return (tempURL, didRemux)
            } catch {
                GlitchoTelemetry.track(
                    "recording_playback_prepare_failed",
                    metadata: [
                        "source_ext": pathExt,
                        "operation": "decrypt_remux",
                        "error": error.localizedDescription,
                        "elapsed_ms": elapsedMs()
                    ]
                )
                throw error
            }
        }
        guard pathExt == "mp4" else {
            GlitchoTelemetry.track(
                "recording_playback_prepare_completed",
                metadata: [
                    "source_ext": pathExt.isEmpty ? "none" : pathExt,
                    "operation": "passthrough",
                    "did_remux": "false",
                    "elapsed_ms": elapsedMs()
                ]
            )
            return (url, false)
        }

        // No remux needed for already-playable MP4 files.
        guard isTransportStreamFile(at: url) else {
            GlitchoTelemetry.track(
                "recording_playback_prepare_completed",
                metadata: [
                    "source_ext": pathExt,
                    "operation": "passthrough",
                    "did_remux": "false",
                    "elapsed_ms": elapsedMs()
                ]
            )
            return (url, false)
        }

        // Resolve main-actor-bound state up front (fast, no disk I/O).
        guard let ffmpegPath = resolveFFmpegPath() else {
            if allowTransportStreamFallback {
                let tempURL = recordingEncryptionManager.tempTransportPlaybackURL()
                do {
                    try await copyTransportStreamForPlaybackToTemp(sourceURL: url, tempURL: tempURL)
                    GlitchoTelemetry.track(
                        "recording_playback_prepare_completed",
                        metadata: [
                            "source_ext": pathExt,
                            "operation": "transport_passthrough_temp",
                            "did_remux": "false",
                            "elapsed_ms": elapsedMs()
                        ]
                    )
                    return (tempURL, false)
                } catch {
                    GlitchoTelemetry.track(
                        "recording_playback_prepare_failed",
                        metadata: [
                            "source_ext": pathExt,
                            "operation": "transport_passthrough_temp",
                            "error": error.localizedDescription,
                            "elapsed_ms": elapsedMs()
                        ]
                    )
                }
            }

            GlitchoTelemetry.track(
                "recording_playback_prepare_failed",
                metadata: [
                    "source_ext": pathExt,
                    "operation": "remux",
                    "error": "ffmpeg_not_found",
                    "elapsed_ms": elapsedMs()
                ]
            )
            throw NSError(
                domain: "RecordingError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "FFmpeg was not found. Set it in Settings → Recording, or install ffmpeg (e.g. via Homebrew)."]
            )
        }
        let tempURL = uniqueTemporaryMP4URL(for: url)

        // Awaiting a nonisolated async function from @MainActor suspends the main actor and
        // runs the callee on the cooperative thread pool — no Task.detached needed and no
        // self-capture that could trigger an unexpected hop back to main actor.
        let didRemux: Bool
        do {
            didRemux = try await _remuxIfNeeded(url: url, ffmpegPath: ffmpegPath, tempURL: tempURL)
        } catch {
            GlitchoTelemetry.track(
                "recording_playback_prepare_failed",
                metadata: [
                    "source_ext": pathExt,
                    "operation": "remux",
                    "error": error.localizedDescription,
                    "elapsed_ms": elapsedMs()
                ]
            )
            throw error
        }

        GlitchoTelemetry.track(
            "recording_playback_prepare_completed",
            metadata: [
                "source_ext": pathExt,
                "operation": didRemux ? "remux" : "passthrough",
                "did_remux": didRemux ? "true" : "false",
                "elapsed_ms": elapsedMs()
            ]
        )
        return (url, didRemux)
    }

    /// Nonisolated async helper that runs file inspection and ffmpeg entirely on the
    /// cooperative thread pool. Called via `await` from the @MainActor function above,
    /// which is the correct way to hop off the main actor without Task.detached.
    nonisolated private func _remuxIfNeeded(url: URL, ffmpegPath: String, tempURL: URL) async throws -> Bool {
        let isTS = isTransportStreamFile(at: url)
        guard isTS else { return false }
        do {
            _ = try await runProcess(
                executable: ffmpegPath,
                arguments: [
                    "-y", "-hide_banner", "-loglevel", "error",
                    "-i", url.path,
                    "-c", "copy",
                    "-movflags", "+faststart",
                    "-bsf:a", "aac_adtstoasc",
                    tempURL.path
                ]
            )
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    nonisolated private func copyTransportStreamForPlaybackToTemp(sourceURL: URL, tempURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try FileManager.default.removeItem(at: tempURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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

    nonisolated func isTransportStreamFile(at url: URL) -> Bool {
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

    nonisolated private func uniqueTemporaryMP4URL(for url: URL) -> URL {
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

    private func resolveDownloadWorkerPath() -> String? {
        let candidates: [String?] = [
            bundledDownloadWorkerPath(),
            installedDownloadWorkerPath()
        ]
        for candidate in candidates {
            guard let path = candidate, !path.isEmpty else { continue }
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func bundledDownloadWorkerPath() -> String? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("GlitchoRecorderAgent")
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private func installedDownloadWorkerPath() -> String? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let candidate = base
            .appendingPathComponent("Glitcho", isDirectory: true)
            .appendingPathComponent("BackgroundRecorder", isDirectory: true)
            .appendingPathComponent("GlitchoRecorderAgent")
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
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
        guard let host = url.host?.lowercased(), host.contains("twitch.tv"), host != "clips.twitch.tv" else {
            return nil
        }

        let parts = url.path.split(separator: "/").map { String($0).lowercased() }
        guard let first = parts.first, !first.isEmpty else { return nil }
        guard !isReservedTwitchPathComponent(first) else { return nil }
        if parts.count >= 2 {
            let second = parts[1]
            if second == "videos" || second == "clip" || second == "clips" {
                return nil
            }
        }
        return first
    }

    private func isReservedTwitchPathComponent(_ value: String) -> Bool {
        let reserved: Set<String> = [
            "directory", "downloads", "login", "logout", "search", "settings", "signup", "p",
            "following", "browse", "drops", "subs", "inventory", "videos", "clip", "clips",
            "turbo", "wallet"
        ]
        return reserved.contains(value.lowercased())
    }

    private func sanitizedFilenameComponent(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? nil : cleaned
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

    nonisolated func runProcess(
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

extension Notification.Name {
    static let recordingLibraryDidChange = Notification.Name("com.glitcho.recordingLibraryDidChange")
}
