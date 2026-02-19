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
