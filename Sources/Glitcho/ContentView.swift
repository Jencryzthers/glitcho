#if canImport(SwiftUI)
import SwiftUI
import WebKit

private enum DetailMode {
    case web
    case native
    case recordings
    case settings
}

private struct AutoRecordRetryState {
    let attemptCount: Int
    let nextAttemptAt: Date
}

struct ContentView: View {
    @StateObject private var store = WebViewStore(url: URL(string: "https://www.twitch.tv")!)
    @StateObject private var recordingManager = RecordingManager()
    @StateObject private var backgroundAgentManager = BackgroundRecorderAgentManager()
    @EnvironmentObject private var updateChecker: UpdateChecker
    @Environment(\.notificationManager) private var notificationManager
    @AppStorage("pinnedChannels") private var pinnedChannelsJSON: String = "[]"
    @AppStorage("liveAlertsEnabled") private var liveAlertsEnabled = true
    @AppStorage("liveAlertsPinnedOnly") private var liveAlertsPinnedOnly = false
    @AppStorage("autoRecordOnLive") private var autoRecordOnLive = false
    @AppStorage("autoRecordPinnedOnly") private var autoRecordPinnedOnly = false
    @AppStorage("recordingsDirectory") private var recordingsDirectorySetting = ""
    @AppStorage("streamlinkPath") private var streamlinkPathSetting = ""
    @State private var pinnedChannels: [PinnedChannel] = []
    @State private var hasLoadedPins = false
    @State private var lastLiveLogins: Set<String> = []
    @State private var hasSeenInitialLiveList = false
    @State private var autoRecordedLogins: Set<String> = []
    @State private var autoRecordRetryState: [String: AutoRecordRetryState] = [:]
    @State private var autoRecordSuppressedLogins: Set<String> = []
    @State private var pendingRecoveryIntents: [String: RecordingManager.RecoveryIntent] = [:]
    @State private var hasLoadedRecoveryIntents = false
    @State private var searchText = ""
    @State private var playbackRequest = NativePlaybackRequest(kind: .liveChannel, streamlinkTarget: "twitch.tv", channelName: nil)
    @State private var detailMode: DetailMode = .web
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showSubscriptionPopup = false
    @State private var subscriptionChannel: String?
    @State private var showGiftPopup = false
    @State private var giftChannel: String?
    @State private var showSettings = false
    @State private var showLoadingOverlay = true
    @State private var toastMessage: String? = nil
    @State private var toastIcon: String = "pin.slash"
    private let pinnedLimit = 8
    private let autoRecordEvaluationTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var pendingSyncWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
                .ignoresSafeArea()

            NavigationSplitView(columnVisibility: $columnVisibility) {
                Sidebar(
                    searchText: $searchText,
                    store: store,
                    recordingManager: recordingManager,
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
                        detailMode = .web
                        store.navigate(to: url)
                    },
                    onChannelSelected: { channelName in
                        playbackRequest = NativePlaybackRequest(kind: .liveChannel, streamlinkTarget: "twitch.tv/\(channelName)", channelName: channelName)
                        detailMode = .native
                    },
                    onShowRecordings: {
                        detailMode = .recordings
                    },
                    onShowSettings: {
                        detailMode = .settings
                    },
                    onPinLimitReached: {
                        showToast(message: "You've reached the limit of \(pinnedLimit) favorites! 💜", icon: "heart.fill")
                    }
                )
        .navigationSplitViewColumnWidth(295)
            } detail: {
                Group {
                    switch detailMode {
                    case .native:
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
                            onFollowChannel: { channel in
                                store.followChannel(login: channel)
                            },
                            followedChannels: store.followedLive,
                            notificationEnabled: currentNotificationEnabled(),
                            onNotificationToggle: { enabled in
                                guard let login = playbackRequest.channelName else { return }
                                handleChannelNotificationToggle(ChannelNotificationToggle(login: login, enabled: enabled))
                            },
                            onRecordRequest: {
                                guard playbackRequest.kind == .liveChannel else { return }
                                guard let login = playbackRequest.channelName?.lowercased() else { return }

                                if recordingManager.isRecordingInBackgroundAgent(channelLogin: login) {
                                    // Stop manual recording via background agent
                                    backgroundAgentManager.removeManualRecording(login: login)
                                    scheduleSyncBackgroundRecordingAgent()
                                    autoRecordSuppressedLogins.insert(login)
                                    autoRecordRetryState.removeValue(forKey: login)
                                } else {
                                    // Start manual recording via background agent
                                    let displayName = playbackRequest.channelName ?? login
                                    backgroundAgentManager.addManualRecording(login: login, displayName: displayName)
                                    scheduleSyncBackgroundRecordingAgent()
                                    autoRecordSuppressedLogins.remove(login)
                                    autoRecordRetryState.removeValue(forKey: login)
                                }
                            }
                        )
                    case .recordings:
                        RecordingsLibraryView(recordingManager: recordingManager)
                    case .settings:
                        SettingsDetailView(
                            recordingManager: recordingManager,
                            onOpenTwitchSettings: {
                                detailMode = .web
                                store.navigate(to: URL(string: "https://www.twitch.tv/settings")!)
                            }
                        )
                        .environment(\.notificationManager, notificationManager)
                    case .web:
                        WebViewContainer(webView: store.webView)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(12)
            }
            .navigationSplitViewStyle(.prominentDetail)
            .onChange(of: store.shouldSwitchToNativePlayback) { request in
                if let request {
                    if detailMode == .native, playbackRequest == request {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            store.shouldSwitchToNativePlayback = nil
                        }
                        return
                    }
                    store.prepareWebViewForNativePlayer()
                    playbackRequest = request
                    detailMode = .native
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

            if recordingManager.isAnyRecordingIncludingBackground() {
                RecordingStatusBadge(
                    channel: recordingManager.recordingBadgeChannelIncludingBackground(),
                    count: recordingManager.recordingCountIncludingBackground()
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                    .zIndex(2)
                    .allowsHitTesting(false)
            }

            if showLoadingOverlay {
                LoadingOverlay()
                    .zIndex(100)
                    .transition(.opacity)
            }

            // Toast notification
            if let message = toastMessage {
                ToastView(message: message, icon: toastIcon)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(200)
            }
        }
        .task {
            await updateChecker.checkForUpdates()
        }
        .onChange(of: store.isLoading) { isLoading in
            if !isLoading && showLoadingOverlay {
                withAnimation(.easeOut(duration: 0.4)) {
                    showLoadingOverlay = false
                }
            }
        }
        .task {
            loadPinnedChannelsIfNeeded()
        }
        .task {
            loadRecoveryIntentsIfNeeded()
        }
    .task {
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: pinnedChannels) { newValue in
            savePinnedChannels(newValue)
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: store.followedLive) { newValue in
            refreshPinnedMetadata(using: newValue)
            handleFollowedLiveChange(newValue)
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: store.followedChannelLogins) { _ in
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: store.channelNotificationToggle) { request in
            guard let request else { return }
            handleChannelNotificationToggle(request)
            store.channelNotificationToggle = nil
        }
        .onChange(of: store.channelPinRequest) { request in
            guard let request else { return }
            handleChannelPinRequest(request)
            store.channelPinRequest = nil
        }
        .onChange(of: liveAlertsEnabled) { isEnabled in
            if isEnabled, let notificationManager {
                Task { _ = await notificationManager.requestAuthorization() }
            }
        }
        .onChange(of: autoRecordOnLive) { _ in
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: autoRecordPinnedOnly) { _ in
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: recordingsDirectorySetting) { _ in
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: streamlinkPathSetting) { _ in
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: store.isLoggedIn) { _ in
            scheduleSyncBackgroundRecordingAgent()
        }
        .onChange(of: playbackRequest) { _ in
            updateChannelBellStateIfNeeded()
        }
        .onReceive(autoRecordEvaluationTimer) { _ in
            guard store.isLoggedIn, autoRecordOnLive || !pendingRecoveryIntents.isEmpty else { return }
            handleFollowedLiveChange(store.followedLive)
        }
    }

    private func showToast(message: String, icon: String = "info.circle.fill") {
        toastIcon = icon
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                toastMessage = nil
            }
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
        guard store.isLoggedIn else {
            lastLiveLogins = []
            hasSeenInitialLiveList = false
            autoRecordedLogins = []
            autoRecordRetryState = [:]
            autoRecordSuppressedLogins = []
            return
        }

        let now = Date()
        let isChannelAlreadyRecording: (String) -> Bool = { login in
            recordingManager.isRecording(channelLogin: login)
                || recordingManager.isRecordingInBackgroundAgent(channelLogin: login)
        }
        let currentLogins = Set(liveChannels.map { $0.login.lowercased() })
        autoRecordSuppressedLogins.formIntersection(currentLogins)
        autoRecordRetryState = autoRecordRetryState.filter { currentLogins.contains($0.key) }
        autoRecordedLogins = Set(
            autoRecordedLogins.filter { login in
                guard currentLogins.contains(login) else { return false }
                if autoRecordSuppressedLogins.contains(login) { return true }
                return isChannelAlreadyRecording(login)
            }
        )
        defer {
            lastLiveLogins = currentLogins
            hasSeenInitialLiveList = true
        }

        let newlyLive = currentLogins.subtracting(lastLiveLogins)

        let channelMap = Dictionary(liveChannels.map { ($0.login.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let pinMap = Dictionary(pinnedChannels.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })

        if hasSeenInitialLiveList, liveAlertsEnabled, let notificationManager {
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

        for login in currentLogins {
            if isChannelAlreadyRecording(login) {
                autoRecordedLogins.insert(login)
                clearAutoRecordRetry(for: login)
            }
        }

        // Recovery path: channels that were recording before restart/crash.
        let recoveryCandidates = currentLogins.intersection(pendingRecoveryIntents.keys)
        for login in recoveryCandidates.sorted() {
            guard !isChannelAlreadyRecording(login) else {
                pendingRecoveryIntents.removeValue(forKey: login)
                autoRecordedLogins.insert(login)
                clearAutoRecordRetry(for: login)
                continue
            }
            guard shouldAttemptAutoRecord(for: login, now: now) else { continue }

            let intent = pendingRecoveryIntents[login]
            let channel = channelMap[login]
            let target = intent?.target ?? "twitch.tv/\(login)"
            let channelName = channel?.name ?? intent?.channelName ?? login
            let quality = intent?.quality ?? "best"

            let started = recordingManager.startRecording(
                target: target,
                channelName: channelName,
                quality: quality
            )
            if started {
                recordingManager.clearPendingRecoveryIntent(channelLogin: login)
                pendingRecoveryIntents.removeValue(forKey: login)
                autoRecordSuppressedLogins.remove(login)
                autoRecordedLogins.insert(login)
                clearAutoRecordRetry(for: login)
            } else {
                registerAutoRecordFailure(for: login, now: now)
            }
        }

        guard autoRecordOnLive else { return }

        let baseAutoCandidates = hasSeenInitialLiveList ? newlyLive : currentLogins
        let retryCandidates = Set(
            currentLogins.filter { login in
                if autoRecordRetryState[login] != nil { return true }
                if autoRecordedLogins.contains(login) && !isChannelAlreadyRecording(login) {
                    return true
                }
                return false
            }
        )
        let autoRecordCandidates = baseAutoCandidates.union(retryCandidates)

        let eligibleLogins = autoRecordCandidates.filter { login in
            guard channelMap[login] != nil else { return false }
            guard !autoRecordSuppressedLogins.contains(login) else { return false }
            if autoRecordPinnedOnly {
                guard let pin = pinMap[login], pin.notifyEnabled else { return false }
            }
            return true
        }

        for targetLogin in eligibleLogins.sorted() {
            guard !isChannelAlreadyRecording(targetLogin) else {
                autoRecordedLogins.insert(targetLogin)
                clearAutoRecordRetry(for: targetLogin)
                continue
            }
            guard shouldAttemptAutoRecord(for: targetLogin, now: now) else { continue }
            guard let channel = channelMap[targetLogin] else { continue }

            let started = recordingManager.startRecording(
                target: "twitch.tv/\(targetLogin)",
                channelName: channel.name
            )
            if started {
                autoRecordedLogins.insert(targetLogin)
                autoRecordSuppressedLogins.remove(targetLogin)
                clearAutoRecordRetry(for: targetLogin)
            } else {
                autoRecordedLogins.remove(targetLogin)
                registerAutoRecordFailure(for: targetLogin, now: now)
            }
        }
    }

    private func loadRecoveryIntentsIfNeeded() {
        guard !hasLoadedRecoveryIntents else { return }
        hasLoadedRecoveryIntents = true

        let intents = recordingManager.consumeRecoveryIntents()
        guard !intents.isEmpty else { return }

        var recovered: [String: RecordingManager.RecoveryIntent] = [:]
        for intent in intents {
            let trimmedLogin = intent.channelLogin?.trimmingCharacters(in: .whitespacesAndNewlines)
            let login = (trimmedLogin?.isEmpty == false ? trimmedLogin : nil) ?? normalizeChannelLogin(intent.target)
            if let login {
                recovered[login.lowercased()] = intent
            } else {
                _ = recordingManager.startRecording(
                    target: intent.target,
                    channelName: intent.channelName,
                    quality: intent.quality
                )
            }
        }

        pendingRecoveryIntents = recovered
        if !store.followedLive.isEmpty {
            handleFollowedLiveChange(store.followedLive)
        }
    }

    private func shouldAttemptAutoRecord(for login: String, now: Date) -> Bool {
        guard let retry = autoRecordRetryState[login] else { return true }
        return now >= retry.nextAttemptAt
    }

    private func clearAutoRecordRetry(for login: String) {
        autoRecordRetryState.removeValue(forKey: login)
    }

    private func registerAutoRecordFailure(for login: String, now: Date) {
        let currentAttempt = autoRecordRetryState[login]?.attemptCount ?? 0
        let nextAttempt = min(currentAttempt + 1, 8)
        let delay = min(pow(2, Double(max(nextAttempt - 1, 0))) * 10, 300)
        autoRecordRetryState[login] = AutoRecordRetryState(
            attemptCount: nextAttempt,
            nextAttemptAt: now.addingTimeInterval(delay)
        )
    }

    private func scheduleSyncBackgroundRecordingAgent() {
        pendingSyncWork?.cancel()
        let work = DispatchWorkItem { [self] in
            let channels = backgroundAgentChannels()
            let streamlinkPath = recordingManager.streamlinkPathForBackgroundAgent()
            let recordingsDirectory = recordingManager.recordingsDirectory().path

            backgroundAgentManager.sync(
                enabled: autoRecordOnLive,
                channels: channels,
                streamlinkPath: streamlinkPath,
                recordingsDirectory: recordingsDirectory,
                quality: "best"
            )
        }
        pendingSyncWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func backgroundAgentChannels() -> [BackgroundRecorderAgentChannel] {
        let liveByLogin = Dictionary(
            store.followedLive.map { ($0.login.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pinnedByLogin = Dictionary(
            pinnedChannels.map { ($0.login.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var candidateLogins: Set<String>
        if autoRecordPinnedOnly {
            candidateLogins = Set(
                pinnedChannels
                    .filter { $0.notifyEnabled }
                    .map { $0.login.lowercased() }
            )
        } else {
            let followed = Set(store.followedChannelLogins.map { $0.lowercased() })
            if !followed.isEmpty {
                candidateLogins = followed
            } else {
                candidateLogins = Set(store.followedLive.map { $0.login.lowercased() })
            }

            // Keep pinned channels in the background set as a fallback when followed lists are stale.
            candidateLogins.formUnion(pinnedChannels.map { $0.login.lowercased() })
        }

        return candidateLogins
            .sorted()
            .map { login in
                let displayName =
                    liveByLogin[login]?.name
                    ?? pinnedByLogin[login]?.displayName
                    ?? login
                return BackgroundRecorderAgentChannel(login: login, displayName: displayName)
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

    private func handleChannelPinRequest(_ request: ChannelPinRequest) {
        let normalizedLogin = request.login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedLogin.isEmpty else { return }

        let preferredName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = preferredName.isEmpty ? normalizedLogin : preferredName
        _ = addPinned(login: normalizedLogin, displayName: displayName, thumbnailURL: nil)
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

private struct RecordingStatusBadge: View {
    let channel: String?
    let count: Int

    private var suffix: String {
        if count > 1 {
            return " • \(count) channels"
        }
        return channel.map { " • \($0)" } ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text("Recording\(suffix)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
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
    @ObservedObject var recordingManager: RecordingManager
    @Binding var pinnedChannels: [PinnedChannel]
    let pinnedLimit: Int
    @Binding var liveAlertsEnabled: Bool
    @AppStorage(SidebarTint.storageKey) private var sidebarTintHex = SidebarTint.defaultHex
    var onTogglePin: ((TwitchChannel) -> Void)?
    var onTogglePinNotifications: ((PinnedChannel) -> Void)?
    var onAddPin: ((String) -> Bool)?
    var onRemovePin: ((PinnedChannel) -> Void)?
    var onNavigate: ((URL) -> Void)?
    var onChannelSelected: ((String) -> Void)?
    var onShowRecordings: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onPinLimitReached: (() -> Void)?
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
    private var sidebarTint: Color {
        SidebarTint.color(from: sidebarTintHex)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with logo and account
            HStack(spacing: 12) {
                Button {
                    if store.isLoggedIn {
                        let url = URL(string: "https://www.twitch.tv/settings")!
                        onNavigate?(url) ?? store.navigate(to: url)
                    }
                } label: {
                    AvatarView(url: store.profileAvatarURL, isLoggedIn: store.isLoggedIn, size: 36)
                }
                .buttonStyle(.plain)
                .disabled(!store.isLoggedIn)

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
                    ForEach(sections) { destination in
                        SidebarRow(
                            title: destination.title,
                            systemImage: destination.icon
                        ) {
                            onNavigate?(destination.url) ?? store.navigate(to: destination.url)
                        }
                    }

                    SidebarRow(
                        title: "Recordings",
                        systemImage: "record.circle"
                    ) {
                        onShowRecordings?()
                    }

                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)

                    // Pinned section
                    let pinnedLogins = Set(pinnedChannels.map(\.login))
                    HStack {
                        Text("PINNED")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                            .tracking(1)

                        Spacer()

                        Button(action: {
                            if pinnedChannels.count >= pinnedLimit {
                                onPinLimitReached?()
                            } else {
                                toggleAddPin()
                            }
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(pinnedChannels.count >= pinnedLimit ? 0.2 : 0.6))
                        }
                        .buttonStyle(.plain)
                        .help(pinnedChannels.count >= pinnedLimit ? "Favorites limit reached" : "Add favorite")
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
                        let liveByLogin = Dictionary(store.followedLive.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
                        ForEach(pinnedChannels) { pin in
                            let liveChannel = liveByLogin[pin.login]
                            let isRecording = recordingManager.isRecordingAny(channelLogin: pin.login)
                            PinnedRow(
                                channel: pin,
                                liveChannel: liveChannel,
                                isRecording: isRecording,
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

                    // Following section
                    Text("Following (Live)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(1)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)

                    let nonPinnedLive = store.followedLive.filter { !pinnedLogins.contains($0.login) }

                    if nonPinnedLive.isEmpty {
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
                        ForEach(nonPinnedLive) { channel in
                            FollowingRow(
                                channel: channel,
                                isRecording: recordingManager.isRecordingAny(channelLogin: channel.login)
                            ) {
                                let channelName = channel.url.lastPathComponent
                                onChannelSelected?(channelName)
                            }
                            .contextMenu {
                                Button(pinnedLogins.contains(channel.login) ? "Unpin from Favorites" : "Pin to Favorites") {
                                    if !pinnedLogins.contains(channel.login) && pinnedChannels.count >= pinnedLimit {
                                        onPinLimitReached?()
                                    } else {
                                        onTogglePin?(channel)
                                    }
                                }
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
                sidebarTint.opacity(0.25)
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
        if pinnedChannels.count >= pinnedLimit {
            onPinLimitReached?()
            withAnimation(.easeOut(duration: 0.12)) {
                isAddingPin = false
            }
            newPinText = ""
            pinError = nil
            return
        }
        let didAdd = onAddPin?(trimmed) ?? false
        if didAdd {
            newPinText = ""
            pinError = nil
            withAnimation(.easeOut(duration: 0.12)) {
                isAddingPin = false
            }
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
    let isRecording: Bool
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

                if isRecording {
                    Text("REC")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.85))
                        )
                }

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
    let isRecording: Bool
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

                if isRecording {
                    Text("REC")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.85))
                        )
                }

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

struct ToastView: View {
    let message: String
    let icon: String

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.purple, Color.pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.15), Color.pink.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.4), Color.pink.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.purple.opacity(0.3), radius: 20, x: 0, y: 8)

            Spacer()
        }
        .padding(.top, 20)
    }
}

struct LoadingOverlay: View {
    @State private var pulseScale: CGFloat = 0.95
    @State private var glowOpacity: Double = 0.4
    @State private var dotOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Dark background
            Color(red: 0.04, green: 0.04, blue: 0.06)
                .ignoresSafeArea()

            // Animated purple glow
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.purple.opacity(0.3),
                            Color.purple.opacity(0.1),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: 50,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .scaleEffect(pulseScale)
                .opacity(glowOpacity)

            VStack(spacing: 24) {
                // App icon / logo area
                ZStack {
                    // Outer glow ring
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.6), Color.purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 100, height: 100)
                        .scaleEffect(pulseScale)

                    // App icon from dock
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }

                // App name
                Text("Glitcho")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Loading indicator
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.purple.opacity(0.8))
                            .frame(width: 8, height: 8)
                            .scaleEffect(dotOffset == CGFloat(index) ? 1.3 : 0.8)
                            .animation(
                                .easeInOut(duration: 0.4)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.15),
                                value: dotOffset
                            )
                    }
                }
                .padding(.top, 8)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseScale = 1.05
                glowOpacity = 0.6
            }
            dotOffset = 2
        }
    }
}

#endif
