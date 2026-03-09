import Foundation

#if canImport(SwiftUI)

struct CompanionHealthResponse: Decodable {
    let ok: Bool
    let service: String?
    let timestamp: String?
}

struct CompanionRecordingStatusResponse: Decodable {
    let ok: Bool
    let licensed: Bool?
    let active_recordings: Int?
    let background_recordings: Int?
    let any_recording: Bool?
    let badge_channel: String?
    let timestamp: String?
}

struct CompanionRecordingsResponse: Decodable {
    struct Recording: Decodable {
        let channel_name: String
        let filename: String
        let path: String?
        let recorded_at: String?
    }

    let ok: Bool
    let recordings: [Recording]
}

struct CompanionDownloadsStatusResponse: Decodable {
    struct Summary: Decodable {
        let total: Int
        let active: Int
        let paused: Int
        let failed: Int
        let completed: Int
        let canceled: Int
    }

    struct DownloadTask: Decodable {
        let id: String
        let target: String
        let channel_name: String?
        let quality: String
        let capture_type: String
        let state: String
        let started_at: String?
        let updated_at: String
        let progress_fraction: Double?
        let bytes_written: Int64
        let status_message: String?
        let last_error_message: String?
        let retry_count: Int
    }

    let ok: Bool
    let summary: Summary
    let tasks: [DownloadTask]
}

struct CompanionActionResponse: Decodable {
    let ok: Bool
}

final class CompanionAPIClient {
    let baseURL: URL
    var token: String

    init(baseURL: URL, token: String = "") {
        self.baseURL = baseURL
        self.token = token
    }

    func health() async throws -> CompanionHealthResponse {
        try await request(path: "/health", method: "GET")
    }

    func status() async throws -> CompanionRecordingStatusResponse {
        try await request(path: "/recording/status", method: "GET")
    }

    func recordings() async throws -> CompanionRecordingsResponse {
        try await request(path: "/recordings", method: "GET")
    }

    func startRecording(target: String, channelName: String?, quality: String = "best") async throws {
        let payload = CompanionRecordingStartRequest(target: target, channelName: channelName, quality: quality)
        _ = try await request(path: "/recording/start", method: "POST", body: payload) as CompanionHealthResponse
    }

    func stopRecording(channelLogin: String? = nil) async throws {
        let payload = CompanionRecordingStopRequest(channelLogin: channelLogin)
        _ = try await request(path: "/recording/stop", method: "POST", body: payload) as CompanionHealthResponse
    }

    func downloadsStatus() async throws -> CompanionDownloadsStatusResponse {
        try await request(path: "/downloads/status", method: "GET")
    }

    func pauseDownload(id: String? = nil) async throws {
        _ = try await request(
            path: "/downloads/pause",
            method: "POST",
            body: CompanionDownloadTaskRequest(id: id)
        ) as CompanionActionResponse
    }

    func resumeDownload(id: String? = nil) async throws {
        _ = try await request(
            path: "/downloads/resume",
            method: "POST",
            body: CompanionDownloadTaskRequest(id: id)
        ) as CompanionActionResponse
    }

    func retryFailedDownloads() async throws {
        _ = try await request(path: "/downloads/retry-failed", method: "POST", body: CompanionDownloadTaskRequest(id: nil)) as CompanionActionResponse
    }

    func clearCompletedDownloads() async throws {
        _ = try await request(path: "/downloads/clear-completed", method: "POST", body: CompanionDownloadTaskRequest(id: nil)) as CompanionActionResponse
    }

    func cancelActiveDownloads() async throws {
        _ = try await request(path: "/downloads/cancel-active", method: "POST", body: CompanionDownloadTaskRequest(id: nil)) as CompanionActionResponse
    }

    private func request<T: Decodable, B: Encodable>(path: String, method: String, body: B?) async throws -> T {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "CompanionAPIClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Companion API request failed"]
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request<T: Decodable>(path: String, method: String) async throws -> T {
        try await request(path: path, method: method, body: Optional<String>.none)
    }
}

#endif
