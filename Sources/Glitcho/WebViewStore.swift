#if canImport(SwiftUI)
import Foundation
import AppKit
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
    @Published var profileName: String?
    @Published var profileLogin: String?
    @Published var profileAvatarURL: URL?
    @Published var isLoggedIn = false
    @Published var shouldSwitchToNativePlayback: NativePlaybackRequest? = nil
    @Published var channelNotificationToggle: ChannelNotificationToggle? = nil

    private var observations: [NSKeyValueObservation] = []
    private var backgroundWebView: WKWebView?
    private var followedRefreshTimer: Timer?
    private var wasLoggedIn = false
    private var lastNonChannelURL: URL?
    private var followedWarmupAttempts = 0

    private static let sharedProcessPool = WKProcessPool()


    init(url: URL) {
        self.homeURL = url

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.safariUserAgent
        self.webView = webView

        super.init()

        contentController.add(self, name: "followedLive")
        contentController.add(self, name: "profile")
        contentController.add(self, name: "channelNotification")
        contentController.addUserScript(Self.initialHideScript)
        contentController.addUserScript(Self.adBlockScript)
        contentController.addUserScript(Self.codecWorkaroundScript)
        contentController.addUserScript(Self.hideChromeScript)
        contentController.addUserScript(Self.channelActionsScript)
        contentController.addUserScript(Self.ensureLiveStreamScript)
        contentController.addUserScript(Self.followedLiveScript)
        contentController.addUserScript(Self.profileScript)
        contentController.addUserScript(Self.autoPlayScript)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: normalizedTwitchURL(url)))
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
        webView.load(URLRequest(url: normalizedTwitchURL(homeURL)))
    }

    func navigate(to url: URL) {
        webView.load(URLRequest(url: normalizedTwitchURL(url)))
    }

    /// Stoppe toute lecture (vidéo/audio) dans le WebView et retourne à la dernière page non-channel.
    func prepareWebViewForNativePlayer() {
        webView.stopLoading()
        stopWebPlayback()
        if let lastNonChannelURL {
            webView.load(URLRequest(url: lastNonChannelURL))
        } else {
            webView.load(URLRequest(url: normalizedTwitchURL(homeURL)))
        }
    }

    private func stopWebPlayback() {
        let js = """
        (function() {
          try {
            document.querySelectorAll('video').forEach(v => { try { v.pause(); v.muted = true; } catch (e) {} });
            document.querySelectorAll('audio').forEach(a => { try { a.pause(); a.muted = true; } catch (e) {} });
          } catch (e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func logout() {
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
                    self?.webView.load(URLRequest(url: URL(string: "https://www.twitch.tv")!))
                    self?.backgroundWebView?.load(URLRequest(url: URL(string: "https://www.twitch.tv/following")!))
                }
            }
        }
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
        let channel = first.lowercased()
        guard !reserved.contains(channel) else { return nil }
        guard parts.count == 1 else { return nil }

        return NativePlaybackRequest(kind: .liveChannel, streamlinkTarget: "twitch.tv/\(first)", channelName: first)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "followedLive":
            guard let items = message.body as? [[String: String]] else { return }

            let channels = items.compactMap { item -> TwitchChannel? in
                guard let urlString = item["url"], let url = URL(string: urlString) else { return nil }
                let normalizedURL = normalizedTwitchURL(url)
                let name = item["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = (name?.isEmpty == false) ? name! : normalizedURL.lastPathComponent
                let thumb = item["thumbnail"].flatMap { URL(string: $0) }
                return TwitchChannel(id: urlString, name: displayName, url: normalizedURL, thumbnailURL: thumb)
            }

            if !channels.isEmpty {
                DispatchQueue.main.async {
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
            DispatchQueue.main.async {
                if loggedIn {
                    if !self.wasLoggedIn {
                        self.profileName = nil
                        self.profileLogin = nil
                        self.profileAvatarURL = nil
                    }
                    if let name, !name.isEmpty {
                        self.profileName = name
                    }
                    if let login, !login.isEmpty {
                        self.profileLogin = login
                    }
                    if let avatar {
                        self.profileAvatarURL = avatar
                    }
                } else {
                    self.profileName = nil
                    self.profileLogin = nil
                    self.profileAvatarURL = nil
                }
                self.isLoggedIn = loggedIn
                if loggedIn && !self.wasLoggedIn {
                    self.loadFollowedLiveInBackground()
                }
                self.wasLoggedIn = loggedIn
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
        default:
            return
        }
    }

    func setChannelNotificationState(login: String, enabled: Bool) {
        let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        let js = "window.__glitcho_setBellState && window.__glitcho_setBellState('\(normalized)', \(enabled ? "true" : "false"));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        if normalized != url {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: normalized))
            return
        }
        
        if let request = nativePlaybackRequestIfNeeded(url: url) {
            print("❌ [Glitcho] Detected playback: \(request.kind.rawValue) - Switching to native player")
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

    private func makeBackgroundWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.processPool = Self.sharedProcessPool
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []

        contentController.add(self, name: "followedLive")
        contentController.add(self, name: "profile")
        contentController.addUserScript(Self.adBlockScript)
        contentController.addUserScript(Self.codecWorkaroundScript)
        contentController.addUserScript(Self.ensureLiveStreamScript)
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
        return webView
    }

    private func loadFollowedLiveInBackground() {
        guard let backgroundWebView else { return }
        followedWarmupAttempts = 0
        let url = URL(string: "https://www.twitch.tv/following")!
        backgroundWebView.load(URLRequest(url: url))

        followedRefreshTimer?.invalidate()
        followedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.backgroundWebView?.reload()
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

          const observer = new MutationObserver(() => {
            hideNavigation();
          });
          observer.observe(document.documentElement, { childList: true, subtree: true });

          // Détecter les changements d'URL (navigation SPA)
          let lastUrl = location.href;
          new MutationObserver(() => {
            const url = location.href;
            if (url !== lastUrl) {
              lastUrl = url;
              updatePageType();
              // Re-reveal after SPA navigation
              document.body.classList.add('glitcho-ready');
            }
          }).observe(document, { subtree: true, childList: true });
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
          setInterval(decorate, 2000);

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

          function extract() {
            const map = new Map();
            // Extract from /following page (background webview)
            extractFromFollowing(map);
            // Also extract from sidebar "Followed Channels" section (main webview)
            // This section only shows LIVE followed channels
            extractFromSideNav(map);
            if (map.size > 0) {
              window.webkit.messageHandlers.followedLive.postMessage(Array.from(map.values()));
            }
          }

          extract();
          setInterval(extract, 5000);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    private static let adBlockScript = WKUserScript(
        source: """
        (function() {
          if (window.__purple_adblock) { return; }
          window.__purple_adblock = true;

          console.log('[Enhanced Adblock] Initializing with uBlock-inspired rules...');

          // Enhanced Adblock - Network request blocking (inspired by uBlock Origin)
          const blockedDomains = [
            // Ad servers
            'doubleclick.net',
            'googlesyndication.com',
            'googleadservices.com',
            'amazon-adsystem.com',
            'advertising.amazon.com',
            'pubads.g.doubleclick.net',
            'adservice.google.com',
            'ads.twitch.tv',
            'ads-api.twitter.com',
            'ads-twitter.com',
            'criteo.com',
            'criteo.net',
            'taboola.com',
            'outbrain.com',
            'smartadserver.com',
            'adform.net',
            'adsrvr.org',
            'pubmatic.com',
            'openx.net',
            'doubleverify.com',
            // Analytics & tracking
            'google-analytics.com',
            'analytics.google.com',
            'googletagmanager.com',
            'googletagservices.com',
            'stats.g.doubleclick.net',
            'facebook.com/tr',
            'connect.facebook.net',
            'pixel.facebook.com',
            'scorecardresearch.com',
            'comscore.com',
            // Twitch-specific ad domains
            'pubads.twitch.tv',
            'ttvnw.net/ads',
            'video-weaver.twitch.tv/ads',
            // Common ad/tracking patterns
            'adnxs.com',
            'rubiconproject.com',
            'indexww.com',
            'casalemedia.com',
            'adsafeprotected.com',
            'moatads.com',
            'krxd.net'
          ];

          function shouldBlockRequest(url) {
            if (!url || typeof url !== 'string') return false;
            const lowerUrl = url.toLowerCase();
            
            // Check against blocked domains
            for (const domain of blockedDomains) {
              if (lowerUrl.includes(domain)) {
                console.log('[Enhanced Adblock] Blocked domain:', domain, 'in', url);
                return true;
              }
            }
            
            // Block common ad patterns in URLs
            const adPatterns = [
              '/ad/',
              '/ads/',
              '/advert',
              '/banner',
              '/sponsor',
              '/tracking',
              '/analytics',
              '/pixel',
              '/beacon',
              'utm_source=',
              'utm_medium=',
              '_ad.',
              '_ads.',
              'ad_',
              'ads_'
            ];
            
            for (const pattern of adPatterns) {
              if (lowerUrl.includes(pattern)) {
                console.log('[Enhanced Adblock] Blocked pattern:', pattern, 'in', url);
                return true;
              }
            }
            
            return false;
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
                console.log('[Purple Adblock] Filtered ad marker:', line);
                skipNext = true;
                continue;
              }
              
              // Skip the segment URL after an ad marker
              if (skipNext && !line.startsWith('#')) {
                console.log('[Purple Adblock] Skipped ad segment:', line);
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
            const url = typeof resource === 'string' ? resource : resource.url;
            
            // Block ad/tracking requests
            if (shouldBlockRequest(url)) {
              console.log('[Enhanced Adblock] Fetch blocked:', url);
              return Promise.reject(new Error('Blocked by Enhanced Adblock'));
            }
            
            try {
              // Intercept playlist requests
              if (url && (url.includes('.m3u8') || url.includes('playlist'))) {
                console.log('[Purple Adblock] Intercepting playlist:', url);
                
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
                    'ChannelShellQuery',
                    'VideoAdUI'
                  ];
                  
                  if (Array.isArray(body)) {
                    const filtered = body.filter(item => {
                      return !adOperations.includes(item.operationName || '');
                    });
                    
                    if (filtered.length !== body.length) {
                      console.log('[Purple Adblock] Filtered GraphQL ad operations');
                      init.body = JSON.stringify(filtered);
                    }
                  }
                } catch (e) {}
              }
            } catch (e) {
              console.error('[Purple Adblock] Error:', e);
            }
            
            return originalFetch.apply(this, arguments);
          };

          // Override XMLHttpRequest for legacy requests + ad blocking
          XMLHttpRequest.prototype.open = function(method, url) {
            this.__purple_url = url;
            this.__purple_method = method;
            
            // Block ad/tracking requests
            if (shouldBlockRequest(url)) {
              console.log('[Enhanced Adblock] XHR blocked:', url);
              this.__purple_blocked = true;
            }
            
            return originalXHROpen.apply(this, arguments);
          };

          XMLHttpRequest.prototype.send = function(body) {
            const self = this;
            const url = this.__purple_url;
            
            // Block if flagged
            if (this.__purple_blocked) {
              console.log('[Enhanced Adblock] XHR send blocked:', url);
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
            [id*="ad-banner"],
            [id*="ad-overlay"],
            [class*="AdBanner"],
            [class*="ad-banner"],
            /* Display ads on directory/browse */
            [data-a-target*="amazon"],
            [data-test-selector*="amazon"],
            [data-a-target*="display-ad"],
            [data-test-selector*="display-ad"],
            [aria-label*="Advertisement"],
            [aria-label*="advertisement"],
            
            /* Twitch-specific ad elements */
            [data-a-target*="ad-"],
            [data-test-selector*="ad-"],
            .tw-ad,
            [class*="TwitchAd"],
            [class*="twitch-ad"],
            .channel-info-bar__ad,
            
            /* Sponsored content */
            [data-a-target="sponsorship"],
            [data-test-selector="sponsorship"],
            .sponsored-content,
            [class*="Sponsored"],
            [class*="sponsored"],
            
            /* Promotional banners */
            [data-a-target="promo-banner"],
            [data-test-selector="promo-banner"],
            .promo-banner,
            [class*="PromoBanner"],
            
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
          
          // Block ad scripts from loading
          const scriptObserver = new MutationObserver((mutations) => {
            mutations.forEach((mutation) => {
              mutation.addedNodes.forEach((node) => {
                if (node.tagName === 'SCRIPT' && node.src && shouldBlockRequest(node.src)) {
                  console.log('[Enhanced Adblock] Blocked script:', node.src);
                  node.remove();
                }
                if (node.tagName === 'IFRAME' && node.src && shouldBlockRequest(node.src)) {
                  console.log('[Enhanced Adblock] Blocked iframe:', node.src);
                  node.remove();
                }
              });
            });
          });
          scriptObserver.observe(document.documentElement, { childList: true, subtree: true });
          
          // Remove existing ad scripts
          document.querySelectorAll('script').forEach((script) => {
            if (script.src && shouldBlockRequest(script.src)) {
              console.log('[Enhanced Adblock] Removed existing script:', script.src);
              script.remove();
            }
          });
          
          // Remove existing ad iframes
          document.querySelectorAll('iframe').forEach((iframe) => {
            if (iframe.src && shouldBlockRequest(iframe.src)) {
              console.log('[Enhanced Adblock] Removed existing iframe:', iframe.src);
              iframe.remove();
            }
          });
          
          // Block Image.prototype.src setter for tracking pixels
          const originalImageSrc = Object.getOwnPropertyDescriptor(Image.prototype, 'src');
          if (originalImageSrc && originalImageSrc.set) {
            Object.defineProperty(Image.prototype, 'src', {
              set: function(value) {
                if (shouldBlockRequest(value)) {
                  console.log('[Enhanced Adblock] Blocked image:', value);
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
                console.log('[Purple Adblock] Ad overlay detected, hiding...');
                adIndicators.forEach(el => {
                  el.style.display = 'none';
                  el.style.visibility = 'hidden';
                });
              }
            }, 500);
          }

          startAdMonitoring();
          
          // Aggressively remove ad elements every second
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
              '[data-a-target*="ad"]',
              '[data-test-selector*="ad"]',
              '[class*="ad-"]',
              '[class*="Ad"]',
              '[id*="ad-"]',
              '.sponsored',
              '[data-a-target="sponsorship"]',
              '[data-a-target*="amazon"]',
              '[data-test-selector*="amazon"]'
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
          }, 1000);

          console.log('[Enhanced Adblock] Initialized successfully with uBlock-inspired rules');
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
