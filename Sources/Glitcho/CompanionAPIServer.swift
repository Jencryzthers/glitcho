import Foundation
import Network

#if canImport(SwiftUI)

final class CompanionAPIServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var endpoint = ""
    @Published private(set) var lastRequestSummary = ""
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.glitcho.companion-api", qos: .utility)
    private weak var recordingManager: RecordingManager?
    private var authToken = ""
    private var boundPort: UInt16?

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct HTTPResponse {
        let statusCode: Int
        let body: Data
        let contentType: String

        static func json(statusCode: Int, object: Any) -> HTTPResponse {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return HTTPResponse(statusCode: statusCode, body: data, contentType: "application/json")
        }
    }

    func configure(
        enabled: Bool,
        port: Int,
        token: String,
        recordingManager: RecordingManager
    ) {
        self.recordingManager = recordingManager

        let normalizedPort = UInt16(max(1024, min(port, 65535)))
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        if !enabled {
            stop()
            return
        }

        if isRunning, boundPort == normalizedPort, authToken == normalizedToken {
            return
        }

        stop()
        start(port: normalizedPort, token: normalizedToken)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        endpoint = ""
        boundPort = nil
    }

    private func start(port: UInt16, token: String) {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                lastError = "Invalid companion API port."
                return
            }

            let listener = try NWListener(using: .tcp, on: nwPort)
            authToken = token
            boundPort = port

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.lastError = nil
                        self.endpoint = "http://0.0.0.0:\(port)"
                    case .failed(let error):
                        self.isRunning = false
                        self.lastError = "Companion API failed: \(error.localizedDescription)"
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = "Unable to start companion API: \(error.localizedDescription)"
            isRunning = false
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let content {
                buffer.append(content)
            }

            if let request = self.parseRequest(from: buffer) {
                self.process(request: request, on: connection)
                return
            }

            if isComplete {
                let response = HTTPResponse.json(statusCode: 400, object: ["ok": false, "error": "invalid_request"])
                self.send(response: response, on: connection)
                return
            }

            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func parseRequest(from data: Data) -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else { return nil }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let availableBodyLength = data.count - bodyStart
        guard availableBodyLength >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        return HTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private func process(request: HTTPRequest, on connection: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self else {
                connection.cancel()
                return
            }

            let response = self.route(request: request)
            let payload = self.responsePayload(response: response)
            self.queue.async {
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    @MainActor
    private func route(request: HTTPRequest) -> HTTPResponse {
        let routePath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path

        if !authToken.isEmpty {
            let authHeader = request.headers["authorization"] ?? ""
            if authHeader != "Bearer \(authToken)" {
                return .json(statusCode: 401, object: ["ok": false, "error": "unauthorized"])
            }
        }

        guard let recordingManager else {
            return .json(statusCode: 500, object: ["ok": false, "error": "server_not_ready"])
        }

        switch (request.method, routePath) {
        case ("GET", "/health"):
            lastRequestSummary = "GET /health"
            return .json(statusCode: 200, object: [
                "ok": true,
                "service": "glitcho-companion-api",
                "timestamp": isoDate(Date())
            ])

        case ("GET", "/recording/status"):
            lastRequestSummary = "GET /recording/status"
            return .json(statusCode: 200, object: [
                "ok": true,
                "licensed": true,
                "active_recordings": recordingManager.activeRecordingCount,
                "background_recordings": recordingManager.backgroundRecordingCount,
                "any_recording": recordingManager.isAnyRecordingIncludingBackground(),
                "badge_channel": recordingManager.recordingBadgeChannelIncludingBackground() ?? NSNull(),
                "timestamp": isoDate(Date())
            ])

        case ("GET", "/recordings"):
            lastRequestSummary = "GET /recordings"
            let recordings = recordingManager.listRecordings().map { entry in
                [
                    "channel_name": entry.channelName,
                    "filename": entry.url.lastPathComponent,
                    "path": entry.url.path,
                    "recorded_at": entry.recordedAt.map(isoDate) ?? NSNull()
                ] as [String: Any]
            }
            return .json(statusCode: 200, object: ["ok": true, "recordings": recordings])

        case ("POST", "/recording/start"):
            lastRequestSummary = "POST /recording/start"
            guard let startRequest = try? JSONDecoder().decode(CompanionRecordingStartRequest.self, from: request.body) else {
                return .json(statusCode: 400, object: ["ok": false, "error": "invalid_body"])
            }

            let didStart = recordingManager.startRecording(
                target: startRequest.target,
                channelName: startRequest.channelName,
                quality: startRequest.quality ?? "best"
            )
            if didStart {
                return .json(statusCode: 200, object: ["ok": true, "started": true])
            }
            return .json(statusCode: 409, object: [
                "ok": false,
                "started": false,
                "error": recordingManager.errorMessage ?? "unable_to_start"
            ])

        case ("POST", "/recording/stop"):
            lastRequestSummary = "POST /recording/stop"
            if let stopRequest = try? JSONDecoder().decode(CompanionRecordingStopRequest.self, from: request.body),
               let channelLogin = stopRequest.channelLogin?.trimmingCharacters(in: .whitespacesAndNewlines),
               !channelLogin.isEmpty {
                recordingManager.stopRecording(channelLogin: channelLogin)
            } else {
                recordingManager.stopRecording()
            }
            return .json(statusCode: 200, object: ["ok": true, "stopped": true])

        default:
            return .json(statusCode: 404, object: ["ok": false, "error": "not_found"])
        }
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        let payload = responsePayload(response: response)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func responsePayload(response: HTTPResponse) -> Data {
        let statusText: String
        switch response.statusCode {
        case 200:
            statusText = "OK"
        case 400:
            statusText = "Bad Request"
        case 401:
            statusText = "Unauthorized"
        case 404:
            statusText = "Not Found"
        case 409:
            statusText = "Conflict"
        default:
            statusText = "Error"
        }

        var head = "HTTP/1.1 \(response.statusCode) \(statusText)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        return payload
    }

    private func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

#endif
