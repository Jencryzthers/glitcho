#if canImport(SwiftUI)
import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var store = WebViewStore(url: URL(string: "https://www.twitch.tv")!)
    @EnvironmentObject private var updateChecker: UpdateChecker
    @Environment(\.notificationManager) private var notificationManager
    @AppStorage("pinnedChannels") private var pinnedChannelsJSON: String = "[]"
    @AppStorage("liveAlertsEnabled") private var liveAlertsEnabled = true
    @AppStorage("liveAlertsPinnedOnly") private var liveAlertsPinnedOnly = false
    @State private var pinnedChannels: [PinnedChannel] = []
    @State private var hasLoadedPins = false
    @State private var lastLiveLogins: Set<String> = []
    @State private var hasSeenInitialLiveList = false
    @State private var searchText = ""
    @State private var playbackRequest = NativePlaybackRequest(kind: .liveChannel, streamlinkTarget: "twitch.tv", channelName: nil)
    @State private var useNativePlayer = false
    @StateObject private var recordingManager = RecordingManager()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showSubscriptionPopup = false
    @State private var subscriptionChannel: String?
    @State private var showGiftPopup = false
    @State private var giftChannel: String?
    @State private var showSettings = false
    private let pinnedLimit = 8

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
                .ignoresSafeArea()

            NavigationSplitView(columnVisibility: $columnVisibility) {
                Sidebar(
                    searchText: $searchText,
                    store: store,
                    pinnedChannels: $pinnedChannels,
                    pinnedLimit: pinnedLimit,
                    liveAlertsEnabled: $liveAlertsEnabled,
                    onTogglePin: { channel in
                        togglePinned(channel: channel)
                    },
                    onTogglePinNotifications: { pin in
                        togglePinnedNotifications(pin)
                    },
                    onAddPin: { input in
                        addPinned(fromInput: input)
                    },
                    onRemovePin: { pin in
                        removePinned(pin: pin)
                    },
                    onNavigate: { url in
                        useNativePlayer = false
                        store.navigate(to: url)
                    },
                    onChannelSelected: { channelName in
                        playbackRequest = NativePlaybackRequest(kind: .liveChannel, streamlinkTarget: "twitch.tv/\(channelName)", channelName: channelName)
                        useNativePlayer = true
                    },
                    onShowSettings: {
                        showSettings = true
                    }
                )
        .navigationSplitViewColumnWidth(295)
            } detail: {
                Group {
                    if useNativePlayer {
                        HybridTwitchView(
                            playback: $playbackRequest,
                            recordingManager: recordingManager,
                            onOpenSubscription: { channel in
                                subscriptionChannel = channel
                                showSubscriptionPopup = true
                            },
                            onOpenGiftSub: { channel in
                                giftChannel = channel
                                showGiftPopup = true
                            },
                            notificationEnabled: currentNotificationEnabled(),
                            onNotificationToggle: { enabled in
                                guard let login = playbackRequest.channelName else { return }
                                handleChannelNotificationToggle(ChannelNotificationToggle(login: login, enabled: enabled))
                            },
                            onRecordRequest: {
                                guard playbackRequest.kind == .liveChannel else { return }
                                recordingManager.toggleRecording(
                                    target: playbackRequest.streamlinkTarget,
                                    channelName: playbackRequest.channelName
                                )
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

            if updateChecker.isPromptVisible, let update = updateChecker.update {
                UpdatePromptView(update: update) {
                    updateChecker.dismissPrompt()
                }
                .zIndex(5)
            }

            if updateChecker.isStatusVisible, let status = updateChecker.status {
                UpdateStatusView(status: status) {
                    updateChecker.dismissStatus()
                }
                .zIndex(6)
            }

            if showSettings {
                SettingsModal(
                    onClose: { showSettings = false },
                    recordingManager: recordingManager
                )
                .environment(\.notificationManager, notificationManager)
                .zIndex(10)
            }
        }
        .task {
            await updateChecker.checkForUpdates()
        }
        .task {
            loadPinnedChannelsIfNeeded()
        }
        .onChange(of: pinnedChannels) { newValue in
            savePinnedChannels(newValue)
        }
        .onChange(of: store.followedLive) { newValue in
            refreshPinnedMetadata(using: newValue)
            handleFollowedLiveChange(newValue)
        }
        .onChange(of: store.channelNotificationToggle) { request in
            guard let request else { return }
            handleChannelNotificationToggle(request)
            store.channelNotificationToggle = nil
        }
        .onChange(of: liveAlertsEnabled) { isEnabled in
            if isEnabled, let notificationManager {
                Task { _ = await notificationManager.requestAuthorization() }
            }
        }
        .onChange(of: playbackRequest) { _ in
            updateChannelBellStateIfNeeded()
        }
    }

    private func loadPinnedChannelsIfNeeded() {
        guard !hasLoadedPins else { return }
        hasLoadedPins = true
        let decoded = decodePinnedChannels(from: pinnedChannelsJSON)
        var seen = Set<String>()
        let unique = decoded.filter { seen.insert($0.login).inserted }
        pinnedChannels = Array(unique.prefix(pinnedLimit))
        updateChannelBellStateIfNeeded()
    }

    private func savePinnedChannels(_ channels: [PinnedChannel]) {
        pinnedChannelsJSON = encodePinnedChannels(channels)
        updateChannelBellStateIfNeeded()
    }

    private func togglePinned(channel: TwitchChannel) {
        let login = channel.login
        if let index = pinnedChannels.firstIndex(where: { $0.login == login }) {
            pinnedChannels.remove(at: index)
            return
        }

        _ = addPinned(login: login, displayName: channel.name, thumbnailURL: channel.thumbnailURL)
    }

    private func removePinned(pin: PinnedChannel) {
        pinnedChannels.removeAll { $0.login == pin.login }
    }

    private func togglePinnedNotifications(_ pin: PinnedChannel) {
        guard let index = pinnedChannels.firstIndex(where: { $0.login == pin.login }) else { return }
        var updated = pinnedChannels
        updated[index].notifyEnabled.toggle()
        pinnedChannels = updated
    }

    private func addPinned(fromInput input: String) -> Bool {
        guard let login = normalizeChannelLogin(input) else { return false }
        return addPinned(login: login, displayName: login, thumbnailURL: nil)
    }

    private func addPinned(login: String, displayName: String, thumbnailURL: URL?) -> Bool {
        let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        if let index = pinnedChannels.firstIndex(where: { $0.login == normalized }) {
            var updated = pinnedChannels
            let existing = updated.remove(at: index)
            updated.insert(existing, at: 0)
            pinnedChannels = updated
            return true
        }

        guard pinnedChannels.count < pinnedLimit else { return false }

        var updated = pinnedChannels
        let pin = PinnedChannel(login: normalized, displayName: displayName, thumbnailURL: thumbnailURL, notifyEnabled: true)
        updated.insert(pin, at: 0)
        pinnedChannels = updated
        return true
    }

    private func refreshPinnedMetadata(using liveChannels: [TwitchChannel]) {
        guard !pinnedChannels.isEmpty else { return }
        let liveByLogin = Dictionary(liveChannels.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
        var updated = pinnedChannels
        var didChange = false
        for index in updated.indices {
            guard let liveChannel = liveByLogin[updated[index].login] else { continue }
            if updated[index].displayName != liveChannel.name {
                updated[index].displayName = liveChannel.name
                didChange = true
            }
            let thumb = liveChannel.thumbnailURL?.absoluteString
            if updated[index].thumbnailURLString != thumb {
                updated[index].thumbnailURLString = thumb
                didChange = true
            }
        }
        if didChange {
            pinnedChannels = updated
        }
    }

    private func handleFollowedLiveChange(_ liveChannels: [TwitchChannel]) {
        let currentLogins = Set(liveChannels.map { $0.login })
        defer {
            lastLiveLogins = currentLogins
            hasSeenInitialLiveList = true
        }

        guard store.isLoggedIn else { return }
        guard liveAlertsEnabled else { return }
        guard hasSeenInitialLiveList else { return }
        guard let notificationManager else { return }

        let newlyLive = currentLogins.subtracting(lastLiveLogins)
        guard !newlyLive.isEmpty else { return }

        let channelMap = Dictionary(liveChannels.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
        let pinMap = Dictionary(pinnedChannels.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })

        for login in newlyLive {
            guard let channel = channelMap[login] else { continue }
            if liveAlertsPinnedOnly {
                guard let pin = pinMap[login], pin.notifyEnabled else { continue }
            }
            Task {
                await notificationManager.notifyChannelLive(channel)
            }
        }
    }

    private func handleChannelNotificationToggle(_ request: ChannelNotificationToggle) {
        let login = request.login.lowercased()
        if request.enabled {
            _ = addPinned(login: login, displayName: login, thumbnailURL: nil)
            if let index = pinnedChannels.firstIndex(where: { $0.login == login }) {
                var updated = pinnedChannels
                updated[index].notifyEnabled = true
                pinnedChannels = updated
            }
        } else {
            guard let index = pinnedChannels.firstIndex(where: { $0.login == login }) else { return }
            var updated = pinnedChannels
            updated[index].notifyEnabled = false
            pinnedChannels = updated
        }
        updateChannelBellStateIfNeeded()
    }

    private func updateChannelBellStateIfNeeded() {
        guard let login = playbackRequest.channelName?.lowercased() else { return }
        let pin = pinnedChannels.first { $0.login == login }
        let enabled = pin?.notifyEnabled ?? !liveAlertsPinnedOnly
        store.setChannelNotificationState(login: login, enabled: enabled)
    }

    private func currentNotificationEnabled() -> Bool {
        guard let login = playbackRequest.channelName?.lowercased() else { return true }
        let pin = pinnedChannels.first { $0.login == login }
        return pin?.notifyEnabled ?? !liveAlertsPinnedOnly
    }

    private func decodePinnedChannels(from json: String) -> [PinnedChannel] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([PinnedChannel].self, from: data)) ?? []
    }

    private func encodePinnedChannels(_ channels: [PinnedChannel]) -> String {
        guard let data = try? JSONEncoder().encode(channels) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func normalizeChannelLogin(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host?.lowercased(), host.contains("twitch.tv") {
            let parts = url.path.split(separator: "/").map(String.init)
            if let first = parts.first, !first.isEmpty {
                return first.lowercased()
            }
        }

        var value = trimmed.lowercased()
        if value.hasPrefix("@") {
            value.removeFirst()
        }
        if let range = value.range(of: "twitch.tv/") {
            value = String(value[range.upperBound...])
        }
        if let first = value.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first {
            value = String(first)
        }

        return value.isEmpty ? nil : value
    }
}

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
    @Binding var pinnedChannels: [PinnedChannel]
    let pinnedLimit: Int
    @Binding var liveAlertsEnabled: Bool
    var onTogglePin: ((TwitchChannel) -> Void)?
    var onTogglePinNotifications: ((PinnedChannel) -> Void)?
    var onAddPin: ((String) -> Bool)?
    var onRemovePin: ((PinnedChannel) -> Void)?
    var onNavigate: ((URL) -> Void)?
    var onChannelSelected: ((String) -> Void)?
    var onShowSettings: (() -> Void)?
    @State private var isAddingPin = false
    @State private var newPinText = ""
    @State private var pinError: String?

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
                        onShowSettings?()
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
                    // Pinned section
                    HStack {
                        Text("PINNED")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                            .tracking(1)

                        Spacer()

                        Button(action: toggleAddPin) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(pinnedChannels.count >= pinnedLimit ? 0.2 : 0.6))
                        }
                        .buttonStyle(.plain)
                        .disabled(pinnedChannels.count >= pinnedLimit)
                        .help("Add favorite")
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                    if isAddingPin {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("Channel name or URL", text: $newPinText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white)
                                    .onSubmit { submitPin() }

                                Button("Add") { submitPin() }
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.12))
                                    .clipShape(Capsule())
                                    .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.horizontal, 12)

                            if let pinError {
                                Text(pinError)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .padding(.horizontal, 12)
                            }
                        }
                        .padding(.bottom, 6)
                    }

                    if pinnedChannels.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "pin")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("Pin channels from LIVE")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else {
                        ForEach(pinnedChannels) { pin in
                            let liveChannel = liveChannelFor(pin.login)
                            PinnedRow(
                                channel: pin,
                                liveChannel: liveChannel,
                                onOpen: {
                                    if let liveChannel {
                                        onChannelSelected?(liveChannel.login)
                                    } else {
                                        onNavigate?(pin.url) ?? store.navigate(to: pin.url)
                                    }
                                },
                                onRemove: { onRemovePin?(pin) },
                                onToggleNotifications: { onTogglePinNotifications?(pin) }
                            )
                        }
                    }

                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)

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
                            .contextMenu {
                                Button(isPinned(channel) ? "Unpin from Favorites" : "Pin to Favorites") {
                                    onTogglePin?(channel)
                                }
                                .disabled(!isPinned(channel) && pinnedChannels.count >= pinnedLimit)
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

    private func liveChannelFor(_ login: String) -> TwitchChannel? {
        store.followedLive.first { $0.login == login }
    }

    private func isPinned(_ channel: TwitchChannel) -> Bool {
        pinnedChannels.contains { $0.login == channel.login }
    }

    private func toggleAddPin() {
        withAnimation(.easeOut(duration: 0.12)) {
            isAddingPin.toggle()
        }
        if !isAddingPin {
            newPinText = ""
            pinError = nil
        }
    }

    private func submitPin() {
        let trimmed = newPinText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pinError = "Enter a channel name."
            return
        }
        let didAdd = onAddPin?(trimmed) ?? false
        if didAdd {
            newPinText = ""
            pinError = nil
            withAnimation(.easeOut(duration: 0.12)) {
                isAddingPin = false
            }
        } else if pinnedChannels.count >= pinnedLimit {
            pinError = "Favorites limit reached (\(pinnedLimit))."
        } else {
            pinError = "Unable to add this channel."
        }
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

struct PinnedRow: View {
    let channel: PinnedChannel
    let liveChannel: TwitchChannel?
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onToggleNotifications: () -> Void
    @State private var isHovered = false

    private var displayName: String {
        let name = channel.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return channel.login }
        return name
    }

    private var avatarURL: URL? {
        liveChannel?.thumbnailURL ?? channel.thumbnailURL
    }

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Group {
                    if let url = avatarURL {
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

                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? .white : .white.opacity(0.7))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )

            HStack(spacing: 8) {
                Spacer()

                Circle()
                    .fill(liveChannel == nil ? Color.white.opacity(0.2) : Color.red)
                    .frame(width: 8, height: 8)

                Button(action: onToggleNotifications) {
                    Image(systemName: channel.notifyEnabled ? "bell.fill" : "bell.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(channel.notifyEnabled ? Color.yellow.opacity(0.9) : Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help(channel.notifyEnabled ? "Disable notifications" : "Enable notifications")

                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.trailing, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button(channel.notifyEnabled ? "Disable notifications" : "Enable notifications", action: onToggleNotifications)
            Button("Remove from Favorites", action: onRemove)
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

#endif
