import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var store = WebViewStore(url: URL(string: "https://www.twitch.tv")!)
    @State private var searchText = ""
    @State private var showSettingsPopup = false
    @State private var playbackRequest = NativePlaybackRequest(kind: .liveChannel, streamlinkTarget: "twitch.tv", channelName: nil)
    @State private var useNativePlayer = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showSubscriptionPopup = false
    @State private var subscriptionChannel: String?
    @State private var showGiftPopup = false
    @State private var giftChannel: String?

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
                .ignoresSafeArea()

            NavigationSplitView(columnVisibility: $columnVisibility) {
                Sidebar(
                    searchText: $searchText,
                    store: store,
                    showSettingsPopup: $showSettingsPopup,
                    onNavigate: { url in
                        useNativePlayer = false
                        store.navigate(to: url)
                    },
                    onChannelSelected: { channelName in
                        playbackRequest = NativePlaybackRequest(kind: .liveChannel, streamlinkTarget: "twitch.tv/\(channelName)", channelName: channelName)
                        useNativePlayer = true
                    }
                )
                .navigationSplitViewColumnWidth(320)
            } detail: {
                Group {
                    if useNativePlayer {
                        HybridTwitchView(
                            playback: $playbackRequest,
                            onOpenSubscription: { channel in
                                subscriptionChannel = channel
                                showSubscriptionPopup = true
                            },
                            onOpenGiftSub: { channel in
                                giftChannel = channel
                                showGiftPopup = true
                            }
                        )
                    } else {
                        WebViewContainer(webView: store.webView)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(12)
            }
            .navigationSplitViewStyle(.prominentDetail)
            .onChange(of: store.shouldSwitchToNativePlayback) { request in
                if let request {
                    if useNativePlayer, playbackRequest == request {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            store.shouldSwitchToNativePlayback = nil
                        }
                        return
                    }
                    store.prepareWebViewForNativePlayer()
                    playbackRequest = request
                    useNativePlayer = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        store.shouldSwitchToNativePlayback = nil
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 340)

            if showSettingsPopup {
                PopupPanel(
                    title: "Settings",
                    width: 760,
                    height: 700,
                    url: URL(string: "https://www.twitch.tv/settings")!,
                    onLoadScript: settingsPopupScript
                ) {
                    showSettingsPopup = false
                }
                .zIndex(2)
            }

            if showSubscriptionPopup, let channel = subscriptionChannel {
                PopupPanel(
                    title: "Subscribe",
                    width: 760,
                    height: 700,
                    url: URL(string: "https://www.twitch.tv/subs/\(channel)")!,
                    onLoadScript: subscriptionPopupScript
                ) {
                    showSubscriptionPopup = false
                }
                .zIndex(3)
            }

            if showGiftPopup, let channel = giftChannel {
                PopupPanel(
                    title: "Gift a Sub",
                    width: 760,
                    height: 700,
                    url: URL(string: "https://www.twitch.tv/subs/\(channel)?gift=1")!,
                    onLoadScript: subscriptionPopupScript
                ) {
                    showGiftPopup = false
                }
                .zIndex(4)
            }
        }
    }
}

private let settingsPopupScript = """
(function() {
  const css = `
    :root {
      --side-nav-width: 0px !important;
      --side-nav-width-collapsed: 0px !important;
      --side-nav-width-expanded: 0px !important;
      --left-nav-width: 0px !important;
      --top-nav-height: 0px !important;
    }
    header,
    .top-nav,
    .top-nav__menu,
    [data-a-target="top-nav-container"],
    [data-test-selector="top-nav-container"],
    [data-test-selector="top-nav"],
    [data-a-target="top-nav"],
    #sideNav,
    [data-a-target="left-nav"],
    [data-test-selector="left-nav"],
    [data-a-target="side-nav"],
    [data-a-target="side-nav-bar"],
    [data-a-target="side-nav-bar__content"],
    [data-a-target="side-nav-bar__content__inner"],
    [data-a-target="side-nav-bar__overlay"],
    [data-a-target="side-nav__content"],
    [data-a-target="side-nav-container"],
    [data-test-selector="side-nav"],
    nav[aria-label="Primary Navigation"] {
      display: none !important;
      width: 0 !important;
      min-width: 0 !important;
      max-width: 0 !important;
      opacity: 0 !important;
      pointer-events: none !important;
    }
    main,
    [data-a-target="page-layout__main"],
    [data-a-target="page-layout__main-content"],
    [data-a-target="content"] {
      margin-left: 0 !important;
      padding-left: 0 !important;
      margin-top: 0 !important;
      padding-top: 0 !important;
      background: transparent !important;
    }
    body, #root {
      background: transparent !important;
    }
    [data-a-target="user-menu"],
    [data-test-selector="user-menu"],
    [data-a-target="user-menu-dropdown"],
    [data-test-selector="user-menu-dropdown"],
    [data-a-target="user-menu-overlay"],
    [data-test-selector="user-menu-overlay"] {
      display: none !important;
    }
    [data-a-target="settings-layout"],
    [data-test-selector="settings-layout"],
    [data-a-target="settings-content"],
    [data-test-selector="settings-content"] {
      margin: 0 !important;
      padding: 0 !important;
      max-width: 100% !important;
    }
  `;
  let style = document.getElementById('tw-popup-style');
  if (!style) {
    style = document.createElement('style');
    style.id = 'tw-popup-style';
    style.textContent = css;
    document.head.appendChild(style);
  }
})();
"""

private let subscriptionPopupScript = """
(function() {
  const css = `
    :root {
      --side-nav-width: 0px !important;
      --side-nav-width-collapsed: 0px !important;
      --side-nav-width-expanded: 0px !important;
      --left-nav-width: 0px !important;
      --top-nav-height: 0px !important;
    }
    header,
    .top-nav,
    .top-nav__menu,
    [data-a-target="top-nav-container"],
    [data-test-selector="top-nav-container"],
    [data-test-selector="top-nav"],
    [data-a-target="top-nav"],
    #sideNav,
    [data-a-target="left-nav"],
    [data-test-selector="left-nav"],
    [data-a-target="side-nav"],
    [data-a-target="side-nav-bar"],
    [data-a-target="side-nav-bar__content"],
    [data-a-target="side-nav-bar__content__inner"],
    [data-a-target="side-nav-bar__overlay"],
    [data-a-target="side-nav__content"],
    [data-a-target="side-nav-container"],
    [data-test-selector="side-nav"],
    nav[aria-label="Primary Navigation"] {
      display: none !important;
      width: 0 !important;
      min-width: 0 !important;
      max-width: 0 !important;
      opacity: 0 !important;
      pointer-events: none !important;
    }
    main,
    [data-a-target="page-layout__main"],
    [data-a-target="page-layout__main-content"],
    [data-a-target="content"] {
      margin-left: 0 !important;
      padding-left: 0 !important;
      margin-top: 0 !important;
      padding-top: 0 !important;
      background: transparent !important;
    }
    body, #root {
      background: transparent !important;
    }
  `;
  let style = document.getElementById('tw-sub-popup-style');
  if (!style) {
    style = document.createElement('style');
    style.id = 'tw-sub-popup-style';
    style.textContent = css;
    document.head.appendChild(style);
  }
})();
"""

struct Sidebar: View {
    @Binding var searchText: String
    @ObservedObject var store: WebViewStore
    @Binding var showSettingsPopup: Bool
    var onNavigate: ((URL) -> Void)?
    var onChannelSelected: ((String) -> Void)?

    private let sections: [TwitchDestination] = [
        .home,
        .following,
        .browse,
        .music,
        .drops
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header with logo and account
            HStack(spacing: 12) {
                AvatarView(url: store.profileAvatarURL, isLoggedIn: store.isLoggedIn, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isLoggedIn ? (normalized(store.profileName) ?? normalized(store.profileLogin) ?? "Profile") : "Glitcho")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if store.isLoggedIn, let login = normalized(store.profileLogin) {
                        Text("@\(login)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer()

                if store.isLoggedIn {
                    Button {
                        showSettingsPopup = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Settings")

                    Button {
                        store.logout()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Log out")
                } else {
                    Button {
                        let url = URL(string: "https://www.twitch.tv/login")!
                        onNavigate?(url) ?? store.navigate(to: url)
                    } label: {
                        Text("Log in")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.8))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Search
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))

                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .onSubmit {
                        let query = searchText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        let url = URL(string: "https://www.twitch.tv/search?term=\(query)")!
                        onNavigate?(url) ?? store.navigate(to: url)
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 16)

            // Navigation
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sections) { destination in
                        SidebarRow(
                            title: destination.title,
                            systemImage: destination.icon
                        ) {
                            onNavigate?(destination.url) ?? store.navigate(to: destination.url)
                        }
                    }

                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)

                    // Following section
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(1)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)

                    if store.followedLive.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "heart")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("No live channels")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else {
                        ForEach(store.followedLive) { channel in
                            FollowingRow(channel: channel) {
                                let channelName = channel.url.lastPathComponent
                                onChannelSelected?(channelName)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
        }
        .background(
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.10)
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    .opacity(0.5)
            }
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let lower = trimmed.lowercased()
        if ["user", "profile", "account", "avatar", "menu", "user menu"].contains(lower) {
            return nil
        }
        return trimmed
    }
}

struct AvatarView: View {
    let url: URL?
    let isLoggedIn: Bool
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        ZStack {
                            Color.white.opacity(0.1)
                            Image(systemName: "person.fill")
                                .font(.system(size: size * 0.4, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    default:
                        ZStack {
                            Color.white.opacity(0.08)
                            ProgressView()
                                .scaleEffect(0.5)
                                .tint(.white.opacity(0.4))
                        }
                    }
                }
            } else {
                ZStack {
                    Color.purple.opacity(0.3)
                    Image(systemName: isLoggedIn ? "person.fill" : "play.tv.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

struct TwitchDestination: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: URL
    let icon: String

    static let home = TwitchDestination(title: "Home", url: URL(string: "https://www.twitch.tv")!, icon: "house")
    static let following = TwitchDestination(title: "Following", url: URL(string: "https://www.twitch.tv/directory/following")!, icon: "heart")
    static let browse = TwitchDestination(title: "Browse", url: URL(string: "https://www.twitch.tv/directory")!, icon: "sparkles.tv")
    static let categories = TwitchDestination(title: "Categories", url: URL(string: "https://www.twitch.tv/directory/categories")!, icon: "rectangle.grid.2x2")
    static let music = TwitchDestination(title: "Music", url: URL(string: "https://www.twitch.tv/directory/category/music")!, icon: "music.note")
    static let esports = TwitchDestination(title: "Esports", url: URL(string: "https://www.twitch.tv/directory/category/esports")!, icon: "trophy")
    static let drops = TwitchDestination(title: "Drops", url: URL(string: "https://www.twitch.tv/drops")!, icon: "gift")
}

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(
                ZStack {
                    Color(red: 0.06, green: 0.06, blue: 0.08)
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .opacity(0.4)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

struct SidebarRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHovered ? .white : .white.opacity(0.5))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? .white : .white.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

struct FollowingRow: View {
    let channel: TwitchChannel
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Avatar
                Group {
                    if let url = channel.thumbnailURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Color.white.opacity(0.1)
                            }
                        }
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())

                Text(channel.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? .white : .white.opacity(0.7))
                    .lineLimit(1)

                Spacer()

                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        _ = nsView
    }
}

struct PopupWebViewContainer: NSViewRepresentable {
    let url: URL
    let onLoadScript: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadScript: onLoadScript)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.customUserAgent = WebViewStore.safariUserAgent
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
        context.coordinator.onLoadScript = onLoadScript
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLoadScript: String?

        init(onLoadScript: String?) {
            self.onLoadScript = onLoadScript
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let script = onLoadScript else { return }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}

struct PopupPanel: View {
    let title: String
    let width: CGFloat
    let height: CGFloat
    let url: URL
    let onLoadScript: String?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                PopupWebViewContainer(url: url, onLoadScript: onLoadScript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .frame(width: width, height: height)
            .shadow(color: Color.black.opacity(0.4), radius: 30, x: 0, y: 10)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
