import Foundation

#if canImport(SwiftUI)

@MainActor
final class RecorderOrchestrator {
    enum JobState: String, Codable, Equatable {
        case idle = "Idle"
        case queued = "Queued"
        case recording = "Recording"
        case stopping = "Stopping"
        case error = "Error"
        case retrying = "Retrying"
    }

    struct RetryMetadata: Codable, Equatable {
        var retryCount: Int
        var lastFailureAt: Date?
        var nextRetryAt: Date?
        var lastErrorMessage: String?

        init(
            retryCount: Int = 0,
            lastFailureAt: Date? = nil,
            nextRetryAt: Date? = nil,
            lastErrorMessage: String? = nil
        ) {
            self.retryCount = retryCount
            self.lastFailureAt = lastFailureAt
            self.nextRetryAt = nextRetryAt
            self.lastErrorMessage = lastErrorMessage
        }
    }

    struct JobStatus: Codable, Equatable {
        let login: String
        var state: JobState
        var retry: RetryMetadata
    }

    var maxConcurrentRecordings: Int {
        didSet {
            maxConcurrentRecordings = max(1, maxConcurrentRecordings)
        }
    }

    let retryDelay: TimeInterval
    let maxRetryDelay: TimeInterval

    private var jobs: [String: JobStatus] = [:]
    private var queuedLogins: [String] = []

    init(
        maxConcurrentRecordings: Int = 2,
        retryDelay: TimeInterval = 30,
        maxRetryDelay: TimeInterval = 300
    ) {
        self.maxConcurrentRecordings = max(1, maxConcurrentRecordings)
        self.retryDelay = max(1, retryDelay)
        self.maxRetryDelay = max(1, maxRetryDelay)
    }

    func state(for channelLogin: String?) -> JobState {
        guard let normalized = normalizedLogin(channelLogin) else { return .idle }
        return jobs[normalized]?.state ?? .idle
    }

    func retryMetadata(for channelLogin: String?) -> RetryMetadata? {
        guard let normalized = normalizedLogin(channelLogin) else { return nil }
        return jobs[normalized]?.retry
    }

    func setQueued(for channelLogin: String?) {
        guard let normalized = normalizedLogin(channelLogin) else { return }
        updateStatus(for: normalized) { status in
            status.state = .queued
        }
        if !queuedLogins.contains(normalized) {
            queuedLogins.append(normalized)
        }
    }

    func setRecording(for channelLogin: String?) {
        guard let normalized = normalizedLogin(channelLogin) else { return }
        removeNormalizedFromQueue(normalized)
        updateStatus(for: normalized) { status in
            status.state = .recording
            status.retry = RetryMetadata()
        }
    }

    func setStopping(for channelLogin: String?) {
        setState(.stopping, for: channelLogin)
    }

    func setIdle(for channelLogin: String?) {
        guard let normalized = normalizedLogin(channelLogin) else { return }
        removeNormalizedFromQueue(normalized)
        updateStatus(for: normalized) { status in
            status.state = .idle
            status.retry.nextRetryAt = nil
        }
    }

    func setError(for channelLogin: String?, errorMessage: String?, failedAt: Date = Date()) {
        guard let normalized = normalizedLogin(channelLogin) else { return }
        removeNormalizedFromQueue(normalized)
        updateStatus(for: normalized) { status in
            status.state = .error
            status.retry.lastFailureAt = failedAt
            status.retry.lastErrorMessage = sanitizedErrorMessage(errorMessage)
            status.retry.nextRetryAt = nil
        }
    }

    @discardableResult
    func scheduleRetry(
        for channelLogin: String?,
        now: Date = Date(),
        errorMessage: String? = nil
    ) -> Date? {
        guard let normalized = normalizedLogin(channelLogin) else { return nil }
        removeNormalizedFromQueue(normalized)

        var nextRetryAt: Date?
        updateStatus(for: normalized) { status in
            status.retry.retryCount += 1
            status.retry.lastFailureAt = now
            if let message = sanitizedErrorMessage(errorMessage) {
                status.retry.lastErrorMessage = message
            }

            let exponent = Double(max(0, status.retry.retryCount - 1))
            let delay = min(retryDelay * pow(2, exponent), maxRetryDelay)
            nextRetryAt = now.addingTimeInterval(delay)
            status.retry.nextRetryAt = nextRetryAt
            status.state = .retrying
        }

        return nextRetryAt
    }

    func dequeueNextQueuedLogin() -> String? {
        while let first = queuedLogins.first {
            queuedLogins.removeFirst()
            if state(for: first) == .queued {
                return first
            }
        }
        return nil
    }

    func removeFromQueue(login channelLogin: String?) {
        guard let normalized = normalizedLogin(channelLogin) else { return }
        removeNormalizedFromQueue(normalized)
    }

    private func setState(_ state: JobState, for channelLogin: String?) {
        guard let normalized = normalizedLogin(channelLogin) else { return }
        updateStatus(for: normalized) { status in
            status.state = state
        }
    }

    private func removeNormalizedFromQueue(_ normalizedLogin: String) {
        queuedLogins.removeAll { $0 == normalizedLogin }
    }

    private func updateStatus(for normalizedLogin: String, _ mutate: (inout JobStatus) -> Void) {
        var status = jobs[normalizedLogin] ?? JobStatus(
            login: normalizedLogin,
            state: .idle,
            retry: RetryMetadata()
        )
        mutate(&status)
        jobs[normalizedLogin] = status
    }

    private func normalizedLogin(_ channelLogin: String?) -> String? {
        guard let channelLogin else { return nil }
        let normalized = channelLogin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func sanitizedErrorMessage(_ errorMessage: String?) -> String? {
        guard let errorMessage else { return nil }
        let sanitized = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }
}

#endif
