#if canImport(SwiftUI)
import Foundation
import AppKit
import CryptoKit
import Network
import Security
import WebKit

struct NativePlaybackRequest: Equatable {
    enum Kind: String, Equatable {
        case liveChannel
        case vod
        case clip
    }

    let kind: Kind
    /// Argument to pass to Streamlink (URL or "twitch.tv/<channel>").
    let streamlinkTarget: String
    /// Optional channel name used for chat/about panels.
    let channelName: String?
}

struct TwitchChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let thumbnailURL: URL?
    let viewerCount: Int
    let gameName: String
    let title: String
    let startedAt: Date?

    init(id: String, name: String, url: URL, thumbnailURL: URL?,
         viewerCount: Int = 0, gameName: String = "", title: String = "",
         startedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.viewerCount = viewerCount
        self.gameName = gameName
        self.title = title
        self.startedAt = startedAt
    }
}

extension Notification.Name {
    static let channelsWentLive = Notification.Name("com.glitcho.channelsWentLive")
}

struct TwitchProfile {
    let name: String?
    let avatarURL: URL?
    let isLoggedIn: Bool
}

struct ChannelNotificationToggle: Equatable {
    let login: String
    let enabled: Bool
}

struct ChannelPinRequest: Equatable {
    let login: String
    let displayName: String
    let nonce: UUID
}

struct ExternalAuthNotice: Equatable {
    let message: String
    let isError: Bool
    let nonce: UUID
}

final class WebViewStore: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let homeURL: URL

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var estimatedProgress: Double = 0
    @Published var pageTitle = "Twitch"
    @Published var pageURL: String = "twitch.tv"
    @Published var followedLive: [TwitchChannel] = []
    @Published var followedChannelLogins: [String] = []
    @Published var offlineChannelAvatarURLs: [String: URL] = [:]  // login → avatar URL
    @Published var profileName: String?
    @Published var profileLogin: String?
    @Published var profileAvatarURL: URL?
    @Published var isLoggedIn = false
    @Published var shouldSwitchToNativePlayback: NativePlaybackRequest? = nil
    @Published var channelNotificationToggle: ChannelNotificationToggle? = nil
    @Published var channelPinRequest: ChannelPinRequest? = nil
    @Published var externalAuthInProgress = false
    @Published var externalAuthNotice: ExternalAuthNotice? = nil

    private var observations: [NSKeyValueObservation] = []
    private var backgroundWebView: WKWebView?
    private var followedRefreshTimer: Timer?
    private var followActionWebView: WKWebView?
    private var followActionTeardownWork: DispatchWorkItem?
    private weak var mainMessageController: WKUserContentController?
    private weak var backgroundMessageController: WKUserContentController?
    private let followActionDelegate = FollowActionDelegate()
    private var wasLoggedIn = false
    private var lastNonChannelURL: URL?
    private var followedWarmupAttempts = 0
    private var lastFollowedLiveUpdateAt = Date.distantPast
    private var lastFollowedChannelsSyncAt = Date.distantPast
    private var mainWebViewUsesAuthProfile = false
    private var hasPurgedTwitchDataForAuth = false
    private var webPlaybackSuppressed = false
    private var externalAuthState: StoredExternalAuthState?
    private var externalAuthTask: Task<Void, Never>?

    private static let sharedProcessPool = WKProcessPool()
    private static let twitchWebClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private static let followedChannelsCacheKey = "webview.followedChannelLogins.v1"
    private static let avatarCacheKey = "webview.offlineAvatarURLs.v1"
    private static let externalAuthStorageKey = "webview.externalAuthState.v1"
    private static let externalAuthClientIDOverrideKey = "webview.externalAuthClientID"
    private static let externalAuthCallbackPath = "/oauth/callback"
    private static let externalAuthScopes = "user:read:follows"

    private struct StoredExternalAuthState: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let login: String?
        let displayName: String?
        let avatarURLString: String?
    }

    private struct OAuthTokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    private struct OAuthDeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let verification_uri_complete: String?
        let expires_in: Int
        let interval: Int?
    }

    private struct OAuthValidateResponse: Decodable {
        let login: String?
        let user_id: String?
        let expires_in: Int?
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String?
        let message: String?
        let status: Int?
    }

    private enum ExternalOAuthError: LocalizedError {
        case callbackTimeout
        case callbackMissingCode
        case stateMismatch
        case browserOpenFailed
        case tokenExchangeFailed(String)
        case validateFailed(String)

        var errorDescription: String? {
            switch self {
            case .callbackTimeout:
                return "External login timed out waiting for Twitch redirect back to Glitcho."
            case .callbackMissingCode:
                return "Login callback did not include an authorization code."
            case .stateMismatch:
                return "Login callback state did not match."
            case .browserOpenFailed:
                return "Unable to open the system browser for Twitch login."
            case .tokenExchangeFailed(let message):
                return "OAuth token exchange failed: \(message)"
            case .validateFailed(let message):
                return "OAuth token validation failed: \(message)"
            }
        }
    }

    private final class OAuthCallbackListener {
        private let expectedState: String
        private let callbackPath: String
        private let listener: NWListener
        private let queue = DispatchQueue(label: "com.glitcho.external-auth-callback")
        private let readySemaphore = DispatchSemaphore(value: 0)
        private let callbackSemaphore = DispatchSemaphore(value: 0)
        private var callbackResult: Result<String, Error>?

        private(set) var port: UInt16 = 0

        init(expectedState: String, callbackPath: String) throws {
            self.expectedState = expectedState
            self.callbackPath = callbackPath
            self.listener = try NWListener(using: .tcp, on: .any)

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.readySemaphore.signal()
                case .failed(let error):
                    self.complete(.failure(error))
                    self.readySemaphore.signal()
                case .cancelled:
                    self.complete(.failure(ExternalOAuthError.callbackTimeout))
                    self.readySemaphore.signal()
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            listener.start(queue: queue)
            let ready = readySemaphore.wait(timeout: .now() + 5)
            guard ready == .success,
                  let rawPort = listener.port?.rawValue else {
                listener.cancel()
                throw ExternalOAuthError.callbackTimeout
            }
            self.port = rawPort
        }

        func waitForCode(timeout: TimeInterval) throws -> String {
            let result = callbackSemaphore.wait(timeout: .now() + timeout)
            listener.cancel()
            guard result == .success else {
                throw ExternalOAuthError.callbackTimeout
            }
            guard let callbackResult else {
                throw ExternalOAuthError.callbackTimeout
            }
            switch callbackResult {
            case .success(let code):
                return code
            case .failure(let error):
                throw error
            }
        }

        func cancel() {
            listener.cancel()
        }

        private func complete(_ result: Result<String, Error>) {
            queue.async {
                guard self.callbackResult == nil else { return }
                self.callbackResult = result
                self.callbackSemaphore.signal()
            }
        }

        private func handle(connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
                guard let self else { return }
                if let error {
                    self.sendResponse(
                        to: connection,
                        status: 500,
                        title: "Login Error",
                        body: "Failed to read OAuth callback (\(error.localizedDescription))."
                    )
                    self.complete(.failure(error))
                    return
                }

                let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first ?? ""
                let tokens = firstLine.split(separator: " ")
                guard tokens.count >= 2 else {
                    self.sendResponse(
                        to: connection,
                        status: 400,
                        title: "Login Error",
                        body: "Malformed OAuth callback request."
                    )
                    self.complete(.failure(ExternalOAuthError.callbackMissingCode))
                    return
                }

                let target = String(tokens[1])
                guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
                    self.sendResponse(
                        to: connection,
                        status: 400,
                        title: "Login Error",
                        body: "Malformed callback URL."
                    )
                    self.complete(.failure(ExternalOAuthError.callbackMissingCode))
                    return
                }

                let path = components.path
                guard path == callbackPath else {
                    self.sendResponse(
                        to: connection,
                        status: 404,
                        title: "Login Error",
                        body: "Unexpected callback path."
                    )
                    self.complete(.failure(ExternalOAuthError.callbackMissingCode))
                    return
                }

                let queryItems = components.queryItems ?? []
                let errorMessage = queryItems.first(where: { $0.name == "error_description" })?.value
                    ?? queryItems.first(where: { $0.name == "error" })?.value
                if let errorMessage, !errorMessage.isEmpty {
                    self.sendResponse(
                        to: connection,
                        status: 400,
                        title: "Login Error",
                        body: errorMessage
                    )
                    self.complete(.failure(ExternalOAuthError.tokenExchangeFailed(errorMessage)))
                    return
                }

                let callbackState = queryItems.first(where: { $0.name == "state" })?.value ?? ""
                guard callbackState == expectedState else {
                    self.sendResponse(
                        to: connection,
                        status: 400,
                        title: "Login Error",
                        body: "State verification failed."
                    )
                    self.complete(.failure(ExternalOAuthError.stateMismatch))
                    return
                }

                guard let code = queryItems.first(where: { $0.name == "code" })?.value,
                      !code.isEmpty else {
                    self.sendResponse(
                        to: connection,
                        status: 400,
                        title: "Login Error",
                        body: "Authorization code is missing."
                    )
                    self.complete(.failure(ExternalOAuthError.callbackMissingCode))
                    return
                }

                self.sendResponse(
                    to: connection,
                    status: 200,
                    title: "Login Complete",
                    body: "You can return to Glitcho."
                )
                self.complete(.success(code))
            }
        }

        private func sendResponse(to connection: NWConnection, status: Int, title: String, body: String) {
            let html = """
            <html><head><meta charset="utf-8"><title>\(title)</title></head>
            <body style="font-family:-apple-system,system-ui,sans-serif;background:#111;color:#f5f5f5;padding:32px;">
            <h2>\(title)</h2><p>\(body)</p></body></html>
            """
            let payload = Data(html.utf8)
            var response = "HTTP/1.1 \(status)\r\n"
            response += "Content-Type: text/html; charset=utf-8\r\n"
            response += "Content-Length: \(payload.count)\r\n"
            response += "Connection: close\r\n\r\n"

            var content = Data(response.utf8)
            content.append(payload)
            connection.send(content: content, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private struct HelixUsersResponse: Decodable {
        let data: [HelixUser]
    }

    private struct HelixUser: Decodable {
        let id: String
    }

    private struct HelixProfileUsersResponse: Decodable {
        let data: [HelixProfileUser]
    }

    private struct HelixProfileUser: Decodable {
        let login: String
        let display_name: String?
        let profile_image_url: String?
    }

    private struct HelixFollowedStreamsResponse: Decodable {
        let data: [HelixFollowedStream]
        let pagination: HelixPagination?
    }

    private struct HelixFollowedChannelsResponse: Decodable {
        let data: [HelixFollowedChannel]
        let pagination: HelixPagination?
    }

    private struct HelixPagination: Decodable {
        let cursor: String?
    }

    private struct HelixFollowedStream: Decodable {
        let user_login: String
        let user_name: String
        let thumbnail_url: String?
        let viewer_count: Int?
        let game_name: String?
        let title: String?
        let started_at: String?
    }

    private struct HelixFollowedChannel: Decodable {
        let broadcaster_login: String
    }


    init(url: URL) {
        self.homeURL = url

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        mainMessageController = contentController
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.safariUserAgent
        self.webView = webView

        super.init()
        followedChannelLogins = loadCachedFollowedChannelLogins()
        offlineChannelAvatarURLs = loadCachedAvatarURLs()
        restoreExternalAuthStateFromStorage()
        followActionDelegate.onDidFinish = { [weak self] webView in
            self?.runFollowScript(in: webView)
        }

        contentController.add(self, name: "followedLive")
        contentController.add(self, name: "sideNavFollowedLogins")
        contentController.add(self, name: "profile")
        contentController.add(self, name: "channelNotification")
        contentController.add(self, name: "channelPin")
        contentController.add(self, name: "consoleLog")
        contentController.add(self, name: "vodThumbnailRequest")
        Self.installDefaultMainUserScripts(on: contentController)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let initialURL = normalizedTwitchURL(url)
        configureMainWebViewProfile(for: initialURL)
        webView.load(URLRequest(url: initialURL))
        backgroundWebView = makeBackgroundWebView()
        loadFollowedLiveInBackground()

        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, change in
                self?.canGoBack = change.newValue ?? false
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, change in
                self?.canGoForward = change.newValue ?? false
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, change in
                self?.isLoading = change.newValue ?? false
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, change in
                self?.estimatedProgress = change.newValue ?? 0
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] _, change in
                let title = (change.newValue ?? nil) ?? "Twitch"
                self?.pageTitle = title.isEmpty ? "Twitch" : title
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, change in
                guard let self else { return }
                guard let url = change.newValue ?? nil else {
                    self.pageURL = "twitch.tv"
                    return
                }

                if let host = url.host {
                    self.pageURL = host
                } else {
                    self.pageURL = "twitch.tv"
                }

                // Twitch est une SPA: beaucoup de navigations n'entrent pas dans decidePolicyFor.
                // On détecte ici les URLs de chaînes pour basculer vers le player natif.
                if let request = self.nativePlaybackRequestIfNeeded(url: url) {
                    // Stopper le player web (sinon double audio) et revenir à la page précédente non-channel.
                    self.prepareWebViewForNativePlayer()
                    DispatchQueue.main.async {
                        if self.shouldSwitchToNativePlayback != request {
                            self.shouldSwitchToNativePlayback = request
                        }
                    }
                } else {
                    // Garder en mémoire la dernière page "non-channel" pour pouvoir y revenir après un switch natif.
                    if let host = url.host?.lowercased(), host.hasSuffix("twitch.tv") {
                        self.lastNonChannelURL = self.normalizedTwitchURL(url)
                    }
                }
            }
        ]
    }

    deinit {
        followedRefreshTimer?.invalidate()
        followActionTeardownWork?.cancel()
        externalAuthTask?.cancel()
        observations.forEach { $0.invalidate() }
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func goHome() {
        let url = normalizedTwitchURL(homeURL)
        configureMainWebViewProfile(for: url)
        webView.load(URLRequest(url: url))
    }

    func navigate(to url: URL) {
        let normalized = normalizedTwitchURL(url)
        configureMainWebViewProfile(for: normalized)
        if Self.isAuthRoute(url: normalized) {
            purgeTwitchDataForAuthIfNeeded { [weak self] in
                self?.webView.load(URLRequest(url: normalized))
            }
            return
        }
        webView.load(URLRequest(url: normalized))
    }

    func startExternalBrowserAuth() {
        if externalAuthInProgress { return }
        externalAuthTask?.cancel()
        externalAuthTask = Task { [weak self] in
            await self?.runExternalBrowserAuthFlow()
        }
    }

    func followChannel(login: String) {
        let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        let view = ensureFollowActionWebView()
        let url = URL(string: "https://www.twitch.tv/\(normalized)")!
        view.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak view] in
            guard let view else { return }
            self?.runFollowScript(in: view)

            // Refresh followed list after action completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.refreshFollowedList()
                self?.scheduleFollowActionTeardown()
            }
        }
    }

    /// Force refresh of the followed channels list
    func refreshFollowedList() {
        backgroundWebView?.reload()
        Task {
            _ = await refreshFollowedLiveUsingAPI()
        }
    }

    private func refreshFollowedLiveUsingAPI() async -> Bool {
        guard isLoggedIn else { return false }
        guard let login = profileLogin?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !login.isEmpty else { return false }
        guard let authToken = await twitchAuthToken() else { return false }

        do {
            let userID = try await fetchHelixUserID(login: login, authToken: authToken)
            let channels = try await fetchFollowedLiveHelixStreams(userID: userID, authToken: authToken)
            let now = Date()
            let liveLogins = Set(channels.map { $0.id.lowercased() })
            let cachedFollowedLogins = Set(followedChannelLogins.map { $0.lowercased() })
            let liveSubsetMissingInCache = !liveLogins.isSubset(of: cachedFollowedLogins)
            let shouldRefreshFollowedLogins =
                now.timeIntervalSince(lastFollowedChannelsSyncAt) > 60
                || followedChannelLogins.isEmpty
                || liveSubsetMissingInCache

            if shouldRefreshFollowedLogins {
                var followedLogins = try? await fetchFollowedChannelsLogins(userID: userID, authToken: authToken)
                if followedLogins == nil || followedLogins?.isEmpty == true {
                    followedLogins = try? await fetchFollowedChannelsGQL(authToken: authToken)
                }
                if let followedLogins, !followedLogins.isEmpty {
                    await MainActor.run {
                        if self.followedChannelLogins != followedLogins {
                            self.followedChannelLogins = followedLogins
                            self.persistFollowedChannelLogins(followedLogins)
                        }
                        self.lastFollowedChannelsSyncAt = now
                    }
                    // After the followedChannelLogins update block:
                    let offlineLogins = followedLogins.filter { login in
                        !channels.map({ $0.id }).contains(login)
                    }
                    Task {
                        await self.refreshOfflineAvatars(logins: offlineLogins)
                    }
                }
            }
            await MainActor.run {
                self.lastFollowedLiveUpdateAt = now
                if self.followedLive != channels {
                    let previousLogins = Set(self.followedLive.map(\.id))
                    if !previousLogins.isEmpty {
                        let newlyLive = channels.filter { !previousLogins.contains($0.id) }
                        if !newlyLive.isEmpty {
                            NotificationCenter.default.post(
                                name: .channelsWentLive,
                                object: nil,
                                userInfo: ["channels": newlyLive]
                            )
                        }
                    }
                    self.followedLive = channels
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func fetchHelixUserID(login: String, authToken: String) async throws -> String {
        var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
        components.queryItems = [URLQueryItem(name: "login", value: login)]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(currentOAuthClientID(), forHTTPHeaderField: "Client-Id")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(HelixUsersResponse.self, from: data)
        guard let userID = decoded.data.first?.id, !userID.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return userID
    }

    private func fetchFollowedLiveHelixStreams(userID: String, authToken: String) async throws -> [TwitchChannel] {
        var cursor: String?
        var channels: [TwitchChannel] = []

        repeat {
            var components = URLComponents(string: "https://api.twitch.tv/helix/streams/followed")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "user_id", value: userID),
                URLQueryItem(name: "first", value: "100")
            ]
            if let cursor, !cursor.isEmpty {
                queryItems.append(URLQueryItem(name: "after", value: cursor))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue(currentOAuthClientID(), forHTTPHeaderField: "Client-Id")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let decoded = try JSONDecoder().decode(HelixFollowedStreamsResponse.self, from: data)
            let iso8601Formatter: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime]
                return f
            }()
            let pageChannels = decoded.data.compactMap { stream -> TwitchChannel? in
                let login = stream.user_login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !login.isEmpty else { return nil }
                let name = stream.user_name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: "https://www.twitch.tv/\(login)") else { return nil }

                let thumbnailURL = stream.thumbnail_url
                    .map { value in
                        value
                            .replacingOccurrences(of: "{width}", with: "320")
                            .replacingOccurrences(of: "{height}", with: "180")
                    }
                    .flatMap(URL.init(string:))

                let startedAt: Date? = stream.started_at.flatMap { iso8601Formatter.date(from: $0) }

                return TwitchChannel(
                    id: login,
                    name: name.isEmpty ? login : name,
                    url: url,
                    thumbnailURL: thumbnailURL,
                    viewerCount: stream.viewer_count ?? 0,
                    gameName: stream.game_name ?? "",
                    title: stream.title ?? "",
                    startedAt: startedAt
                )
            }
            channels.append(contentsOf: pageChannels)
            cursor = decoded.pagination?.cursor
        } while cursor?.isEmpty == false

        return channels
            .deduplicatedByLogin()
            .sorted { lhs, rhs in
                lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }

    private func fetchFollowedChannelsLogins(userID: String, authToken: String) async throws -> [String] {
        var cursor: String?
        var logins: [String] = []

        repeat {
            var components = URLComponents(string: "https://api.twitch.tv/helix/channels/followed")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "user_id", value: userID),
                URLQueryItem(name: "first", value: "100")
            ]
            if let cursor, !cursor.isEmpty {
                queryItems.append(URLQueryItem(name: "after", value: cursor))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue(currentOAuthClientID(), forHTTPHeaderField: "Client-Id")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let decoded = try JSONDecoder().decode(HelixFollowedChannelsResponse.self, from: data)
            let pageLogins = decoded.data
                .map { $0.broadcaster_login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            logins.append(contentsOf: pageLogins)
            cursor = decoded.pagination?.cursor
        } while cursor?.isEmpty == false

        var seen = Set<String>()
        return logins.filter { seen.insert($0).inserted }.sorted()
    }

    private func fetchFollowedChannelsGQL(authToken: String) async throws -> [String] {
        var logins: [String] = []
        var cursor: String? = nil
        var pageCount = 0
        let maxPages = 20 // safety cap: 20 × 100 = 2 000 channels

        repeat {
            pageCount += 1
            guard pageCount <= maxPages else { break }

            let cursorClause = cursor.map { ", after: \"\($0)\"" } ?? ""
            let query = """
            query {
              currentUser {
                follows(first: 100\(cursorClause)) {
                  edges {
                    node { login }
                  }
                  pageInfo { hasNextPage endCursor }
                }
              }
            }
            """
            let body: [String: Any] = ["query": query]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { break }

            var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(currentOAuthClientID(), forHTTPHeaderField: "Client-ID")
            request.setValue("OAuth \(authToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { break }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let currentUser = dataObj["currentUser"] as? [String: Any],
                  let follows = currentUser["follows"] as? [String: Any],
                  let edges = follows["edges"] as? [[String: Any]] else { break }

            for edge in edges {
                guard let node = edge["node"] as? [String: Any],
                      let login = node["login"] as? String else { continue }
                let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty { logins.append(normalized) }
            }

            let pageInfo = follows["pageInfo"] as? [String: Any]
            let hasNextPage = pageInfo?["hasNextPage"] as? Bool ?? false
            cursor = hasNextPage ? (pageInfo?["endCursor"] as? String) : nil
        } while cursor != nil

        var seen = Set<String>()
        return logins.filter { seen.insert($0).inserted }.sorted()
    }

    private func twitchAuthToken() async -> String? {
        if let externalToken = currentExternalAuthToken() {
            return externalToken
        }
        let cookies = await webKitCookies()
        let names: Set<String> = ["auth-token", "auth_token", "auth-token-next", "auth_token_next"]
        return cookies.first(where: {
            names.contains($0.name.lowercased()) && $0.domain.lowercased().contains("twitch.tv")
        })?.value
    }

    /// Stoppe toute lecture (vidéo/audio) dans le WebView avant bascule vers le player natif.
    func prepareWebViewForNativePlayer() {
        webPlaybackSuppressed = true
        stopWebPlayback(in: webView, stopLoading: true)
        stopWebPlayback(in: backgroundWebView)
        stopWebPlayback(in: followActionWebView)
    }

    func restoreWebPlaybackAfterNativePlayer() {
        guard webPlaybackSuppressed else { return }
        webPlaybackSuppressed = false
        restoreWebPlayback(in: webView)
        restoreWebPlayback(in: backgroundWebView)
        restoreWebPlayback(in: followActionWebView)
    }

    private func stopWebPlayback(in targetWebView: WKWebView?, stopLoading: Bool = false) {
        guard let targetWebView else { return }
        if stopLoading {
            targetWebView.stopLoading()
            targetWebView.evaluateJavaScript("window.stop();", completionHandler: nil)
        }
        let js = """
        (function() {
          try {
            function stopAllMedia() {
              try {
                document.querySelectorAll('video,audio').forEach(function(el) {
                  try { el.pause(); } catch (e) {}
                  try { el.muted = true; } catch (e) {}
                  try { el.volume = 0; } catch (e) {}
                  try { el.removeAttribute('autoplay'); } catch (e) {}
                });
              } catch (e) {}
            }

            if (!window.__glitcho_native_media_original_play &&
                window.HTMLMediaElement &&
                HTMLMediaElement.prototype &&
                typeof HTMLMediaElement.prototype.play === 'function') {
              window.__glitcho_native_media_original_play = HTMLMediaElement.prototype.play;
              HTMLMediaElement.prototype.play = function() {
                try { this.pause(); } catch (e) {}
                try { this.muted = true; this.volume = 0; } catch (e) {}
                return Promise.resolve();
              };
            }

            stopAllMedia();

            if (!window.__glitcho_native_media_observer &&
                window.MutationObserver &&
                document.documentElement) {
              window.__glitcho_native_media_observer = new MutationObserver(stopAllMedia);
              window.__glitcho_native_media_observer.observe(document.documentElement, {
                childList: true,
                subtree: true
              });
            }

            if (!window.__glitcho_native_media_stop_timer) {
              window.__glitcho_native_media_stop_timer = setInterval(stopAllMedia, 750);
            }
          } catch (e) {}
        })();
        """
        targetWebView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func restoreWebPlayback(in targetWebView: WKWebView?) {
        guard let targetWebView else { return }
        let js = """
        (function() {
          try {
            if (window.__glitcho_native_media_stop_timer) {
              clearInterval(window.__glitcho_native_media_stop_timer);
              window.__glitcho_native_media_stop_timer = null;
            }
            if (window.__glitcho_native_media_observer) {
              try { window.__glitcho_native_media_observer.disconnect(); } catch (_) {}
              window.__glitcho_native_media_observer = null;
            }
            if (window.__glitcho_native_media_original_play &&
                window.HTMLMediaElement &&
                HTMLMediaElement.prototype) {
              HTMLMediaElement.prototype.play = window.__glitcho_native_media_original_play;
              window.__glitcho_native_media_original_play = null;
            }
          } catch (_) {}
        })();
        """
        targetWebView.evaluateJavaScript(js, completionHandler: nil)
    }

    func logout() {
        externalAuthTask?.cancel()
        clearExternalAuthState()
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()

        func matchesTwitch(_ record: WKWebsiteDataRecord) -> Bool {
            let name = record.displayName.lowercased()
            return name.contains("twitch") || name.contains("ttvnw") || name.contains("jtv")
        }

        dataStore.fetchDataRecords(ofTypes: types) { [weak self] records in
            let toDelete = records.filter(matchesTwitch)
            dataStore.removeData(ofTypes: types, for: toDelete) {
                DispatchQueue.main.async {
                    self?.profileName = nil
                    self?.profileLogin = nil
                    self?.profileAvatarURL = nil
                    self?.isLoggedIn = false
                    self?.wasLoggedIn = false
                    self?.followedLive = []
                    self?.followedChannelLogins = []
                    self?.persistFollowedChannelLogins([])
                    self?.webView.load(URLRequest(url: URL(string: "https://www.twitch.tv")!))
                    self?.backgroundWebView?.load(URLRequest(url: URL(string: "https://www.twitch.tv/following")!))
                }
            }
        }
    }

    private func restoreExternalAuthStateFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: Self.externalAuthStorageKey),
              let state = try? JSONDecoder().decode(StoredExternalAuthState.self, from: data),
              !state.accessToken.isEmpty else {
            return
        }

        if let expiresAt = state.expiresAt, expiresAt <= Date() {
            clearExternalAuthState()
            return
        }

        externalAuthState = state
        if let login = Self.normalizedNonEmpty(state.login) {
            profileLogin = login
        }
        if let displayName = Self.normalizedNonEmpty(state.displayName) {
            profileName = displayName
        } else if let login = Self.normalizedNonEmpty(state.login), profileName == nil {
            profileName = login
        }
        if let avatarString = Self.normalizedNonEmpty(state.avatarURLString),
           let avatarURL = URL(string: avatarString) {
            profileAvatarURL = avatarURL
        }
        isLoggedIn = true
        wasLoggedIn = true
    }

    private func persistExternalAuthState(_ state: StoredExternalAuthState) {
        externalAuthState = state
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.externalAuthStorageKey)
    }

    private func clearExternalAuthState() {
        externalAuthState = nil
        UserDefaults.standard.removeObject(forKey: Self.externalAuthStorageKey)
    }

    private func currentExternalAuthToken() -> String? {
        guard let state = externalAuthState else { return nil }
        if let expiresAt = state.expiresAt, expiresAt <= Date() {
            clearExternalAuthState()
            return nil
        }
        let token = state.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func runExternalBrowserAuthFlow() async {
        await MainActor.run {
            self.externalAuthInProgress = true
            self.externalAuthNotice = nil
        }

        do {
            let clientID = currentOAuthClientID()
            let tokenResponse: OAuthTokenResponse
            if shouldUseLoopbackCallbackFlow(clientID: clientID) {
                tokenResponse = try await runLoopbackCallbackAuth(clientID: clientID)
            } else {
                tokenResponse = try await runDeviceCodeAuth(clientID: clientID)
            }
            let validateResponse = try? await validateOAuthToken(tokenResponse.access_token)
            let normalizedLogin = Self.normalizedNonEmpty(validateResponse?.login)
            let profile = await fetchHelixProfile(login: normalizedLogin, authToken: tokenResponse.access_token)
            let expiresIn = tokenResponse.expires_in ?? validateResponse?.expires_in
            let expiresAt = expiresIn.map { Date().addingTimeInterval(TimeInterval(max(0, $0 - 60))) }
            let displayName = Self.normalizedNonEmpty(profile?.display_name)
                ?? normalizedLogin
                ?? "Twitch user"
            let avatarURL = profile?.profile_image_url

            let storedState = StoredExternalAuthState(
                accessToken: tokenResponse.access_token,
                refreshToken: tokenResponse.refresh_token,
                expiresAt: expiresAt,
                login: normalizedLogin,
                displayName: displayName,
                avatarURLString: avatarURL
            )

            await MainActor.run {
                self.persistExternalAuthState(storedState)
                self.profileLogin = normalizedLogin
                self.profileName = displayName
                if let avatarURL, let url = URL(string: avatarURL) {
                    self.profileAvatarURL = url
                }
                self.isLoggedIn = true
                self.wasLoggedIn = true
                self.externalAuthNotice = ExternalAuthNotice(
                    message: "Logged in using the system browser.",
                    isError: false,
                    nonce: UUID()
                )
                self.externalAuthInProgress = false
                NSApp.activate(ignoringOtherApps: true)
            }

            _ = await refreshFollowedLiveUsingAPI()
            await MainActor.run {
                self.loadFollowedLiveInBackground()
            }
        } catch is CancellationError {
            await MainActor.run {
                self.externalAuthInProgress = false
            }
        } catch let oauthError as ExternalOAuthError {
            await MainActor.run {
                self.externalAuthInProgress = false
                self.externalAuthNotice = ExternalAuthNotice(
                    message: oauthError.errorDescription ?? "External login failed.",
                    isError: true,
                    nonce: UUID()
                )
            }
        } catch {
            await MainActor.run {
                self.externalAuthInProgress = false
                self.externalAuthNotice = ExternalAuthNotice(
                    message: "External login failed: \(error.localizedDescription)",
                    isError: true,
                    nonce: UUID()
                )
            }
        }
    }

    private func shouldUseLoopbackCallbackFlow(clientID: String) -> Bool {
        // Twitch's default web client ID does not accept arbitrary localhost redirects.
        // Keep callback flow for custom client IDs only.
        return clientID != Self.twitchWebClientID
    }

    private func runLoopbackCallbackAuth(clientID: String) async throws -> OAuthTokenResponse {
        let state = Self.randomURLSafeToken(byteCount: 24)
        let codeVerifier = Self.randomURLSafeToken(byteCount: 64)
        let codeChallenge = Self.pkceCodeChallenge(for: codeVerifier)
        let callbackListener = try OAuthCallbackListener(
            expectedState: state,
            callbackPath: Self.externalAuthCallbackPath
        )
        defer { callbackListener.cancel() }

        let redirectURI = "http://127.0.0.1:\(callbackListener.port)\(Self.externalAuthCallbackPath)"
        guard let authorizeURL = Self.makeOAuthAuthorizeURL(
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: codeChallenge
        ) else {
            throw ExternalOAuthError.tokenExchangeFailed("Invalid external login URL.")
        }

        let opened = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
        guard opened else {
            throw ExternalOAuthError.browserOpenFailed
        }

        await MainActor.run {
            self.externalAuthNotice = ExternalAuthNotice(
                message: "Browser opened. Finish Twitch login; Glitcho is waiting for redirect.",
                isError: false,
                nonce: UUID()
            )
        }

        let authorizationCode = try callbackListener.waitForCode(timeout: 240)
        return try await exchangeOAuthCodeForToken(
            code: authorizationCode,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier,
            clientID: clientID
        )
    }

    private func runDeviceCodeAuth(clientID: String) async throws -> OAuthTokenResponse {
        let deviceCode = try await startDeviceCodeFlow(clientID: clientID)
        guard let verificationURL = Self.makeDeviceVerificationURL(from: deviceCode) else {
            throw ExternalOAuthError.tokenExchangeFailed("Invalid external login URL.")
        }

        let opened = await MainActor.run { NSWorkspace.shared.open(verificationURL) }
        guard opened else {
            throw ExternalOAuthError.browserOpenFailed
        }

        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(deviceCode.user_code, forType: .string)
            self.externalAuthNotice = ExternalAuthNotice(
                message: "Browser opened for Twitch activation (code copied): \(deviceCode.user_code)",
                isError: false,
                nonce: UUID()
            )
        }

        return try await pollDeviceCodeForToken(
            clientID: clientID,
            deviceCode: deviceCode.device_code,
            initialInterval: deviceCode.interval ?? 5,
            expiresIn: deviceCode.expires_in
        )
    }

    private func startDeviceCodeFlow(clientID: String) async throws -> OAuthDeviceCodeResponse {
        guard let url = URL(string: "https://id.twitch.tv/oauth2/device") else {
            throw ExternalOAuthError.tokenExchangeFailed("Invalid device auth endpoint URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody([
            "client_id": clientID,
            "scopes": Self.externalAuthScopes
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExternalOAuthError.tokenExchangeFailed("No HTTP response from device auth endpoint.")
        }

        if (200...299).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(OAuthDeviceCodeResponse.self, from: data) {
            return decoded
        }

        if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
           let message = oauthError.message ?? oauthError.error {
            throw ExternalOAuthError.tokenExchangeFailed(message)
        }

        throw ExternalOAuthError.tokenExchangeFailed("HTTP \(http.statusCode)")
    }

    private func pollDeviceCodeForToken(
        clientID: String,
        deviceCode: String,
        initialInterval: Int,
        expiresIn: Int
    ) async throws -> OAuthTokenResponse {
        guard let url = URL(string: "https://id.twitch.tv/oauth2/token") else {
            throw ExternalOAuthError.tokenExchangeFailed("Invalid token endpoint URL.")
        }

        let deadline = Date().addingTimeInterval(TimeInterval(max(60, expiresIn)))
        var pollInterval = max(2, initialInterval)

        while Date() < deadline {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formURLEncodedBody([
                "client_id": clientID,
                "scopes": Self.externalAuthScopes,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ExternalOAuthError.tokenExchangeFailed("No HTTP response from token endpoint.")
            }

            if (200...299).contains(http.statusCode),
               let decoded = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data),
               !decoded.access_token.isEmpty {
                return decoded
            }

            if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
                let message = (oauthError.message ?? oauthError.error ?? "").lowercased()
                if message.contains("authorization_pending") {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)
                    continue
                }
                if message.contains("slow_down") {
                    pollInterval += 2
                    try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)
                    continue
                }
                if message.contains("access_denied") {
                    throw ExternalOAuthError.tokenExchangeFailed("Authorization was denied in browser.")
                }
                if message.contains("expired_token") {
                    throw ExternalOAuthError.tokenExchangeFailed("Device login expired. Start login again.")
                }
                throw ExternalOAuthError.tokenExchangeFailed(oauthError.message ?? oauthError.error ?? "HTTP \(http.statusCode)")
            }

            throw ExternalOAuthError.tokenExchangeFailed("HTTP \(http.statusCode)")
        }

        throw ExternalOAuthError.callbackTimeout
    }

    private func currentOAuthClientID() -> String {
        let override = UserDefaults.standard
            .string(forKey: Self.externalAuthClientIDOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return override
        }
        return Self.twitchWebClientID
    }

    private func exchangeOAuthCodeForToken(
        code: String,
        redirectURI: String,
        codeVerifier: String,
        clientID: String
    ) async throws -> OAuthTokenResponse {
        guard let url = URL(string: "https://id.twitch.tv/oauth2/token") else {
            throw ExternalOAuthError.tokenExchangeFailed("Invalid token endpoint URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody([
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExternalOAuthError.tokenExchangeFailed("No HTTP response from token endpoint.")
        }

        if (200...299).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data),
           !decoded.access_token.isEmpty {
            return decoded
        }

        if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
           let message = oauthError.message ?? oauthError.error {
            throw ExternalOAuthError.tokenExchangeFailed(message)
        }

        throw ExternalOAuthError.tokenExchangeFailed("HTTP \(http.statusCode)")
    }

    private func validateOAuthToken(_ accessToken: String) async throws -> OAuthValidateResponse {
        guard let url = URL(string: "https://id.twitch.tv/oauth2/validate") else {
            throw ExternalOAuthError.validateFailed("Invalid validation endpoint URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExternalOAuthError.validateFailed("No HTTP response from validation endpoint.")
        }

        if (200...299).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(OAuthValidateResponse.self, from: data) {
            return decoded
        }

        if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
           let message = oauthError.message ?? oauthError.error {
            throw ExternalOAuthError.validateFailed(message)
        }

        throw ExternalOAuthError.validateFailed("HTTP \(http.statusCode)")
    }

    private func fetchHelixProfile(login: String?, authToken: String) async -> HelixProfileUser? {
        guard let login = Self.normalizedNonEmpty(login) else { return nil }
        var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
        components.queryItems = [URLQueryItem(name: "login", value: login)]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(currentOAuthClientID(), forHTTPHeaderField: "Client-Id")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(HelixProfileUsersResponse.self, from: data) else {
            return nil
        }
        return decoded.data.first
    }

    private static func makeOAuthAuthorizeURL(
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL? {
        var components = URLComponents(string: "https://id.twitch.tv/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.externalAuthScopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "force_verify", value: "true")
        ]
        return components?.url
    }

    private static func makeDeviceVerificationURL(from response: OAuthDeviceCodeResponse) -> URL? {
        if let complete = normalizedNonEmpty(response.verification_uri_complete),
           let url = URL(string: complete) {
            return url
        }

        guard var components = URLComponents(string: response.verification_uri) else {
            return nil
        }

        // Some responses provide only twitch.tv or /activate without the code.
        if components.path.isEmpty || components.path == "/" {
            components.path = "/activate"
        }

        var queryItems = components.queryItems ?? []
        let hasDeviceCode = queryItems.contains {
            let name = $0.name.lowercased()
            return name == "device-code" || name == "device_code" || name == "user_code"
        }
        if !hasDeviceCode {
            queryItems.append(URLQueryItem(name: "device-code", value: response.user_code))
        }
        let hasPublicFlag = queryItems.contains { $0.name.lowercased() == "public" }
        if !hasPublicFlag {
            queryItems.append(URLQueryItem(name: "public", value: "true"))
        }
        components.queryItems = queryItems

        return components.url
    }

    private static func randomURLSafeToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: max(16, byteCount))
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result == errSecSuccess {
            return base64URLEncode(Data(bytes))
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func pkceCodeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formURLEncodedBody(_ fields: [String: String]) -> Data? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = fields.compactMap { key, value -> String? in
            guard let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return nil
            }
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
        return encoded.data(using: .utf8)
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalizedTwitchURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host.hasSuffix("twitch.tv") else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let parts = components.path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[1].lowercased() == "home" {
            components.path = "/" + parts[0]
        }
        return components.url ?? url
    }

    private func shouldOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            let host = url.host?.lowercased() ?? ""
            return !host.hasSuffix("twitch.tv")
        case "mailto", "tel":
            return true
        default:
            return false
        }
    }

    private func nativePlaybackRequestIfNeeded(url: URL) -> NativePlaybackRequest? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "clips.twitch.tv" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard let slug = parts.first, !slug.isEmpty else { return nil }
            return NativePlaybackRequest(kind: .clip, streamlinkTarget: url.absoluteString, channelName: nil)
        }

        guard host.hasSuffix("twitch.tv") else { return nil }

        let normalized = normalizedTwitchURL(url)
        let parts = normalized.path.split(separator: "/").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }

        // VOD: /videos/<id>
        if first.lowercased() == "videos", parts.count >= 2 {
            let id = parts[1]
            if id.allSatisfy({ $0.isNumber }) {
                return NativePlaybackRequest(kind: .vod, streamlinkTarget: normalized.absoluteString, channelName: nil)
            }
        }

        // Clip: /clip/<slug> or /<channel>/clip/<slug>
        if first.lowercased() == "clip", parts.count >= 2 {
            return NativePlaybackRequest(kind: .clip, streamlinkTarget: normalized.absoluteString, channelName: nil)
        }
        if parts.count >= 3, parts[1].lowercased() == "clip" {
            return NativePlaybackRequest(kind: .clip, streamlinkTarget: normalized.absoluteString, channelName: nil)
        }

        // Live channel root: /<channel>
        let reserved: Set<String> = [
            "directory", "downloads", "login", "logout", "search", "settings", "signup", "p",
            "following", "browse", "drops", "subs", "inventory"
        ]
        let channelSubpages: Set<String> = ["home", "about", "schedule", "videos", "clips", "streams"]
        let channel = first.lowercased()
        guard !reserved.contains(channel) else { return nil }

        if parts.count >= 2 {
            let second = parts[1].lowercased()
            guard channelSubpages.contains(second) else { return nil }
        }

        return NativePlaybackRequest(kind: .liveChannel, streamlinkTarget: "twitch.tv/\(first)", channelName: first)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "followedLive":
            guard let items = message.body as? [[String: String]] else { return }

            let parsedChannels = items.compactMap { item -> TwitchChannel? in
                guard let urlString = item["url"], let url = URL(string: urlString) else { return nil }
                let normalizedURL = normalizedTwitchURL(url)
                let name = item["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = (name?.isEmpty == false) ? name! : normalizedURL.lastPathComponent
                let thumb = item["thumbnail"].flatMap { URL(string: $0) }
                let login = normalizedURL.lastPathComponent.lowercased()
                return TwitchChannel(id: login, name: displayName, url: normalizedURL, thumbnailURL: thumb)
            }

            let channels = parsedChannels
                .deduplicatedByLogin()
                .sorted { lhs, rhs in
                    lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
                }

            let isFromBackground = (userContentController === backgroundMessageController)
            // The main webview often posts empty snapshots while navigating non-following pages.
            // Ignore those so they do not erase the authoritative background/API live list.
            if channels.isEmpty && !isFromBackground {
                return
            }
            // Background DOM scraping can transiently return an empty list while Twitch rewrites the page.
            // Keep current state in that case and ask API refresh for an authoritative value.
            if channels.isEmpty && isFromBackground && !followedLive.isEmpty {
                Task { _ = await self.refreshFollowedLiveUsingAPI() }
                return
            }

            DispatchQueue.main.async {
                self.lastFollowedLiveUpdateAt = Date()
                if self.followedLive != channels {
                    self.followedLive = channels
                }
            }
        case "profile":
            guard let dict = message.body as? [String: String] else { return }
            let name = (dict["displayName"] ?? dict["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let login = dict["login"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let avatarString = dict["avatar"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let avatar = (avatarString?.isEmpty == false) ? URL(string: avatarString!) : nil
            let loggedIn = dict["loggedIn"] == "true"
            let isFromBackground = (userContentController === backgroundMessageController)
            DispatchQueue.main.async {
                // Prevent background-webview profile polling from forcing transient logged-out states.
                if isFromBackground && !loggedIn && self.isLoggedIn {
                    return
                }
                let hasExternalAuth = (self.externalAuthState != nil)
                if !loggedIn && hasExternalAuth {
                    if self.isLoggedIn != true {
                        self.isLoggedIn = true
                    }
                    self.wasLoggedIn = true
                    return
                }
                if loggedIn {
                    if !self.wasLoggedIn {
                        self.profileName = nil
                        self.profileLogin = nil
                        self.profileAvatarURL = nil
                    }
                    if let name, !name.isEmpty, self.profileName != name {
                        self.profileName = name
                    }
                    if let login, !login.isEmpty, self.profileLogin != login {
                        self.profileLogin = login
                    }
                    if let avatar, self.profileAvatarURL != avatar {
                        self.profileAvatarURL = avatar
                    }
                } else {
                    if self.profileName != nil { self.profileName = nil }
                    if self.profileLogin != nil { self.profileLogin = nil }
                    if self.profileAvatarURL != nil { self.profileAvatarURL = nil }
                    if !self.followedChannelLogins.isEmpty {
                        self.followedChannelLogins = []
                        self.persistFollowedChannelLogins([])
                    }
                    self.lastFollowedChannelsSyncAt = .distantPast
                }
                let effectiveLoggedIn = loggedIn || hasExternalAuth
                if self.isLoggedIn != effectiveLoggedIn {
                    self.isLoggedIn = effectiveLoggedIn
                }
                if effectiveLoggedIn && !self.wasLoggedIn {
                    self.loadFollowedLiveInBackground()
                }
                self.wasLoggedIn = effectiveLoggedIn
            }
        case "channelNotification":
            guard let dict = message.body as? [String: Any] else { return }
            guard let loginValue = dict["login"] as? String else { return }
            let enabled: Bool
            if let boolVal = dict["enabled"] as? Bool {
                enabled = boolVal
            } else if let strVal = dict["enabled"] as? String {
                enabled = strVal.lowercased() == "true"
            } else {
                enabled = true
            }
            let login = loginValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !login.isEmpty else { return }
            DispatchQueue.main.async {
                self.channelNotificationToggle = ChannelNotificationToggle(login: login, enabled: enabled)
            }
        case "channelPin":
            guard let dict = message.body as? [String: Any] else { return }
            guard let loginValue = dict["login"] as? String else { return }
            let login = loginValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !login.isEmpty else { return }
            let displayValue = (dict["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (displayValue?.isEmpty == false) ? displayValue! : login
            DispatchQueue.main.async {
                self.channelPinRequest = ChannelPinRequest(
                    login: login,
                    displayName: displayName,
                    nonce: UUID()
                )
            }
        case "sideNavFollowedLogins":
            // Sidebar channel logins (live + recently-offline) scraped from the DOM.
            // Used as a supplementary source when the Helix/GQL API is unavailable.
            guard let raw = message.body as? [String] else { return }
            let normalized = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            guard !normalized.isEmpty, isLoggedIn else { return }
            DispatchQueue.main.async {
                var updated = Set(self.followedChannelLogins)
                let added = normalized.filter { updated.insert($0).inserted }
                guard !added.isEmpty else { return }
                let merged = updated.sorted()
                self.followedChannelLogins = merged
                self.persistFollowedChannelLogins(merged)
            }
        case "consoleLog":
            break
        case "vodThumbnailRequest":
            guard let dict = message.body as? [String: String],
                  let vodId = dict["vodId"],
                  let imgId = dict["imgId"] else { return }
            Task {
                await self.handleVODThumbnailRequest(vodId: vodId, imgId: imgId)
            }
        default:
            return
        }
    }

    private func loadCachedFollowedChannelLogins() -> [String] {
        guard let stored = UserDefaults.standard.array(forKey: Self.followedChannelsCacheKey) as? [String] else {
            return []
        }

        var seen = Set<String>()
        return stored
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private func persistFollowedChannelLogins(_ logins: [String]) {
        UserDefaults.standard.set(logins, forKey: Self.followedChannelsCacheKey)
    }

    private func loadCachedAvatarURLs() -> [String: URL] {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.avatarCacheKey) as? [String: String] else { return [:] }
        var result: [String: URL] = [:]
        for (login, urlString) in dict {
            if let url = URL(string: urlString) { result[login] = url }
        }
        return result
    }

    private func persistAvatarURLs(_ urls: [String: URL]) {
        let dict = urls.mapValues { $0.absoluteString }
        UserDefaults.standard.set(dict, forKey: Self.avatarCacheKey)
    }

    func refreshOfflineAvatars(logins: [String]) async {
        guard !logins.isEmpty else { return }
        guard let authToken = await twitchAuthToken() else { return }

        // Only fetch for logins we don't already have
        let missing = logins.filter { offlineChannelAvatarURLs[$0] == nil }
        guard !missing.isEmpty else { return }

        // Helix allows up to 100 logins per request
        let batches = stride(from: 0, to: missing.count, by: 100).map {
            Array(missing[$0..<min($0 + 100, missing.count)])
        }

        var fetched: [String: URL] = [:]
        for batch in batches {
            var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
            components.queryItems = batch.map { URLQueryItem(name: "login", value: $0) }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue(currentOAuthClientID(), forHTTPHeaderField: "Client-Id")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else { continue }

            for user in dataArr {
                guard let login = (user["login"] as? String)?.lowercased(),
                      let avatarString = user["profile_image_url"] as? String,
                      let avatarURL = URL(string: avatarString) else { continue }
                fetched[login] = avatarURL
            }
        }

        guard !fetched.isEmpty else { return }
        await MainActor.run {
            self.offlineChannelAvatarURLs.merge(fetched) { _, new in new }
            self.persistAvatarURLs(self.offlineChannelAvatarURLs)
        }
    }

    func setChannelNotificationState(login: String, enabled: Bool) {
        let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        let js = "window.__glitcho_setBellState && window.__glitcho_setBellState('\(normalized)', \(enabled ? "true" : "false"));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - VOD Thumbnail Fetching (Swift-side TwitchNoSub)

    private func handleVODThumbnailRequest(vodId: String, imgId: String) async {
        guard let thumbnailURL = await fetchVODThumbnailURL(vodId: vodId) else { return }

        // Inject the thumbnail into the page
        let js = """
        (function() {
            const img = document.querySelector('[data-tns-id="\(imgId)"]');
            if (img) {
                img.src = '\(thumbnailURL)';
                img.srcset = '';
            }
        })();
        """

        await MainActor.run {
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func fetchVODThumbnailURL(vodId: String) async -> String? {
        let query = #"query { video(id: "\#(vodId)") { seekPreviewsURL } }"#

        guard let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["query": query]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = jsonData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let video = dataObj["video"] as? [String: Any],
                  let seekPreviewsURL = video["seekPreviewsURL"] as? String else {
                return nil
            }

            // Convert storyboard URL to thumbnail URL
            // .../storyboards/xxx-strip-0.jpg -> .../thumb/thumb0-320x180.jpg
            let thumbnailURL = seekPreviewsURL
                .replacingOccurrences(of: #"\/storyboards\/.*$"#, with: "/thumb/thumb0-320x180.jpg", options: .regularExpression)

            // Test both thumbnail sizes in parallel
            let thumbnailURL640 = seekPreviewsURL
                .replacingOccurrences(of: #"\/storyboards\/.*$"#, with: "/thumb/thumb0-640x360.jpg", options: .regularExpression)

            async let check320: Bool = {
                guard let testURL = URL(string: thumbnailURL) else { return false }
                var req = URLRequest(url: testURL)
                req.httpMethod = "HEAD"
                guard let (_, resp) = try? await URLSession.shared.data(for: req),
                      let http = resp as? HTTPURLResponse else { return false }
                return http.statusCode == 200
            }()

            async let check640: Bool = {
                guard let testURL = URL(string: thumbnailURL640) else { return false }
                var req = URLRequest(url: testURL)
                req.httpMethod = "HEAD"
                guard let (_, resp) = try? await URLSession.shared.data(for: req),
                      let http = resp as? HTTPURLResponse else { return false }
                return http.statusCode == 200
            }()

            let (ok320, ok640) = await (check320, check640)
            if ok320 { return thumbnailURL }
            if ok640 { return thumbnailURL640 }
            return seekPreviewsURL

        } catch {
            return nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        guard let currentURL = webView.url, !Self.isAuthRoute(url: currentURL) else { return }
        webView.evaluateJavaScript(Self.hideChromeScriptSource, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if shouldOpenExternally(url) {
            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }

        let normalized = normalizedTwitchURL(url)
        if webView === self.webView {
            configureMainWebViewProfile(for: normalized)
            if Self.isAuthRoute(url: normalized) {
                if !hasPurgedTwitchDataForAuth {
                    decisionHandler(.cancel)
                    purgeTwitchDataForAuthIfNeeded { [weak self] in
                        self?.webView.load(URLRequest(url: normalized))
                    }
                    return
                }
                decisionHandler(.allow)
                return
            }
        }
        if normalized != url {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: normalized))
            return
        }
        
        if webView === self.webView, let request = nativePlaybackRequestIfNeeded(url: url) {
            prepareWebViewForNativePlayer()
            DispatchQueue.main.async {
                self.shouldSwitchToNativePlayback = request
            }
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if shouldOpenExternally(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func purgeTwitchDataForAuthIfNeeded(completion: @escaping () -> Void) {
        guard !hasPurgedTwitchDataForAuth else {
            completion()
            return
        }
        hasPurgedTwitchDataForAuth = true

        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            let toDelete = records.filter(Self.matchesTwitchDataRecord)
            dataStore.removeData(ofTypes: types, for: toDelete) {
                completion()
            }
        }
    }

    private static func installDefaultMainUserScripts(on controller: WKUserContentController) {
        controller.addUserScript(Self.initialHideScript)
        controller.addUserScript(Self.adBlockScript)
        controller.addUserScript(Self.codecWorkaroundScript)
        controller.addUserScript(Self.twitchNoSubScript)
        controller.addUserScript(Self.hideChromeScript)
        controller.addUserScript(Self.channelActionsScript)
        controller.addUserScript(Self.channelPinContextMenuScript)
        controller.addUserScript(Self.ensureLiveStreamScript)
        controller.addUserScript(Self.followedLiveScript)
        controller.addUserScript(Self.profileScript)
        controller.addUserScript(Self.autoPlayScript)
    }

    private static func isAuthRoute(url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host.hasSuffix("twitch.tv") else { return false }
        let path = url.path.lowercased()
        return path.hasPrefix("/signup")
            || path.hasPrefix("/password")
            || path.hasPrefix("/reset")
            || path.hasPrefix("/activate")
    }

    private static func matchesTwitchDataRecord(_ record: WKWebsiteDataRecord) -> Bool {
        let name = record.displayName.lowercased()
        return name.contains("twitch") || name.contains("ttvnw") || name.contains("jtv")
    }

    private func configureMainWebViewProfile(for url: URL) {
        guard let host = url.host?.lowercased(), host.hasSuffix("twitch.tv") else { return }
        guard let controller = mainMessageController else { return }

        let shouldUseAuthProfile = Self.isAuthRoute(url: url)
        guard shouldUseAuthProfile != mainWebViewUsesAuthProfile else { return }

        controller.removeAllUserScripts()
        if shouldUseAuthProfile {
            // Keep auth pages as clean as possible; only set a mainstream UA.
            webView.customUserAgent = Self.chromeAuthUserAgent
        } else {
            Self.installDefaultMainUserScripts(on: controller)
            webView.customUserAgent = Self.safariUserAgent
            hasPurgedTwitchDataForAuth = false
        }
        mainWebViewUsesAuthProfile = shouldUseAuthProfile
    }

    private func makeBackgroundWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        backgroundMessageController = contentController
        config.processPool = Self.sharedProcessPool
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]

        contentController.add(self, name: "followedLive")
        contentController.add(self, name: "sideNavFollowedLogins")
        contentController.add(self, name: "profile")
        contentController.addUserScript(Self.followedLiveScript)
        contentController.addUserScript(Self.profileScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if webPlaybackSuppressed {
            stopWebPlayback(in: webView)
        }
        return webView
    }

    private func ensureFollowActionWebView() -> WKWebView {
        if let followActionWebView { return followActionWebView }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = followActionDelegate
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        if webPlaybackSuppressed {
            stopWebPlayback(in: webView)
        }

        followActionWebView = webView
        return webView
    }

    private func runFollowScript(in webView: WKWebView) {
        webView.evaluateJavaScript(Self.followActionScript, completionHandler: nil)
    }

    private func scheduleFollowActionTeardown() {
        followActionTeardownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.followActionWebView = nil
        }
        followActionTeardownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private final class FollowActionDelegate: NSObject, WKNavigationDelegate {
        var onDidFinish: ((WKWebView) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onDidFinish?(webView)
        }
    }

    private func loadFollowedLiveInBackground() {
        guard let backgroundWebView else { return }
        followedWarmupAttempts = 0
        lastFollowedLiveUpdateAt = Date()
        let url = URL(string: "https://www.twitch.tv/following")!
        backgroundWebView.load(URLRequest(url: url))
        Task {
            _ = await refreshFollowedLiveUsingAPI()
        }

        followedRefreshTimer?.invalidate()
        followedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                let didRefreshViaAPI = await self.refreshFollowedLiveUsingAPI()
                if !didRefreshViaAPI {
                    _ = await MainActor.run {
                        self.backgroundWebView?.reload()
                    }
                }
            }
        }

        scheduleFollowedWarmupReload()
    }

    private func scheduleFollowedWarmupReload() {
        guard isLoggedIn else { return }
        guard followedWarmupAttempts < 3 else { return }
        followedWarmupAttempts += 1
        let delay = followedWarmupAttempts == 1 ? 2.0 : (followedWarmupAttempts == 2 ? 6.0 : 12.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.isLoggedIn else { return }
            if self.followedLive.isEmpty {
                self.backgroundWebView?.reload()
                self.scheduleFollowedWarmupReload()
            }
        }
    }

    // Script injected at document start to hide page until customization is done
    private static let initialHideScript = WKUserScript(
        source: """
        (function() {
          if (document.getElementById('glitcho-initial-hide')) { return; }
          const style = document.createElement('style');
          style.id = 'glitcho-initial-hide';
          style.textContent = `
            html { background: #0d0d0f !important; }
            body { opacity: 0 !important; transition: opacity 0.15s ease-out !important; }
            body.glitcho-ready { opacity: 1 !important; }
          `;
          document.documentElement.appendChild(style);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static let hideChromeScriptSource = """
        (function() {
          document.documentElement.setAttribute('data-twitchglass', '1');
          
          // Détection du type de page
          function isChannelPage() {
            const path = window.location.pathname;
            // Page de chaîne si le path est /username (pas /directory, /videos, etc.)
            return path.split('/').filter(Boolean).length === 1 && 
                   !path.includes('/directory') && 
                   !path.includes('/videos') &&
                   !path.includes('/settings') &&
                   !path.includes('/search') &&
                   path !== '/';
          }
          
          const css = `
            :root {
              --side-nav-width: 0px !important;
              --side-nav-width-collapsed: 0px !important;
              --side-nav-width-expanded: 0px !important;
              --left-nav-width: 0px !important;
              --top-nav-height: 0px !important;
              --tw-glass-bg: rgba(20, 20, 24, 0.55);
              --tw-glass-border: rgba(255, 255, 255, 0.08);
              --tw-glass-highlight: rgba(255, 255, 255, 0.18);
              --color-background-base: transparent !important;
              --color-background-body: transparent !important;
              --color-background-alt: transparent !important;
              --color-background-float: rgba(18, 18, 22, 0.45) !important;
            }
            html, body {
              background: transparent !important;
              background-color: transparent !important;
            }
            /* Masquer la barre de navigation Twitch */
            header,
            .top-nav,
            .top-nav__menu,
            [data-a-target="top-nav-container"],
            [data-test-selector="top-nav-container"],
            [data-test-selector="top-nav"],
            [data-a-target="top-nav"],
            [data-a-target="top-nav-search-input"],
            [data-a-target="top-nav-search-input-group"] {
              display: none !important;
              height: 0 !important;
              min-height: 0 !important;
              opacity: 0 !important;
              pointer-events: none !important;
            }
            /* Masquer la sidebar gauche de Twitch */
            [data-test-selector="left-nav"],
            #sideNav,
            [data-a-target="left-nav"],
            [data-a-target="side-nav-bar"],
            [data-a-target="side-nav"],
            [data-a-target="side-nav__content"],
            [data-a-target="side-nav-container"],
            [data-a-target="side-nav-bar__content"],
            [data-a-target="side-nav-bar__content__inner"],
            [data-test-selector="side-nav"],
            nav[aria-label="Primary Navigation"] {
              display: none !important;
              width: 0 !important;
              min-width: 0 !important;
              max-width: 0 !important;
              opacity: 0 !important;
              pointer-events: none !important;
            }
            /* Ajuster le contenu principal */
            main, .root-scrollable, [data-a-target="content"], [data-test-selector="main-page-scrollable-area"] {
              margin-left: 0 !important;
              padding-left: 0 !important;
              margin-top: 0 !important;
              padding-top: 0 !important;
            }
            body, #root {
              background: transparent !important;
            }
            .tw-root,
            .tw-root--theme-dark,
            .tw-root--theme-light,
            .twilight-minimal-root {
              background: transparent !important;
              background-color: transparent !important;
            }
            /* Sur les pages de chaîne, garder le chat et les infos visibles */
            body.channel-page [data-a-target="video-chat"],
            body.channel-page [data-a-target="right-column"],
            body.channel-page [data-a-target="channel-info-content"],
            body.channel-page [data-a-target="stream-info-card"],
            body.channel-page [data-a-target="chat-shell"],
            body.channel-page aside,
            body.channel-page [role="complementary"] {
              display: block !important;
              opacity: 1 !important;
              visibility: visible !important;
            }
            [data-a-target="preview-card"],
            [data-a-target="preview-card-thumbnail-link"],
            [data-a-target="preview-card-image-link"] {
              border-radius: 14px !important;
              overflow: hidden !important;
            }
            [data-a-target="preview-card"] {
              background: var(--tw-glass-bg) !important;
              border: 1px solid var(--tw-glass-border) !important;
              box-shadow: none !important;
            }
            [data-a-target="preview-card"] img {
              border-radius: 12px !important;
            }
            [data-a-target="player"] video,
            video {
              border-radius: 16px !important;
              overflow: hidden !important;
            }
            [data-a-target="follow-button"],
            [data-a-target="subscribe-button"] {
              border-radius: 999px !important;
              border: 1px solid var(--tw-glass-highlight) !important;
              background: rgba(25, 25, 30, 0.45) !important;
              box-shadow: none !important;
            }
          `;
          
          if (!document.getElementById('twitchglass-style')) {
            const style = document.createElement('style');
            style.id = 'twitchglass-style';
            style.appendChild(document.createTextNode(css));
            document.documentElement.appendChild(style);
          }
          
          // Ajouter une classe au body pour identifier les pages de chaîne
          function updatePageType() {
            if (isChannelPage()) {
              document.body.classList.add('channel-page');
            } else {
              document.body.classList.remove('channel-page');
            }
          }

          function hideNavigation() {
            // Masquer uniquement la navigation Twitch, pas le contenu
            const topNav = document.querySelectorAll(
              'header, .top-nav, [data-a-target="top-nav-container"]'
            );
            topNav.forEach(el => {
              el.style.display = 'none';
              el.style.height = '0';
              el.style.minHeight = '0';
              el.style.opacity = '0';
              el.style.pointerEvents = 'none';
            });
            
            const leftRails = document.querySelectorAll(
              '[data-a-target*="side-nav"], [data-a-target="left-nav"], [data-test-selector="left-nav"], nav[aria-label="Primary Navigation"]'
            );
            leftRails.forEach(el => {
              el.style.display = 'none';
              el.style.width = '0';
              el.style.minWidth = '0';
              el.style.maxWidth = '0';
              el.style.opacity = '0';
              el.style.pointerEvents = 'none';
            });
            
            updatePageType();
          }

          hideNavigation();
          updatePageType();

          // Reveal page after customization
          requestAnimationFrame(() => {
            document.body.classList.add('glitcho-ready');
          });

          // Throttled observer: merge nav hiding + SPA URL detection into one observer
          let _hideQueued = false;
          let _lastUrl = location.href;
          const observer = new MutationObserver(() => {
            const url = location.href;
            if (url !== _lastUrl) {
              _lastUrl = url;
              updatePageType();
              document.body.classList.add('glitcho-ready');
            }
            if (!_hideQueued) {
              _hideQueued = true;
              requestAnimationFrame(() => {
                _hideQueued = false;
                hideNavigation();
              });
            }
          });
          observer.observe(document.documentElement, { childList: true, subtree: true });
        })();
        """

    private static let hideChromeScript = WKUserScript(
        source: hideChromeScriptSource,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private static let channelActionsScript = WKUserScript(
        source: """
        (function() {
          if (window.__glitcho_channel_actions) { return; }
          window.__glitcho_channel_actions = true;

          const reserved = new Set(['directory','downloads','login','logout','search','settings','signup','p','following','browse','drops','subs','inventory','videos','clip']);

          function channelLogin() {
            const parts = (location.pathname || '').split('/').filter(Boolean);
            if (!parts.length) { return null; }
            const login = (parts[0] || '').toLowerCase();
            if (!login || reserved.has(login)) { return null; }
            if (parts.length > 1) {
              const allowed = new Set(['about','schedule','videos','home']);
              const next = (parts[1] || '').toLowerCase();
              if (!allowed.has(next)) { return null; }
            }
            return login;
          }

          function ensureStyle() {
            if (document.getElementById('glitcho-channel-actions-style')) { return; }
            const style = document.createElement('style');
            style.id = 'glitcho-channel-actions-style';
            style.textContent = `
              [data-glitcho-bell-state="off"] svg {
                opacity: 0.35 !important;
                filter: grayscale(1) !important;
              }
              [data-glitcho-bell-state="on"] svg {
                opacity: 1 !important;
                color: #f6c357 !important;
              }
            `;
            (document.head || document.documentElement).appendChild(style);
          }

          function findActionRoot() {
            const explicit = document.querySelector('[data-a-target="channel-actions"], [data-a-target*="channel-actions"]');
            if (explicit) { return explicit; }
            const bell = document.querySelector('[data-a-target="notifications-button"], [data-a-target="notification-button"], button[aria-label*="Notification"], button[aria-label*="Notifications"], button[aria-label*="Notific"]');
            if (bell) { return bell.closest('div') || bell.parentElement; }
            const sub = Array.from(document.querySelectorAll('button,a,[role="button"]')).find(el => {
              const t = (el.getAttribute('aria-label') || el.textContent || '').toLowerCase();
              return t.includes('subscribe') || t.includes('sub') || t.includes("s'abonner") || t.includes('sabonner');
            });
            if (sub) { return sub.closest('div') || sub.parentElement; }
            return document.body;
          }

          function setBellState(button, enabled) {
            button.dataset.glitchoBellState = enabled ? 'on' : 'off';
          }

          function purgeRecordButtons() {
            document.querySelectorAll('[data-glitcho-record="1"]').forEach(el => {
              try { el.remove(); } catch (_) {}
            });
            document.querySelectorAll('[data-glitcho-hidden-follow="1"]').forEach(el => {
              try { el.removeAttribute('data-glitcho-hidden-follow'); } catch (_) {}
            });
          }

          function decorateBellButton() {
            const login = channelLogin();
            if (!login) { return; }
            const root = findActionRoot();
            const button = root.querySelector('[data-a-target="notifications-button"], [data-a-target="notification-button"], button[aria-label*="Notification"], button[aria-label*="Notifications"], button[aria-label*="Notific"]');
            if (!button) { return; }
            if (button.dataset.glitchoBell === '1') { return; }
            button.dataset.glitchoBell = '1';
            button.setAttribute('data-glitcho-bell', '1');
            setBellState(button, true);
            button.addEventListener('click', function(e) {
              e.preventDefault();
              e.stopPropagation();
              const enabled = button.dataset.glitchoBellState !== 'on';
              setBellState(button, enabled);
              try {
                window.webkit.messageHandlers.channelNotification.postMessage({ login: login, enabled: enabled });
              } catch (_) {}
            }, true);
          }

          function decorate() {
            if (!channelLogin()) { return; }
            ensureStyle();
            purgeRecordButtons();
            decorateBellButton();
          }

          window.__glitcho_decorateChannelActions = function() {
            decorate();
          };

          decorate();
          const observer = new MutationObserver(() => { decorate(); });
          observer.observe(document.documentElement, { childList: true, subtree: true });

          window.__glitcho_setBellState = function(login, enabled) {
            const current = channelLogin();
            if (!current || current !== (login || '').toLowerCase()) { return; }
            const button = document.querySelector('[data-glitcho-bell="1"]');
            if (button) { setBellState(button, !!enabled); }
          };
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private static let channelPinContextMenuScript = WKUserScript(
        source: """
        (function() {
          if (window.__glitcho_channel_pin_menu) { return; }
          window.__glitcho_channel_pin_menu = true;

          const reserved = new Set([
            'directory', 'downloads', 'login', 'logout', 'search', 'settings', 'signup', 'p',
            'following', 'browse', 'drops', 'subs', 'inventory', 'videos', 'clip', 'turbo', 'wallet'
          ]);
          let menu = null;

          function removeMenu() {
            if (menu && menu.parentNode) {
              menu.parentNode.removeChild(menu);
            }
            menu = null;
          }

          function parseChannelFromHref(href) {
            if (!href) { return null; }
            try {
              const url = new URL(href, window.location.origin);
              const host = (url.host || '').toLowerCase();
              if (!host.endsWith('twitch.tv') || host === 'clips.twitch.tv') { return null; }

              const parts = (url.pathname || '').split('/').filter(Boolean);
              if (!parts.length) { return null; }
              const login = (parts[0] || '').toLowerCase();
              if (!login || reserved.has(login)) { return null; }

              if (parts.length > 1) {
                const next = (parts[1] || '').toLowerCase();
                if (next !== 'home') { return null; }
              }

              return { login: login, displayName: parts[0] || login };
            } catch (_) {
              return null;
            }
          }

          function channelFromTarget(target) {
            let el = target instanceof Element ? target : null;
            while (el) {
              if (el.tagName === 'A') {
                const channel = parseChannelFromHref(el.getAttribute('href') || el.href);
                if (channel) { return channel; }
              }
              el = el.parentElement;
            }
            return null;
          }

          function showMenu(x, y, channel) {
            removeMenu();
            const wrap = document.createElement('div');
            wrap.style.position = 'fixed';
            wrap.style.zIndex = '2147483647';
            wrap.style.top = y + 'px';
            wrap.style.left = x + 'px';
            wrap.style.minWidth = '210px';
            wrap.style.padding = '6px';
            wrap.style.borderRadius = '8px';
            wrap.style.background = 'rgba(18,18,22,0.96)';
            wrap.style.border = '1px solid rgba(255,255,255,0.14)';
            wrap.style.boxShadow = '0 12px 24px rgba(0,0,0,0.38)';
            wrap.style.backdropFilter = 'blur(10px)';

            const item = document.createElement('button');
            item.type = 'button';
            item.textContent = 'Pin ' + channel.displayName + ' to Sidebar';
            item.style.display = 'block';
            item.style.width = '100%';
            item.style.border = 'none';
            item.style.background = 'transparent';
            item.style.color = '#f3f5ff';
            item.style.font = '500 13px -apple-system, BlinkMacSystemFont, sans-serif';
            item.style.padding = '7px 10px';
            item.style.textAlign = 'left';
            item.style.borderRadius = '6px';
            item.style.cursor = 'pointer';
            item.addEventListener('mouseenter', function() {
              item.style.background = 'rgba(255,255,255,0.12)';
            });
            item.addEventListener('mouseleave', function() {
              item.style.background = 'transparent';
            });
            item.addEventListener('click', function(e) {
              e.preventDefault();
              e.stopPropagation();
              try {
                window.webkit.messageHandlers.channelPin.postMessage({
                  login: channel.login,
                  displayName: channel.displayName
                });
              } catch (_) {}
              removeMenu();
            });

            wrap.appendChild(item);
            document.documentElement.appendChild(wrap);
            menu = wrap;

            const rect = wrap.getBoundingClientRect();
            let left = x;
            let top = y;
            if (rect.right > window.innerWidth - 8) {
              left = Math.max(8, x - rect.width);
            }
            if (rect.bottom > window.innerHeight - 8) {
              top = Math.max(8, y - rect.height);
            }
            wrap.style.left = left + 'px';
            wrap.style.top = top + 'px';
          }

          document.addEventListener('contextmenu', function(e) {
            const channel = channelFromTarget(e.target);
            if (!channel) {
              removeMenu();
              return;
            }
            e.preventDefault();
            e.stopPropagation();
            showMenu(e.clientX, e.clientY, channel);
          }, true);

          document.addEventListener('click', function(e) {
            if (!menu) { return; }
            const target = e.target;
            if (target instanceof Node && menu.contains(target)) {
              return;
            }
            removeMenu();
          }, true);
          document.addEventListener('scroll', removeMenu, true);
          window.addEventListener('blur', removeMenu);
          document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') { removeMenu(); }
          }, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private static let followActionScript = #"""
    (function() {
      if (window.__glitcho_follow_click) {
        try { window.__glitcho_follow_click(); } catch (_) {}
        return;
      }

      function normalize(s) {
        try {
          return (s || '')
            .toLowerCase()
            .normalize('NFD')
            .replace(/[\u0300-\u036f]/g, '')
            .trim();
        } catch (_) {
          return (s || '').toLowerCase().trim();
        }
      }

      // Match both Follow AND Following/Unfollow buttons
      function isFollowOrUnfollowLabel(text) {
        const t = normalize(text);
        if (!t) return false;
        // Match: follow, following, unfollow, suivre, abonne, abonné, ne plus suivre
        return t === 'follow' ||
               t === 'suivre' ||
               t === 'following' ||
               t === 'unfollow' ||
               t === 'abonne' ||
               t === 'abonné' ||
               t.includes('ne plus suivre') ||
               (t.includes('follow') && t.length < 15);
      }

      function findFollowButton() {
        // First try the specific data-a-target
        const direct = document.querySelector('[data-a-target="follow-button"], [data-a-target="unfollow-button"], [data-a-target="follow-button__text"]');
        if (direct) {
          return direct.closest('button,[role="button"],a') || direct;
        }
        const buttons = Array.from(document.querySelectorAll('button,[role="button"],a'));
        for (const el of buttons) {
          const label = el.getAttribute('aria-label') || el.getAttribute('title') || el.textContent || '';
          if (isFollowOrUnfollowLabel(label)) {
            return el;
          }
        }
        return null;
      }

      function clickFollow() {
        const button = findFollowButton();
        if (button && typeof button.click === 'function') {
          button.click();
          return true;
        }
        return false;
      }

      window.__glitcho_follow_click = clickFollow;

      let tries = 0;
      const timer = setInterval(function() {
        tries++;
        if (clickFollow() || tries >= 18) {
          clearInterval(timer);
        }
      }, 450);

      clickFollow();
    })();
    """#

    private static let ensureLiveStreamScript = WKUserScript(
        source: """
        (function() {
          try {
            const host = (location && location.host) ? location.host : '';
            if (!host.endsWith('twitch.tv')) { return; }
          } catch (_) { return; }

          if (window.__twitchglass_ensure_live) { return; }
          window.__twitchglass_ensure_live = true;

          function parts() {
            return (location.pathname || '').split('/').filter(Boolean);
          }

          function isReserved(name) {
            const reserved = new Set(['directory','downloads','login','logout','search','settings','signup','p']);
            return reserved.has((name || '').toLowerCase());
          }

          function redirectIfHome() {
            const p = parts();
            if (p.length === 2 && p[1].toLowerCase() === 'home' && !isReserved(p[0])) {
              location.replace('https://www.twitch.tv/' + p[0]);
              return true;
            }
            return false;
          }

          function isChannelRoot() {
            const p = parts();
            return p.length === 1 && !isReserved(p[0]);
          }

          function clickWatchLive() {
            if (!isChannelRoot()) { return; }
            if (document.querySelector('video')) { return; }

            const direct = document.querySelector('[data-a-target="watch-live-button"], [data-test-selector="watch-live-button"]');
            if (direct && typeof direct.click === 'function') {
              direct.click();
              return;
            }

            const candidates = Array.from(document.querySelectorAll('a,button')).filter(el => {
              if (!el || typeof el.click !== 'function') { return false; }
              if (el.offsetParent === null) { return false; }
              const txt = (el.textContent || '').trim().toLowerCase();
              return txt.includes('watch live') || txt.includes('regarder en direct') || txt.includes('en direct');
            });
            if (candidates.length) {
              candidates[0].click();
            }
          }

          if (redirectIfHome()) { return; }
          setTimeout(redirectIfHome, 250);
          setTimeout(clickWatchLive, 1200);
          setTimeout(clickWatchLive, 3000);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private static let followedLiveScript = WKUserScript(
        source: """
        (function() {
          function extractFromFollowing(map) {
            if (!(location.pathname.includes('/following') || location.pathname.includes('/directory/following'))) {
              return;
            }
            const cards = Array.from(document.querySelectorAll(
              '[data-a-target="preview-card"], [data-test-selector="live-channel-card"], article'
            ));
            cards.forEach(card => {
              const link = card.querySelector('a[data-a-target="preview-card-channel-link"], a[data-a-target="preview-card-title-link"], a[href^="/"]');
              if (!link) { return; }
              let href = link.getAttribute('href');
              if (!href || !href.startsWith('/') || href.startsWith('/directory') || href.startsWith('/videos')) { return; }
              if (/^\\/[^/]+\\/home\\/?$/.test(href)) {
                href = href.replace(/\\/home\\/?$/, '');
              }
              const url = 'https://www.twitch.tv' + href;
              let name = link.getAttribute('title') || link.getAttribute('aria-label') || link.textContent || '';
              // Clean up the name - remove badges, streaming info, etc.
              name = name
                .replace(/\\(Verified\\)/gi, '')
                .replace(/\\(Partner\\)/gi, '')
                .replace(/streaming\\s+.*/i, '')
                .replace(/diffuse\\s+.*/i, '')
                .replace(/en\\s+direct.*/i, '')
                .replace(/live\\s*:.*/i, '')
                .replace(/→/g, '')
                .replace(/›/g, '')
                .replace(/\\s+/g, ' ')
                .trim();
              let thumb = '';
              const img = card.querySelector('img');
              if (img && img.getAttribute('src')) {
                thumb = img.getAttribute('src');
              }
              if (!map.has(url) && name) {
                map.set(url, { name: name, url, thumbnail: thumb });
              }
            });
          }

          function extractFromSideNav(map) {
            // Find the Followed Channels section in the sidebar
            // This section ONLY contains live channels - offline followed channels don't appear here
            const sideNav = document.querySelector('[data-a-target*="side-nav"], [data-test-selector="side-nav"], nav[aria-label="Primary Navigation"]');
            if (!sideNav) { return; }

            // Find the "Followed Channels" or "FOLLOWED CHANNELS" header
            let followedSection = null;
            const allText = sideNav.querySelectorAll('p, span, div, h1, h2, h3, h4, h5, h6');
            for (const el of allText) {
              const text = (el.textContent || '').trim().toLowerCase();
              // Match "followed channels", "chaînes suivies" (French), etc.
              if (text === 'followed channels' || text === 'chaînes suivies' || text === 'followed' || text === 'suivi') {
                // Found the header - get its parent container that contains the channel list
                followedSection = el.closest('[class*="side-nav-section"], [class*="SideNavSection"], div');
                break;
              }
            }

            if (!followedSection) {
              // Fallback: try to find by data attribute
              followedSection = sideNav.querySelector('[aria-label*="Followed" i], [aria-label*="Suivi" i]');
            }

            if (!followedSection) { return; }

            // Get all channel links within the followed section only
            const links = Array.from(followedSection.querySelectorAll('a[href^="/"]'));

            // Stop if we hit "Recommended" or "Show More"
            let hitEnd = false;

            links.forEach(link => {
              if (hitEnd) { return; }

              const href = link.getAttribute('href');
              if (!href || !href.startsWith('/') || href.startsWith('/directory') || href.startsWith('/videos') || href.startsWith('/settings')) { return; }

              // Check if this link is for "Show More" or similar
              const linkText = (link.textContent || '').toLowerCase().trim();
              if (linkText.includes('show more') || linkText.includes('afficher plus') || linkText.includes('recommended')) {
                hitEnd = true;
                return;
              }

              // Must have exactly one path segment (channel name only)
              const pathParts = href.split('/').filter(Boolean);
              if (pathParts.length > 1 && pathParts[1] !== 'home') { return; }

              let cleanedHref = href;
              if (/^\\/[^/]+\\/home\\/?$/.test(cleanedHref)) {
                cleanedHref = cleanedHref.replace(/\\/home\\/?$/, '');
              }
              const url = 'https://www.twitch.tv' + cleanedHref;
              let name = link.getAttribute('aria-label') || link.getAttribute('title') || '';

              // If aria-label has extra info, try to get just the channel name from a child element
              if (!name || name.includes('streaming') || name.includes('diffuse')) {
                const nameEl = link.querySelector('[class*="CoreText"], [class*="channel-name"], p, span');
                if (nameEl) {
                  name = nameEl.textContent || '';
                }
              }

              // Clean up the name
              name = name
                .replace(/\\(Verified\\)/gi, '')
                .replace(/\\(Partner\\)/gi, '')
                .replace(/streaming\\s+.*/i, '')
                .replace(/diffuse\\s+.*/i, '')
                .replace(/en\\s+direct.*/i, '')
                .replace(/live\\s*:.*/i, '')
                .replace(/\\d+[\\s,]*\\d*\\s*(viewer|spectateur|watching).*/i, '')
                .replace(/→/g, '')
                .replace(/›/g, '')
                .replace(/\\s+/g, ' ')
                .trim();

              if (!name) {
                const parts = cleanedHref.split('/').filter(Boolean);
                name = parts.length ? parts[0] : '';
              }
              if (!name.trim()) { return; }

              let thumb = '';
              const img = link.querySelector('img');
              if (img && img.getAttribute('src')) {
                thumb = img.getAttribute('src');
              }
              if (!map.has(url)) {
                map.set(url, { name: name.trim(), url, thumbnail: thumb });
              }
            });
          }

          // Returns all channel logins found in the sidebar Followed Channels section,
          // including recently-offline channels shown with a gray indicator.
          function extractSideNavAllLogins() {
            const sideNav = document.querySelector('[data-a-target*="side-nav"], [data-test-selector="side-nav"], nav[aria-label="Primary Navigation"]');
            if (!sideNav) { return []; }
            let followedSection = null;
            const allText = sideNav.querySelectorAll('p, span, div, h1, h2, h3, h4, h5, h6');
            for (const el of allText) {
              const text = (el.textContent || '').trim().toLowerCase();
              if (text === 'followed channels' || text === 'chaînes suivies' || text === 'followed' || text === 'suivi') {
                followedSection = el.closest('[class*="side-nav-section"], [class*="SideNavSection"], div');
                break;
              }
            }
            if (!followedSection) {
              followedSection = sideNav.querySelector('[aria-label*="Followed" i], [aria-label*="Suivi" i]');
            }
            if (!followedSection) { return []; }

            const logins = [];
            const links = Array.from(followedSection.querySelectorAll('a[href^="/"]'));
            for (const link of links) {
              const href = link.getAttribute('href');
              if (!href || !href.startsWith('/') || href.startsWith('/directory') || href.startsWith('/videos') || href.startsWith('/settings')) { continue; }
              const linkText = (link.textContent || '').toLowerCase().trim();
              if (linkText.includes('show more') || linkText.includes('afficher plus') || linkText.includes('recommended')) { break; }
              const pathParts = href.split('/').filter(Boolean);
              if (pathParts.length > 1 && pathParts[1] !== 'home') { continue; }
              let cleanHref = href;
              if (/^\\/[^/]+\\/home\\/?$/.test(cleanHref)) { cleanHref = cleanHref.replace(/\\/home\\/?$/, ''); }
              const login = cleanHref.split('/').filter(Boolean)[0];
              if (login && !logins.includes(login.toLowerCase())) {
                logins.push(login.toLowerCase());
              }
            }
            return logins;
          }

          function extract() {
            const map = new Map();
            // Extract from /following page (background webview)
            extractFromFollowing(map);
            // Also extract from sidebar "Followed Channels" section (main webview)
            // This section only shows LIVE followed channels
            extractFromSideNav(map);
            window.webkit.messageHandlers.followedLive.postMessage(Array.from(map.values()));

            // Post all sidebar logins (live + recently-offline) as a supplementary
            // source for the offline section in case the Helix/GQL API is unavailable.
            const sideNavLogins = extractSideNavAllLogins();
            if (sideNavLogins.length > 0) {
              window.webkit.messageHandlers.sideNavFollowedLogins.postMessage(sideNavLogins);
            }
          }

          extract();
          setInterval(() => {
            // Only run periodic extraction if on a /following page (background webview)
            // or if the side nav is visible (main webview). Skip otherwise to save CPU.
            const path = location.pathname || '';
            if (path.includes('/following') || path.includes('/directory/following') ||
                document.querySelector('[data-a-target*="side-nav"]')) {
              extract();
            }
          }, 10000);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    // Use a realistic modern Safari UA for Twitch web compatibility checks.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"
    static let chromeAuthUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"

    private static let browserCompatScript = WKUserScript(
        source: #"""
        (function() {
          if (window.__glitcho_browser_compat_bootstrap) { return; }
          window.__glitcho_browser_compat_bootstrap = true;

          const el = document.createElement('script');
          el.type = 'text/javascript';
          el.textContent = '(' + function() {
            if (window.__glitcho_browser_compat) { return; }
            window.__glitcho_browser_compat = true;

            const ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36";

            function defineProp(target, key, value) {
              try {
                Object.defineProperty(target, key, {
                  configurable: true,
                  get: function() { return value; }
                });
              } catch (_) {}
            }

            defineProp(navigator, 'userAgent', ua);
            defineProp(navigator, 'appVersion', ua);
            defineProp(navigator, 'platform', 'MacIntel');
            defineProp(navigator, 'vendor', 'Google Inc.');
            defineProp(navigator, 'productSub', '20030107');
            defineProp(navigator, 'webdriver', false);
            defineProp(navigator, 'language', 'en-US');
            defineProp(navigator, 'languages', ['en-US', 'en']);
            defineProp(navigator, 'plugins', [{ name: 'Chrome PDF Viewer' }]);
            defineProp(navigator, 'mimeTypes', [{ type: 'application/pdf' }]);

            try {
              if (!navigator.userAgentData) {
                const brands = [
                  { brand: "Chromium", version: "133" },
                  { brand: "Google Chrome", version: "133" },
                  { brand: "Not_A Brand", version: "24" }
                ];
                const uaData = {
                  brands: brands,
                  mobile: false,
                  platform: "macOS",
                  getHighEntropyValues: async function(hints) {
                    const response = {};
                    const requested = Array.isArray(hints) ? hints : [];
                    for (const hint of requested) {
                      if (hint === "architecture") { response.architecture = "x86"; }
                      else if (hint === "bitness") { response.bitness = "64"; }
                      else if (hint === "model") { response.model = ""; }
                      else if (hint === "platform") { response.platform = "macOS"; }
                      else if (hint === "platformVersion") { response.platformVersion = "14.7.2"; }
                      else if (hint === "uaFullVersion") { response.uaFullVersion = "133.0.0.0"; }
                    }
                    return response;
                  }
                };
                defineProp(navigator, 'userAgentData', uaData);
              }
            } catch (_) {}

            try {
              if (!window.chrome) {
                defineProp(window, 'chrome', {
                  runtime: {},
                  app: {},
                  webstore: {},
                  csi: function() { return {}; },
                  loadTimes: function() { return {}; }
                });
              } else {
                if (!window.chrome.runtime) { window.chrome.runtime = {}; }
                if (!window.chrome.webstore) { window.chrome.webstore = {}; }
              }
            } catch (_) {}
          }.toString() + ')();';

          (document.documentElement || document.head || document.body).appendChild(el);
          try { el.remove(); } catch (_) {}
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static let adBlockScript = WKUserScript(
        source: """
        (function() {
          if (window.__purple_adblock) { return; }
          window.__purple_adblock = true;

          const _path = (location.pathname || '').toLowerCase();
          if (
            _path.startsWith('/login') ||
            _path.startsWith('/signup') ||
            _path.startsWith('/password') ||
            _path.startsWith('/reset') ||
            _path.startsWith('/activate')
          ) {
            return;
          }

          // Enhanced Adblock - Network request blocking (inspired by uBlock Origin)
          const blockedDomains = new Set([
            'doubleclick.net','googlesyndication.com','googleadservices.com',
            'amazon-adsystem.com','advertising.amazon.com','pubads.g.doubleclick.net',
            'adservice.google.com','ads.twitch.tv','ads-api.twitter.com','ads-twitter.com',
            'criteo.com','criteo.net','taboola.com','outbrain.com','smartadserver.com',
            'adform.net','adsrvr.org','pubmatic.com','openx.net','doubleverify.com',
            'google-analytics.com','analytics.google.com','googletagmanager.com',
            'googletagservices.com','stats.g.doubleclick.net','facebook.com/tr',
            'connect.facebook.net','pixel.facebook.com','scorecardresearch.com',
            'comscore.com','pubads.twitch.tv','ttvnw.net/ads','video-weaver.twitch.tv/ads',
            'adnxs.com','rubiconproject.com','indexww.com','casalemedia.com',
            'adsafeprotected.com','moatads.com','krxd.net'
          ]);
          const _adPatternRe = new RegExp('/ads?/|/advert|/sponsor|/pixel|/beacon|utm_source=|utm_medium=', 'i');

          const allowedDomains = new Set([
            'static.twitchcdn.net','assets.twitch.tv','static-cdn.jtvnw.net',
            'gql.twitch.tv','twitch.tv','www.twitch.tv','m.twitch.tv',
            'vod-secure.twitch.tv','clips-media-assets2.twitch.tv',
            'usher.ttvnw.net','video-weaver'
          ]);

          function shouldBlockRequest(url) {
            if (!url || typeof url !== 'string') return false;
            const lowerUrl = url.toLowerCase();
            // Never block Twitch's own CDN / first-party module URLs
            for (const domain of allowedDomains) {
              if (lowerUrl.includes(domain) && !lowerUrl.includes('/ads/') && !lowerUrl.includes('/ads?')) { return false; }
            }
            for (const domain of blockedDomains) {
              if (lowerUrl.includes(domain)) { return true; }
            }
            return _adPatternRe.test(lowerUrl);
          }

          // Purple Adblock - Playlist filtering
          const originalFetch = window.fetch;
          const originalXHROpen = XMLHttpRequest.prototype.open;
          const originalXHRSend = XMLHttpRequest.prototype.send;

          // Function to filter M3U8 playlists
          function filterM3U8Playlist(playlistText) {
            if (!playlistText || typeof playlistText !== 'string') return playlistText;
            
            const lines = playlistText.split('\n');
            const filtered = [];
            let skipNext = false;
            
            for (let i = 0; i < lines.length; i++) {
              const line = lines[i];
              
              // Detect ad segments
              if (line.includes('#EXT-X-DATERANGE') && 
                  (line.includes('stitched-ad') || 
                   line.includes('AMAZON') || 
                   line.includes('AD-') ||
                   line.includes('commercial'))) {
                skipNext = true;
                continue;
              }
              
              // Skip the segment URL after an ad marker
              if (skipNext && !line.startsWith('#')) {
                skipNext = false;
                continue;
              }
              
              // Filter out ad-related tags
              if (line.includes('#EXT-X-DISCONTINUITY') && skipNext) {
                skipNext = false;
                continue;
              }
              
              filtered.push(line);
            }
            
            return filtered.join('\n');
          }

          // Override fetch for playlist requests + ad blocking
          window.fetch = async function(resource, init) {
            const url = typeof resource === 'string' ? resource : (resource && resource.url);

            // Never interfere with JavaScript module/chunk loading
            if (url && (url.endsWith('.js') || url.endsWith('.mjs') || url.includes('/chunk'))) {
              return originalFetch.apply(this, arguments);
            }

            // Block ad/tracking requests
            if (shouldBlockRequest(url)) {
              return Promise.reject(new Error('Blocked by Enhanced Adblock'));
            }
            
            try {
              // Intercept playlist requests
              if (url && (url.includes('.m3u8') || url.includes('playlist'))) {
                
                const response = await originalFetch.apply(this, arguments);
                
                if (response.ok && url.includes('.m3u8')) {
                  const text = await response.text();
                  const filtered = filterM3U8Playlist(text);
                  
                  return new Response(filtered, {
                    status: response.status,
                    statusText: response.statusText,
                    headers: response.headers
                  });
                }
                
                return response;
              }
              
              // Filter GraphQL ad operations
              if (url && url.includes('gql.twitch.tv/gql') && init && init.body) {
                try {
                  const body = JSON.parse(init.body);
                  const adOperations = [
                    'VideoPlayerStreamInfoOverlayChannel',
                    'ComscoreStreamingQuery',
                    'VideoAdUI'
                  ];
                  
                  if (Array.isArray(body)) {
                    const filtered = body.filter(item => {
                      return !adOperations.includes(item.operationName || '');
                    });
                    
                    if (filtered.length !== body.length) {
                      init.body = JSON.stringify(filtered);
                    }
                  }
                } catch (e) {}
              }
            } catch (e) {}
            
            return originalFetch.apply(this, arguments);
          };

          // Override XMLHttpRequest for legacy requests + ad blocking
          XMLHttpRequest.prototype.open = function(method, url) {
            this.__purple_url = url;
            this.__purple_method = method;
            
            // Block ad/tracking requests
            if (shouldBlockRequest(url)) {
              this.__purple_blocked = true;
            }
            
            return originalXHROpen.apply(this, arguments);
          };

          XMLHttpRequest.prototype.send = function(body) {
            const self = this;
            const url = this.__purple_url;
            
            // Block if flagged
            if (this.__purple_blocked) {
              return;
            }
            
            if (url && url.includes('.m3u8')) {
              const originalOnLoad = this.onload;
              const originalOnReadyStateChange = this.onreadystatechange;
              
              this.addEventListener('load', function() {
                if (self.responseType === '' || self.responseType === 'text') {
                  try {
                    const filtered = filterM3U8Playlist(self.responseText);
                    Object.defineProperty(self, 'responseText', {
                      value: filtered,
                      writable: false
                    });
                    Object.defineProperty(self, 'response', {
                      value: filtered,
                      writable: false
                    });
                  } catch (e) {}
                }
              });
            }
            
            return originalXHRSend.apply(this, arguments);
          };

          // Enhanced CSS blocking (inspired by uBlock Origin filters)
          const adBlockCSS = `
            /* Video ad elements */
            [data-a-target="video-ad-countdown"],
            [data-a-target="video-ad-label"],
            [data-a-target="video-ad-overlay"],
            [data-test-selector="video-ad"],
            [class*="video-ads"],
            [class*="VideoAd"],
            [class*="video-ad"],
            .video-ads,
            .video-ad,
            .video-ad__overlay,
            .ad-container,
            .ads-container,
            
            /* Ad banners & overlays */
            [data-a-target="ad-banner"],
            [data-test-selector="ad-banner"],
            [data-test-selector="ad-overlay"],
            [data-a-target="ad-overlay"],
            .ad-overlay,
            .ad-banner,
            .directory-banner,
            [data-a-target="directory-banner"],
            [data-test-selector="directory-banner"],
            [class*="directory-banner"],
            [id*="directory-banner"],
            [data-a-target="display-ad"],
            [data-test-selector="display-ad"],
            [data-a-target*="display-ad"],
            [data-test-selector*="display-ad"],
            [data-a-target="ad-banner"],
            [data-test-selector="ad-banner"],
            [id*="ad-banner"],
            [id*="ad-overlay"],
            [class*="AdBanner"],
            [class*="ad-banner"],
            /* Display ads on directory/browse */
            [data-a-target="display-ad"],
            [data-test-selector="display-ad"],
            [aria-label="Advertisement"],
            [aria-label="advertisement"],

            /* Twitch-specific ad elements */
            .tw-ad,
            [class*="TwitchAd"],
            [class*="twitch-ad"],
            .channel-info-bar__ad,

            /* Sponsored content */
            [data-a-target="sponsorship"],
            [data-test-selector="sponsorship"],
            .sponsored-content,
            
            /* Common ad patterns */
            div[id^="ad-"],
            div[id*="-ad-"],
            div[id$="-ad"],
            div[class^="ad-"],
            div[class*="-ad-"],
            div[class$="-ad"],
            iframe[src*="/ad/"],
            iframe[src*="/ads/"],
            iframe[id*="ad"],
            
            /* Tracking pixels */
            img[src*="tracking"],
            img[src*="pixel"],
            img[src*="beacon"],
            img[width="1"][height="1"],
            
            /* Analytics */
            [id*="analytics"],
            [class*="analytics"],
            script[src*="analytics"],
            script[src*="tracking"] {
              display: none !important;
              visibility: hidden !important;
              opacity: 0 !important;
              pointer-events: none !important;
              height: 0 !important;
              width: 0 !important;
              position: absolute !important;
              left: -9999px !important;
            }
            
            /* Remove ad spacing */
            .ad-placeholder,
            [data-test-selector="ad-placeholder"] {
              display: none !important;
              margin: 0 !important;
              padding: 0 !important;
            }
          `;

          if (!document.getElementById('enhanced-adblocker-style')) {
            const style = document.createElement('style');
            style.id = 'enhanced-adblocker-style';
            style.textContent = adBlockCSS;
            (document.head || document.documentElement).appendChild(style);
          }
          
          // Block ad scripts from loading (only from known ad network domains)
          function isAdNetworkURL(src) {
            if (!src || typeof src !== 'string') return false;
            const lower = src.toLowerCase();
            for (const domain of blockedDomains) {
              if (lower.includes(domain)) return true;
            }
            return false;
          }
          const scriptObserver = new MutationObserver((mutations) => {
            mutations.forEach((mutation) => {
              mutation.addedNodes.forEach((node) => {
                if (node.tagName === 'SCRIPT' && node.src && isAdNetworkURL(node.src)) {
                  node.remove();
                }
                if (node.tagName === 'IFRAME' && node.src && isAdNetworkURL(node.src)) {
                  node.remove();
                }
              });
            });
          });
          scriptObserver.observe(document.documentElement, { childList: true, subtree: true });
          
          // Remove existing ad scripts
          document.querySelectorAll('script').forEach((script) => {
            if (script.src && shouldBlockRequest(script.src)) {
              script.remove();
            }
          });
          
          // Remove existing ad iframes
          document.querySelectorAll('iframe').forEach((iframe) => {
            if (iframe.src && shouldBlockRequest(iframe.src)) {
              iframe.remove();
            }
          });
          
          // Block Image.prototype.src setter for tracking pixels (ad networks only)
          const originalImageSrc = Object.getOwnPropertyDescriptor(Image.prototype, 'src');
          if (originalImageSrc && originalImageSrc.set) {
            Object.defineProperty(Image.prototype, 'src', {
              set: function(value) {
              if (isAdNetworkURL(value)) {
                  return;
                }
                originalImageSrc.set.call(this, value);
              },
              get: originalImageSrc.get
            });
          }

          // Monitor for ad indicators
          let adCheckInterval = null;
          function startAdMonitoring() {
            if (adCheckInterval) return;
            
            adCheckInterval = setInterval(() => {
              const adIndicators = document.querySelectorAll(
                '[data-a-target="video-ad-countdown"], [data-a-target="video-ad-label"], .ad-overlay'
              );
              
              if (adIndicators.length > 0) {
                adIndicators.forEach(el => {
                  el.style.display = 'none';
                  el.style.visibility = 'hidden';
                });
              }
            }, 500);
          }

          startAdMonitoring();
          
          // Aggressively remove ad elements periodically (MutationObserver handles new nodes)
          setInterval(() => {
            function normalize(s) {
              return (s || '').toLowerCase().replace(/\\s+/g, ' ').trim();
            }

            function looksLikeAmazonAd(el) {
              try {
                const t = normalize(el.textContent);
                if (t.includes('shop on amazon') || t.includes('add to cart') || t.includes('prime')) { return true; }
                if (t.includes('dyson') && t.includes('$')) { return true; } // common banner pattern
                const imgs = el.querySelectorAll ? el.querySelectorAll('img') : [];
                for (const img of imgs) {
                  const alt = normalize(img.getAttribute('alt') || '');
                  const src = normalize(img.getAttribute('src') || '');
                  if (alt.includes('prime') || alt.includes('amazon') || src.includes('amazon')) { return true; }
                }
              } catch (_) {}
              return false;
            }

            function hasExternalLink(el) {
              try {
                const links = el.querySelectorAll('a[href]');
                for (const a of links) {
                  const href = a.getAttribute('href') || '';
                  if (!href) { continue; }
                  if (href.startsWith('http') && !href.includes('twitch.tv')) { return true; }
                  // Ads are often external or go through a twitch redirect
                  if (href.includes('amazon.') || href.includes('amzn.to') || href.includes('amazon')) { return true; }
                  if (href.includes('/redirect') && (href.includes('amazon') || href.includes('amzn'))) { return true; }
                }
              } catch (_) {}
              return false;
            }

            function hasAdIframe(el) {
              try {
                const iframes = el.querySelectorAll('iframe[src]');
                for (const iframe of iframes) {
                  const src = (iframe.getAttribute('src') || '').toLowerCase();
                  if (!src) { continue; }
                  if (shouldBlockRequest(src)) { return true; }
                  if (src.includes('amazon-adsystem') || src.includes('doubleclick') || src.includes('googlesyndication')) { return true; }
                }
              } catch (_) {}
              return false;
            }

            function removeLikelyAdContainer(seed) {
              let cur = seed;
              for (let i = 0; i < 10 && cur; i++) {
                const rect = cur.getBoundingClientRect ? cur.getBoundingClientRect() : null;
                const okSize = rect && rect.width >= 240 && rect.height >= 50 && rect.height <= 650;
                if (okSize && (hasExternalLink(cur) || hasAdIframe(cur) || looksLikeAmazonAd(cur))) {
                  cur.remove();
                  return true;
                }
                cur = cur.parentElement;
              }
              return false;
            }

            // Remove any elements matching ad patterns
            const adSelectors = [
              '[data-a-target="video-ad-countdown"]',
              '[data-a-target="video-ad-label"]',
              '[data-a-target="video-ad-overlay"]',
              '[data-a-target="ad-banner"]',
              '[data-a-target="ad-overlay"]',
              '[data-test-selector="video-ad"]',
              '[data-test-selector="ad-banner"]',
              '[data-test-selector="ad-overlay"]',
              '.directory-banner',
              '[data-a-target="directory-banner"]',
              '[data-test-selector="directory-banner"]',
              '[class*="directory-banner"]',
              '[id*="directory-banner"]',
              '[data-a-target="display-ad"]',
              '[data-test-selector="display-ad"]',
              '[data-a-target="sponsorship"]'
            ];
            
            adSelectors.forEach(selector => {
              try {
                const elements = document.querySelectorAll(selector);
                elements.forEach(el => {
                  // Only remove if it looks like an ad (not the main content)
                  const text = (el.textContent || '').toLowerCase();
                  if (text.includes('advertisement') || 
                      text.includes('sponsored') || 
                      text.includes('ad:') ||
                      text.trim() === 'ad' ||
                      text.includes('shop on amazon') ||
                      text.includes('add to cart') ||
                      text.includes('shop now') ||
                      text.includes('learn more') ||
                      el.querySelector('iframe[src*="ad"]') ||
                      el.querySelector('iframe[src*="amazon"]') ||
                      el.className.match(/\\b(ad|ads|adv|banner|sponsor)\\b/i)) {
                    el.remove();
                  }
                });
              } catch (e) {}
            });

            // Force-remove directory banner ads even if they don't match text heuristics.
            try {
              document.querySelectorAll('.directory-banner, [data-a-target="directory-banner"], [data-test-selector="directory-banner"], [class*="directory-banner"], [id*="directory-banner"], [data-a-target="display-ad"], [data-test-selector="display-ad"]').forEach(el => {
                el.remove();
              });
            } catch (e) {}

            // Fallback: remove Amazon display ad cards that don't match selectors.
            try {
              const triggers = new Set(['shop on amazon', 'add to cart', 'shop now', 'learn more']);

              const candidates = Array.from(document.querySelectorAll('a,button,span'));
              candidates.forEach(node => {
                const t = normalize(node.textContent);
                if (!t) { return; }
                const hit = Array.from(triggers).some(k => t.includes(k)) || t === 'ad';
                if (!hit) { return; }

                removeLikelyAdContainer(node);
              });
            } catch (e) {}

            // Fallback: remove generic "Ad" badge blocks (works across Home/Following/Browse).
            try {
              const badgeCandidates = Array.from(document.querySelectorAll('[aria-label],span,div'))
                .filter(el => {
                  const aria = normalize(el.getAttribute && el.getAttribute('aria-label'));
                  const txt = normalize(el.textContent);
                  return aria === 'ad' || aria.includes('advertisement') || txt === 'ad' || txt === 'advertisement';
                });
              badgeCandidates.forEach(badge => {
                removeLikelyAdContainer(badge);
              });
            } catch (e) {}

            // Fallback: remove "Shop on Amazon" / "Prime" blocks anywhere (tends to be ads).
            try {
              const any = Array.from(document.querySelectorAll('button,span,div,a'))
                .filter(el => {
                  const txt = normalize(el.textContent);
                  return txt.includes('shop on amazon') || txt.includes('add to cart') || txt.includes('prime');
                });
              any.forEach(node => { removeLikelyAdContainer(node); });
            } catch (e) {}
          }, 10000);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static let codecWorkaroundScript = WKUserScript(
        source: """
        (function() {
          try {
            const host = (location && location.host) ? location.host : '';
            if (!host.endsWith('twitch.tv')) { return; }
          } catch (_) {}

          if (window.__twitchglass_codec_workaround) { return; }
          window.__twitchglass_codec_workaround = true;

          function shouldBlock(mime) {
            if (!mime || typeof mime !== 'string') { return false; }
            const lower = mime.toLowerCase();
            return (
              lower.includes('av01') ||
              lower.includes('vp09') ||
              lower.includes('vp8') ||
              lower.includes('hvc1') ||
              lower.includes('hev1')
            );
          }

          try {
            if (window.MediaSource && typeof MediaSource.isTypeSupported === 'function') {
              const originalIsTypeSupported = MediaSource.isTypeSupported.bind(MediaSource);
              MediaSource.isTypeSupported = function(mime) {
                if (shouldBlock(mime)) { return false; }
                return originalIsTypeSupported(mime);
              };
            }
          } catch (_) {}

          try {
            const mc = navigator && navigator.mediaCapabilities;
            if (mc && typeof mc.decodingInfo === 'function') {
              const originalDecodingInfo = mc.decodingInfo.bind(mc);
              mc.decodingInfo = async function(config) {
                try {
                  const videoType = config && config.video && config.video.contentType;
                  const audioType = config && config.audio && config.audio.contentType;
                  if (shouldBlock(videoType) || shouldBlock(audioType)) {
                    return { supported: false, smooth: false, powerEfficient: false };
                  }
                } catch (_) {}
                return originalDecodingInfo(config);
              };
            }
          } catch (_) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static let twitchNoSubScript = WKUserScript(
        source: #"""
        (function() {
          'use strict';

          // Inject script into page context (not isolated world) so it can intercept Worker
          const script = document.createElement('script');
          script.textContent = `
            (function() {
              'use strict';

              if (window.__glitcho_twitchnosub) { return; }
              window.__glitcho_twitchnosub = true;

              const _path = (window.location.pathname || '').toLowerCase();
              // Only run TwitchNoSub logic on VOD/video surfaces.
              // Running globally can interfere with Twitch auth/app bootstrap.
              const _isVideoSurface =
                _path.includes('/videos') ||
                _path.includes('/clip') ||
                _path.includes('/clips') ||
                _path.includes('/collections');
              if (!_isVideoSurface) {
                return;
              }

              // Amazon Worker Patch - This needs to run in the Web Worker context
              const amazonWorkerPatchScript = \`
            async function fetchTwitchDataGQL(vodID) {
              const resp = await fetch("https://gql.twitch.tv/gql", {
                method: 'POST',
                body: JSON.stringify({
                  "query": "query { video(id: \\"" + vodID + "\\") { broadcastType, createdAt, seekPreviewsURL, owner { login } }}"
                }),
                headers: {
                  'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
                  'Accept': 'application/json',
                  'Content-Type': 'application/json'
                }
              });
              return resp.json();
            }

            function createServingID() {
              const w = "0123456789abcdefghijklmnopqrstuvwxyz".split("");
              let id = "";
              for (let i = 0; i < 32; i++) {
                id += w[Math.floor(Math.random() * w.length)];
              }
              return id;
            }

            const defaultResolutions = (() => {
              const _defaultResolutions = {
                "160p30": { "name": "160p", "resolution": "284x160", "frameRate": 30 },
                "360p30": { "name": "360p", "resolution": "640x360", "frameRate": 30 },
                "480p30": { "name": "480p", "resolution": "854x480", "frameRate": 30 },
                "720p60": { "name": "720p60", "resolution": "1280x720", "frameRate": 60 },
                "1080p60": { "name": "1080p60", "resolution": "1920x1080", "frameRate": 60 },
                "1440p60": { "name": "1440p60", "resolution": "2560x1440", "frameRate": 60 },
                "chunked": { "name": "chunked", "resolution": "chunked", "frameRate": 60 }
              };
              let sorted_dict = Object.keys(_defaultResolutions).reverse();
              let ordered_resolutions = {};
              for (const key of sorted_dict) {
                ordered_resolutions[key] = _defaultResolutions[key];
              }
              return ordered_resolutions;
            })();

            async function isValidQuality(url) {
              const response = await fetch(url, { cache: "force-cache" });
              if (response.ok) {
                const data = await response.text();
                if (data.includes(".ts")) {
                  return { codec: "avc1.4D001E" };
                }
                if (data.includes(".mp4")) {
                  const mp4Request = await fetch(url.replace("index-dvr.m3u8", "init-0.mp4"), { cache: "force-cache" });
                  if (mp4Request.ok) {
                    const content = await mp4Request.text();
                    return { codec: content.includes("hev1") ? "hev1.1.6.L93.B0" : "avc1.4D001E" };
                  }
                  return { codec: "hev1.1.6.L93.B0" };
                }
              }
              return null;
            }

            const oldFetch = self.fetch;

            self.fetch = async function(input, opt) {
              let url = input instanceof Request ? input.url : input.toString();

              let response = await oldFetch(input, opt);

              // Patch playlist from unmuted to muted segments
              if (url.includes("cloudfront") && url.includes(".m3u8")) {
                const body = await response.text();
                return new Response(body.replace(/-unmuted/g, "-muted"), { status: 200 });
              }

              if (url.startsWith("https://usher.ttvnw.net/vod/")) {
                if (response.status != 200) {
                  const isUsherV2 = url.includes("/vod/v2");

                  const splitUsher = url.split(".m3u8")[0].split("/");
                  const vodId = splitUsher.at(-1);
                  const data = await fetchTwitchDataGQL(vodId);

                  if (!data || !data?.data.video) {
                    return new Response("Unable to fetch twitch data API", { status: 403 });
                  }
                  const vodData = data.data.video;
                  const channelData = vodData.owner;
                  const currentURL = new URL(vodData.seekPreviewsURL);
                  const domain = currentURL.host;
                  const paths = currentURL.pathname.split("/");
                  const vodSpecialID = paths[paths.findIndex(element => element.includes("storyboards")) - 1];

                  let fakePlaylist = '#EXTM3U\\n#EXT-X-TWITCH-INFO:ORIGIN="s3",B="false",REGION="EU",USER-IP="127.0.0.1",SERVING-ID="' + createServingID() + '",CLUSTER="cloudfront_vod",USER-COUNTRY="BE",MANIFEST-CLUSTER="cloudfront_vod"';

                  const now = new Date("2023-02-10");
                  const created = new Date(vodData.createdAt);
                  const time_difference = now.getTime() - created.getTime();
                  const days_difference = time_difference / (1000 * 3600 * 24);
                  const broadcastType = vodData.broadcastType.toLowerCase();
                  let startQuality = 8534030;

                  for (const [resKey, resValue] of Object.entries(defaultResolutions)) {
                    let playlistUrl = undefined;
                    if (broadcastType === "highlight") {
                      playlistUrl = 'https://' + domain + '/' + vodSpecialID + '/' + resKey + '/highlight-' + vodId + '.m3u8';
                    } else if (broadcastType === "upload" && days_difference > 7) {
                      playlistUrl = 'https://' + domain + '/' + channelData.login + '/' + vodId + '/' + vodSpecialID + '/' + resKey + '/index-dvr.m3u8';
                    } else {
                      playlistUrl = 'https://' + domain + '/' + vodSpecialID + '/' + resKey + '/index-dvr.m3u8';
                    }

                    if (!playlistUrl) continue;
                    const result = await isValidQuality(playlistUrl);

                    if (result) {
                      if (isUsherV2) {
                        const variantSource = resKey == "chunked" ? "source" : "transcode";
                        fakePlaylist += '\\n#EXT-X-STREAM-INF:BANDWIDTH=' + startQuality + ',CODECS="' + result.codec + ',mp4a.40.2",RESOLUTION=' + resValue.resolution + ',FRAME-RATE=' + resValue.frameRate + ',STABLE-VARIANT-ID="' + resKey + '",IVS-NAME="' + resValue.name + '",IVS-VARIANT-SOURCE="' + variantSource + '"\\n' + playlistUrl;
                      } else {
                        const enabled = resKey == "chunked" ? "YES" : "NO";
                        fakePlaylist += '\\n#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="' + resKey + '",NAME="' + resKey + '",AUTOSELECT=' + enabled + ',DEFAULT=' + enabled + '\\n#EXT-X-STREAM-INF:BANDWIDTH=' + startQuality + ',CODECS="' + result.codec + ',mp4a.40.2",RESOLUTION=' + resValue.resolution + ',VIDEO="' + resValue.name + '",FRAME-RATE=' + resValue.frameRate + '\\n' + playlistUrl;
                      }
                      startQuality -= 100;
                    }
                  }

                  const header = new Headers();
                  header.append('Content-Type', 'application/vnd.apple.mpegurl');
                  return new Response(fakePlaylist, { status: 200, headers: header });
                }
              }
                  return response;
                };
              \`;

              // Get Worker.js content from Twitch blob URL
              function getWasmWorkerJs(twitchBlobUrl) {
                try {
                  var req = new XMLHttpRequest();
                  req.open('GET', twitchBlobUrl, false);
                  req.overrideMimeType("text/javascript");
                  req.send();
                  return req.responseText;
                } catch (e) {
                  throw e;
                }
              }

              // Override Worker constructor to inject our patch
              const oldWorker = window.Worker;

              window.Worker = class Worker extends oldWorker {
                constructor(workerUrl, options) {
                  const urlString = workerUrl && workerUrl.toString ? workerUrl.toString() : "";
                  const isBlobWorker = typeof urlString === "string" && urlString.startsWith("blob:");
                  const isModuleWorker = !!(options && options.type === "module");

                  // Keep native behavior for non-blob or module workers to avoid
                  // breaking modern loader/runtime workers used by Twitch stories.
                  if (!isBlobWorker || isModuleWorker) {
                    super(workerUrl, options);
                    return;
                  }

                  try {
                    const workerString = getWasmWorkerJs(urlString.replaceAll("'", "%27"));
                    const patchedCode = amazonWorkerPatchScript + '\\n' + workerString;
                    const blobUrl = URL.createObjectURL(new Blob([patchedCode], { type: 'application/javascript' }));
                    super(blobUrl, options);
                  } catch (_) {
                    super(workerUrl, options);
                  }
                }
              };

              // Restriction Remover - Remove subscriber-only badges/overlays
              class RestrictionRemover {
                constructor() {
                  this.observer = null;
                  this.removeExistingRestrictions();
                  this.createObserver();
                  this.addUnblurStyles();
                  this.startContinuousCleanup();
                }

                addUnblurStyles() {
                  // Add CSS to remove blur and overlays from subscriber-only thumbnails
                  const style = document.createElement('style');
                  style.id = 'glitcho-unblur-style';
                  style.textContent = \`
                    /* NUCLEAR OPTION: Remove ALL blur and backdrop-filter from everything */
                    *[style*="blur"],
                    *[style*="filter"] {
                      filter: none !important;
                      -webkit-filter: none !important;
                      backdrop-filter: none !important;
                      -webkit-backdrop-filter: none !important;
                    }

                    /* Target Twitch's specific overlay patterns */
                    [class*="ScPositionOver"],
                    [class*="OverlayWrapper"],
                    [class*="overlay"][style*="blur"],
                    [class*="Overlay"][style*="blur"],
                    div[style*="backdrop-filter"],
                    div[style*="blur"] {
                      display: none !important;
                      visibility: hidden !important;
                      opacity: 0 !important;
                      backdrop-filter: none !important;
                      -webkit-backdrop-filter: none !important;
                      filter: none !important;
                    }

                    /* Remove ALL subscriber-only overlays */
                    [class*="restriction"],
                    [class*="Restriction"],
                    [class*="sub-only"],
                    [class*="SubOnly"],
                    [class*="subscriber-only"],
                    [class*="SubscriberOnly"],
                    [data-a-target*="restriction"],
                    [data-test-selector*="restriction"],
                    [aria-label*="Subscriber only"],
                    [aria-label*="subscribers only"],
                    [aria-label*="Subscriber-only"] {
                      display: none !important;
                      opacity: 0 !important;
                      visibility: hidden !important;
                      pointer-events: none !important;
                    }

                    /* Force thumbnails to be visible and unblurred */
                    [class*="preview"] img,
                    [class*="Preview"] img,
                    [class*="card"] img,
                    [class*="Card"] img,
                    [class*="thumbnail"] img,
                    [class*="Thumbnail"] img,
                    article img {
                      opacity: 1 !important;
                      visibility: visible !important;
                      filter: none !important;
                      -webkit-filter: none !important;
                    }

                    /* Override inline styles on image containers */
                    [class*="preview"] > div,
                    [class*="Preview"] > div,
                    [class*="card"] > div,
                    [class*="Card"] > div {
                      filter: none !important;
                      -webkit-filter: none !important;
                      backdrop-filter: none !important;
                      -webkit-backdrop-filter: none !important;
                    }
                  \`;
                  document.head.appendChild(style);
                }

                startContinuousCleanup() {
                  // Periodic cleanup to catch Twitch re-applying blur
                  setInterval(() => {
                    this.removeExistingRestrictions();
                    this.removeBlurOverlays();
                  }, 2000);

                  // Replace subscriber-only thumbnails with real ones (less frequently)
                  setInterval(() => {
                    this.replaceSubOnlyThumbnails();
                  }, 2000);

                  // Initial thumbnail replacement
                  setTimeout(() => this.replaceSubOnlyThumbnails(), 1500);
                }

                removeBlurOverlays() {
                  // Find all elements with blur in computed style and forcefully remove
                  document.querySelectorAll('[style*="blur"], [style*="filter"]').forEach(el => {
                    el.style.setProperty('filter', 'none', 'important');
                    el.style.setProperty('-webkit-filter', 'none', 'important');
                    el.style.setProperty('backdrop-filter', 'none', 'important');
                    el.style.setProperty('-webkit-backdrop-filter', 'none', 'important');
                  });

                  // Target specific Twitch overlay patterns
                  document.querySelectorAll('[class*="ScPositionOver"], [class*="OverlayWrapper"], [class*="overlay"]').forEach(el => {
                    el.style.setProperty('display', 'none', 'important');
                  });
                }

                // Fetch real VOD thumbnail using TwitchNoSub technique
                async fetchRealThumbnail(vodId) {
                  try {
                    // Same query as TwitchNoSub in Swift
                    const query = 'query { video(id: "' + vodId + '") { broadcastType seekPreviewsURL owner { login } } }';
                    const resp = await fetch('https://gql.twitch.tv/gql', {
                      method: 'POST',
                      headers: {
                        'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
                        'Content-Type': 'application/json'
                      },
                      body: JSON.stringify({ query })
                    });
                    const data = await resp.json();
                    const video = data?.data?.video;
                    if (!video || !video.seekPreviewsURL) return null;

                    // seekPreviewsURL example:
                    // https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/abc123def/storyboards/12345-strip-0.jpg
                    //
                    // Thumbnail URL pattern:
                    // https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/abc123def/thumb/thumb0-320x180.jpg

                    const seekUrl = video.seekPreviewsURL;

                    // Simple replacement: storyboards/* -> thumb/thumb0-320x180.jpg
                    const storyboardPattern = new RegExp('/storyboards/.*$');
                    const thumbUrl320 = seekUrl.replace(storyboardPattern, '/thumb/thumb0-320x180.jpg');
                    const thumbUrl640 = seekUrl.replace(storyboardPattern, '/thumb/thumb0-640x360.jpg');

                    // Try 320x180 first
                    try {
                      const test = await fetch(thumbUrl320, { method: 'HEAD' });
                      if (test.ok) return thumbUrl320;
                    } catch(e) {}

                    // Try 640x360
                    try {
                      const test = await fetch(thumbUrl640, { method: 'HEAD' });
                      if (test.ok) return thumbUrl640;
                    } catch(e) {}

                    // Fallback: use first frame of storyboard
                    return seekUrl;
                  } catch (e) {
                    return null;
                  }
                }

                // Replace placeholder thumbnails with real VOD thumbnails
                async replaceSubOnlyThumbnails() {
                  // Find ALL links to videos
                  const vodLinks = document.querySelectorAll('a[href*="/videos/"]');

                  for (const link of vodLinks) {
                    const href = link.getAttribute('href') || '';
                    // Use RegExp constructor with string to avoid escaping issues
                    const vodPattern = new RegExp('/videos/(\\\\d+)');
                    const match = href.match(vodPattern);
                    if (!match) continue;

                    const vodId = match[1];

                    // Find the closest card/container and its image
                    const container = link.closest('[class*="card"], [class*="Card"], article, div') || link;
                    const imgs = container.querySelectorAll('img');

                    for (const img of imgs) {
                      // Skip if already processed
                      if (img.dataset.tnsProcessed === vodId) continue;

                      const src = img.src || '';

                      // Replace if it looks like a placeholder (not a cf_vods thumbnail)
                      const isRealThumb = src.includes('cf_vods') && (src.includes('/thumb') || src.includes('preview'));

                      if (!isRealThumb && src) {
                        const realThumb = await this.fetchRealThumbnail(vodId);
                        if (realThumb) {
                          img.src = realThumb;
                          img.srcset = '';
                          img.style.objectFit = 'cover';
                        }
                      }
                      img.dataset.tnsProcessed = vodId;
                    }
                  }
                }

                removeExistingRestrictions() {
                  // Remove ALL restriction overlays with aggressive selectors
                  const restrictionSelectors = [
                    '[class*="restriction"]',
                    '[class*="Restriction"]',
                    '[class*="sub-only"]',
                    '[class*="SubOnly"]',
                    '[class*="subscriber-only"]',
                    '[class*="SubscriberOnly"]',
                    '[data-a-target*="restriction"]',
                    '[aria-label*="Subscriber only"]',
                    '[aria-label*="subscribers only"]'
                  ];

                  restrictionSelectors.forEach(selector => {
                    document.querySelectorAll(selector).forEach(element => {
                      // Hide instead of remove to avoid layout shifts
                      element.style.display = 'none';
                      element.style.opacity = '0';
                      element.style.visibility = 'hidden';
                      element.style.pointerEvents = 'none';
                    });
                  });

                  // Remove blur filters from ALL images
                  document.querySelectorAll('img[style*="blur"], video[style*="blur"]').forEach(media => {
                    media.style.filter = 'none';
                    media.style.webkitFilter = 'none';
                  });

                  // Also check parent divs with blur
                  document.querySelectorAll('div[style*="blur"]').forEach(div => {
                    div.style.filter = 'none';
                    div.style.webkitFilter = 'none';
                  });
                }

                createObserver() {
                  this.observer = new MutationObserver((mutations) => {
                    mutations.forEach(mutation => {
                      mutation.addedNodes.forEach(node => {
                        if (node.nodeType === Node.ELEMENT_NODE) {
                          this.processNode(node);
                        }
                      });
                    });
                  });

                  this.observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: false,
                    characterData: false
                  });
                }

                processNode(node) {
                  // Remove restriction overlays
                  if (node.classList && (node.classList.contains('video-preview-card-restriction') ||
                      node.className.includes('VideoPreviewCardRestriction') ||
                      node.className.includes('sub-only-overlay'))) {
                    node.remove();
                    return;
                  }

                  // Remove blur from images
                  if (node.tagName === 'IMG' && node.style && node.style.filter && node.style.filter.includes('blur')) {
                    node.style.filter = 'none';
                  }

                  // Process children
                  if (node.querySelectorAll) {
                    node.querySelectorAll('.video-preview-card-restriction, [class*="VideoPreviewCardRestriction"], [class*="sub-only-overlay"]').forEach(restriction => {
                      restriction.remove();
                    });

                    node.querySelectorAll('img[style*="blur"]').forEach(img => {
                      img.style.filter = 'none';
                    });
                  }
                }
              }

              new RestrictionRemover();
            })();
          \`;

          // Inject into page context by adding script tag to DOM
          (document.head || document.documentElement).appendChild(script);
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static let profileScript = WKUserScript(
        source: """
        (function() {
          function cleanName(value) {
            return (value || '')
              .replace(/'s\\s+(channel|account)/i, '')
              .replace(/profile\\s+picture/i, '')
              .replace(/avatar/i, '')
              .trim();
          }

          function isPlaceholder(value) {
            if (!value) { return true; }
            const lower = value.toLowerCase();
            return (
              lower === 'user' ||
              lower === 'profile' ||
              lower === 'account' ||
              lower === 'avatar' ||
              lower === 'user menu' ||
              lower === 'menu'
            );
          }

          function pickValue(value) {
            const cleaned = cleanName(value);
            return isPlaceholder(cleaned) ? '' : cleaned;
          }

          function mergeProfile(target, source) {
            if (!source) { return target; }
            if (!target.displayName && source.displayName) {
              target.displayName = source.displayName;
            }
            if (!target.login && source.login) {
              target.login = source.login;
            }
            return target;
          }

          function pickFromObject(obj) {
            if (!obj || typeof obj !== 'object') { return {}; }
            const displayName = pickValue(obj.displayName || obj.display_name || obj.name || obj.userDisplayName || obj.user_display_name);
            const login = pickValue(obj.login || obj.username || obj.userLogin || obj.user_login);
            if (displayName || login) {
              return { displayName: displayName, login: login };
            }
            return {};
          }

          function extractFromState(state) {
            if (!state || typeof state !== 'object') { return {}; }
            const candidates = [
              state.session && (state.session.user || state.session.currentUser || state.session.authenticatedUser),
              state.auth && state.auth.user,
              state.user,
              state.currentUser,
              state.viewer
            ];
            for (const candidate of candidates) {
              const picked = pickFromObject(candidate);
              if (picked.displayName || picked.login) {
                return picked;
              }
            }
            return {};
          }

          function extractFromConfig() {
            const sources = [
              window.__twilightSettings,
              window.__TWILIGHT_SETTINGS__,
              window.__TWITCH_SETTINGS__,
              window.__twitch_settings__,
              window.__twitchConfig,
              window.__TwitchSettings
            ];
            for (const source of sources) {
              const picked = pickFromObject(source);
              if (picked.displayName || picked.login) {
                return picked;
              }
              if (source && source.session) {
                const fromSession = pickFromObject(source.session);
                if (fromSession.displayName || fromSession.login) {
                  return fromSession;
                }
              }
            }
            return {};
          }

          function extractFromApollo() {
            const apollo = window.__APOLLO_STATE__;
            if (!apollo || typeof apollo !== 'object') { return {}; }

            // Try to find user data in Apollo cache
            for (const key of Object.keys(apollo)) {
              if (key.startsWith('User:') || key.includes('currentUser') || key.includes('viewer')) {
                const obj = apollo[key];
                if (obj && (obj.displayName || obj.login)) {
                  const picked = pickFromObject(obj);
                  if (picked.displayName || picked.login) {
                    return picked;
                  }
                }
              }
            }

            const root = apollo['Query:ROOT'];
            if (root) {
              const pointer = root.currentUser || root.viewer || root.user || root.loggedInUser;
              if (typeof pointer === 'string' && apollo[pointer]) {
                const picked = pickFromObject(apollo[pointer]);
                if (picked.displayName || picked.login) {
                  return picked;
                }
              } else if (pointer && typeof pointer === 'object') {
                const picked = pickFromObject(pointer);
                if (picked.displayName || picked.login) {
                  return picked;
                }
              }
            }
            return {};
          }

          function extractFromCookies() {
            try {
              const cookies = document.cookie.split(';').reduce((acc, c) => {
                const [key, val] = c.trim().split('=');
                acc[key] = val;
                return acc;
              }, {});

              // Twitch stores login name in 'login' or 'name' cookie
              const login = cookies['login'] || cookies['name'] || '';
              if (login && !isPlaceholder(login)) {
                return { login: decodeURIComponent(login), displayName: '' };
              }
            } catch (_) {}
            return {};
          }

          function extractFromLocalStorage() {
            try {
              // Check various localStorage keys Twitch might use
              const keys = ['twilight-user', 'user', 'currentUser', 'auth-token'];
              for (const key of keys) {
                const data = localStorage.getItem(key);
                if (data) {
                  try {
                    const parsed = JSON.parse(data);
                    const picked = pickFromObject(parsed);
                    if (picked.displayName || picked.login) {
                      return picked;
                    }
                  } catch (_) {}
                }
              }
            } catch (_) {}
            return {};
          }

          function extractProfile() {
            const loginButton = document.querySelector('[data-a-target="login-button"]');
            const loggedIn = !loginButton;

            let displayName = '';
            let login = '';
            let avatar = '';

            const userMenu = document.querySelector('[data-a-target="user-menu-toggle"], [data-test-selector="user-menu-toggle"]');
            if (userMenu) {
              const img = userMenu.querySelector('img');
              if (img && img.getAttribute('src')) {
                avatar = img.getAttribute('src');
              }
              const alt = pickValue(img ? img.getAttribute('alt') : '');
              if (alt) {
                displayName = alt;
              }
              const label = pickValue(userMenu.getAttribute('aria-label') || userMenu.getAttribute('title'));
              if (label && !displayName) {
                displayName = label;
              }
            }

            if (!displayName) {
              const displayNode = document.querySelector('[data-a-target="user-display-name"], [data-test-selector="user-display-name"]');
              if (displayNode) {
                displayName = pickValue(displayNode.textContent || '');
              }
            }

            let merged = { displayName: displayName, login: login };
            merged = mergeProfile(merged, extractFromCookies());
            merged = mergeProfile(merged, extractFromLocalStorage());
            merged = mergeProfile(merged, extractFromConfig());
            merged = mergeProfile(merged, extractFromState(window.__INITIAL_STATE__));
            merged = mergeProfile(merged, extractFromState(window.__TWITCH_STATE__));
            merged = mergeProfile(merged, extractFromState(window.__STATE__));
            merged = mergeProfile(merged, extractFromApollo());

            // If we have login but no displayName, use login as displayName
            if (!merged.displayName && merged.login) {
              merged.displayName = merged.login;
            }

            window.webkit.messageHandlers.profile.postMessage({
              displayName: (merged.displayName || '').trim(),
              login: (merged.login || '').trim(),
              avatar: avatar,
              loggedIn: loggedIn ? 'true' : 'false'
            });
          }

          extractProfile();
          setInterval(extractProfile, 5000);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private static let autoPlayScript = WKUserScript(
        source: """
        (function() {
          if (window.__twitchglass_autoplay) { return; }
          window.__twitchglass_autoplay = true;

          function isNativeManagedRoute() {
            try {
              const host = (location.host || '').toLowerCase();
              const pathParts = (location.pathname || '')
                .split('/')
                .filter(Boolean)
                .map(p => p.toLowerCase());

              if (host === 'clips.twitch.tv') { return true; }
              if (!host.endsWith('twitch.tv') || pathParts.length === 0) { return false; }

              const first = pathParts[0];
              const reserved = new Set([
                'directory', 'downloads', 'login', 'logout', 'search', 'settings', 'signup', 'p',
                'following', 'browse', 'drops', 'subs', 'inventory'
              ]);

              if (first === 'videos' && pathParts.length >= 2) { return true; }
              if (first === 'clip' && pathParts.length >= 2) { return true; }
              if (pathParts.length >= 3 && pathParts[1] === 'clip') { return true; }
              if (!reserved.has(first) && pathParts.length === 1) { return true; }
            } catch (e) {}
            return false;
          }

          if (isNativeManagedRoute()) { return; }

          function tryPlayOnce() {
            const video = document.querySelector('video');
            if (video && video.paused) {
              video.play().catch(() => {});
            }
            const btn = document.querySelector('[data-a-target="player-play-pause-button"]');
            if (btn) {
              const label = (btn.getAttribute('aria-label') || '').toLowerCase();
              if (label.includes('play')) {
                btn.click();
              }
            }
          }

          tryPlayOnce();
          setTimeout(tryPlayOnce, 1500);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )
}

#endif
