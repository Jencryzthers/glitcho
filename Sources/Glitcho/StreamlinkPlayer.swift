import Foundation
import AppKit
import AVKit
import SwiftUI
import WebKit

/// Gestionnaire Streamlink pour extraire les URLs de stream
class StreamlinkManager: ObservableObject {
    @Published var isLoading = false
    @Published var error: String?
    @Published var streamURL: URL?
    
    private var process: Process?
    
    func getStreamURL(for channel: String, quality: String = "best") async throws -> URL {
        return try await getStreamURL(target: "twitch.tv/\(channel)", quality: quality)
    }

    func getStreamURL(target: String, quality: String = "best") async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                let errorPipe = Pipe()
                
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/streamlink")
                let resolvedTarget: String = {
                    let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.hasPrefix("http://") || t.hasPrefix("https://") { return t }
                    return "https://\(t)"
                }()
                process.arguments = [
                    resolvedTarget,
                    quality,
                    "--stream-url",
                    "--twitch-disable-ads",
                    "--twitch-low-latency"
                ]
                
                process.standardOutput = pipe
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    
                    if process.terminationStatus == 0, let url = URL(string: output) {
                        print("[Streamlink] Got stream URL: \(url)")
                        continuation.resume(returning: url)
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        print("[Streamlink] Error: \(errorOutput)")
                        continuation.resume(throwing: NSError(
                            domain: "StreamlinkError",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: errorOutput]
                        ))
                    }
                } catch {
                    print("[Streamlink] Failed to run: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func stopStream() {
        process?.terminate()
        process = nil
    }
}

/// Vue player vidéo natif avec AVPlayer
struct NativeVideoPlayer: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    let pipController: PictureInPictureController?

    init(url: URL, isPlaying: Binding<Bool>, pipController: PictureInPictureController? = nil) {
        self.url = url
        self._isPlaying = isPlaying
        self.pipController = pipController
    }
    
    final class Coordinator {
        var endObserver: Any?
        let pipController: PictureInPictureController?
        
        init(pipController: PictureInPictureController?) {
            self.pipController = pipController
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(pipController: pipController) }
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.showsFrameSteppingButtons = false
        playerView.showsFullScreenToggleButton = true
        
        let player = AVPlayer(url: url)
        playerView.player = player
        
        // Auto-play
        if isPlaying {
            player.play()
        }
        
        // Observer pour détecter la fin
        context.coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            if isPlaying {
                player.play()
            }
        }
        
        context.coordinator.pipController?.attach(playerView)
        return playerView
    }
    
    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if let current = playerView.player?.currentItem?.asset as? AVURLAsset, current.url != url {
            playerView.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        if isPlaying {
            playerView.player?.play()
        } else {
            playerView.player?.pause()
        }
        context.coordinator.pipController?.attach(playerView)
    }
    
    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        if let token = coordinator.endObserver {
            NotificationCenter.default.removeObserver(token)
            coordinator.endObserver = nil
        }
        playerView.player?.pause()
        playerView.player = nil
        coordinator.pipController?.detach(playerView)
    }
}

/// Vue pour l'intégration dans l'interface principale
struct StreamlinkPlayerView: View {
    let channelName: String
    @StateObject private var streamlink = StreamlinkManager()
    @StateObject private var pipController = PictureInPictureController()
    @State private var streamURL: URL?
    @State private var isPlaying = true
    @State private var showError = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Player vidéo natif
            if let url = streamURL {
                NativeVideoPlayer(url: url, isPlaying: $isPlaying, pipController: pipController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if streamlink.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Chargement du stream...")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Streamlink bloque les publicités")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.white.opacity(0.5))
                    Text(channelName)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Cliquez pour charger le stream")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.7))
                    Button("Charger avec Streamlink") {
                        Task {
                            await loadStream()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
            
            // Barre de contrôles
            HStack {
                Button(action: { isPlaying.toggle() }) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(channelName)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Player natif • Sans publicités")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
                
                if pipController.isAvailable {
                    Button(action: { pipController.toggle() }) {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Picture in Picture")
                }

                Button("Recharger") {
                    Task {
                        await loadStream()
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white.opacity(0.9))
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.9),
                        Color.black.opacity(0.7)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .alert("Erreur de chargement", isPresented: $showError) {
            Button("Réessayer") { 
                Task { await loadStream() }
            }
            Button("Annuler", role: .cancel) { showError = false }
        } message: {
            Text(streamlink.error ?? "Impossible de charger le stream")
        }
        .onChange(of: channelName) { _ in
            // Recharger quand la chaîne change
            Task {
                await loadStream()
            }
        }
        .onDisappear {
            isPlaying = false
        }
        .task {
            await loadStream()
        }
    }
    
    private func loadStream() async {
        streamlink.isLoading = true
        streamURL = nil
        do {
            let url = try await streamlink.getStreamURL(for: channelName)
            await MainActor.run {
                self.streamURL = url
                streamlink.isLoading = false
            }
        } catch {
            await MainActor.run {
                streamlink.error = error.localizedDescription
                streamlink.isLoading = false
                showError = true
            }
        }
    }
}

/// Vue hybride : Player natif + Chat + Infos de la chaîne
struct HybridTwitchView: View {
    @Binding var playback: NativePlaybackRequest
    var onOpenSubscription: ((String) -> Void)?
    var onOpenGiftSub: ((String) -> Void)?
    var notificationEnabled: Bool = true
    var onNotificationToggle: ((Bool) -> Void)?
    var onRecordRequest: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @StateObject private var streamlink = StreamlinkManager()
    @StateObject private var pipController = PictureInPictureController()
    @State private var streamURL: URL?
    @State private var isPlaying = true
    @State private var showError = false
    @State private var showChat = true
    @State private var isChatDetached = false
    @State private var detachedChannelName: String?
    @State private var programmaticChatCloseChannel: String?
    @AppStorage("hybridPlayerHeightRatio") private var playerHeightRatio: Double = 0.8
    @State private var dragStartRatio: Double?
    @State private var lastChannelName: String?

    private enum ChatDisplayMode: String {
        case inline
        case hidden
        case detached
    }

    private static let chatPreferencesKey = "glitcho.chatPreferencesByChannel"
    
    var body: some View {
        HStack(spacing: 0) {
            // Colonne principale : Player + Infos
            GeometryReader { geo in
                let minPlayerHeight: CGFloat = 280
                let minAboutHeight: CGFloat = 160
                let maxPlayerHeight = max(geo.size.height - minAboutHeight, minPlayerHeight)
                let desiredPlayerHeight = CGFloat(playerHeightRatio) * geo.size.height
                let playerHeight = min(max(desiredPlayerHeight, minPlayerHeight), maxPlayerHeight)
                VStack(spacing: 0) {
                    // Player vidéo natif (≥ 80% de la hauteur)
                    VStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            Group {
                                if let url = streamURL {
                                    NativeVideoPlayer(url: url, isPlaying: $isPlaying, pipController: pipController)
                                } else if streamlink.isLoading {
                                    VStack(spacing: 12) {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                            .tint(.white.opacity(0.6))
                                        Text("Loading stream...")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                } else {
                                    VStack(spacing: 16) {
                                        Image(systemName: "play.circle")
                                            .font(.system(size: 48, weight: .thin))
                                            .foregroundColor(.white.opacity(0.3))
                                        Button(action: { Task { await loadStream() } }) {
                                            Text("Load Stream")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .background(Color.white.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(red: 0.04, green: 0.04, blue: 0.05))

                            // Contrôles
                            HStack(spacing: 16) {
                                Button(action: { isPlaying.toggle() }) {
                                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .buttonStyle(.plain)

                                Text(playback.channelName ?? "Stream")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))

                                Spacer()

                                if playback.kind == .liveChannel, let channel = playback.channelName {
                                    if !isChatDetached {
                                        Button(action: { toggleChatVisibility(channel: channel) }) {
                                            Image(systemName: "sidebar.right")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.white.opacity(showChat ? 0.8 : 0.4))
                                        }
                                        .buttonStyle(.plain)
                                        .help(showChat ? "Hide chat" : "Show chat")
                                    }

                                    Button(action: { isChatDetached ? attachChat() : detachChat(channel) }) {
                                        Image(systemName: isChatDetached ? "rectangle.on.rectangle" : "arrow.up.right.square")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .help(isChatDetached ? "Attach chat" : "Detach chat")
                                }

                                if pipController.isAvailable {
                                    Button(action: { pipController.toggle() }) {
                                        Image(systemName: "pip.enter")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Picture in Picture")
                                }

                                Button(action: { Task { await loadStream() } }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                                .help("Reload stream")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [Color.black.opacity(0), Color.black.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        }
                        .frame(height: playerHeight)
                        .layoutPriority(2)
                    }

                    ResizeHandle()
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let start = dragStartRatio ?? playerHeightRatio
                                    dragStartRatio = start

                                    let nextHeight = (CGFloat(start) * geo.size.height) + value.translation.height
                                    let unclamped = Double(nextHeight / geo.size.height)
                                    let minRatio = Double(minPlayerHeight / geo.size.height)
                                    let maxRatio = Double(maxPlayerHeight / geo.size.height)
                                    playerHeightRatio = min(max(unclamped, minRatio), maxRatio)
                                }
                                .onEnded { _ in
                                    dragStartRatio = nil
                                }
                        )

                    if let channel = playback.channelName {
                        // Vue "section du bas" Twitch (About/Schedule/Videos) sans player/chat.
                        // Intercepte les clips/VODs pour ne changer que le flux du player natif.
                        ChannelInfoView(
                            channelName: channel,
                            onOpenSubscription: { onOpenSubscription?(channel) },
                            onOpenGiftSub: { onOpenGiftSub?(channel) },
                            onSelectPlayback: { request in
                                playback = request
                            },
                            notificationEnabled: notificationEnabled,
                            onNotificationToggle: { enabled in
                                onNotificationToggle?(enabled)
                            },
                            onRecordRequest: {
                                onRecordRequest?()
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            
            // Chat
            if playback.kind == .liveChannel, let channel = playback.channelName, showChat, !isChatDetached {
                TwitchChatView(channelName: channel)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .alert("Erreur", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(streamlink.error ?? "Erreur inconnue")
        }
        .onAppear {
            lastChannelName = playback.channelName
            if playback.kind == .liveChannel, let channel = playback.channelName {
                applyChatPreference(for: channel)
            } else {
                showChat = false
            }
        }
        .onChange(of: playback) { newValue in
            // Mettre à jour le player sans "ouvrir Twitch" en bas:
            // on remplace uniquement la source streamlinkTarget.
            Task { await loadStream() }

            // Si on change de chaîne, reset les onglets du bas.
            if newValue.channelName != lastChannelName {
                lastChannelName = newValue.channelName
                if newValue.kind == .liveChannel, let channel = newValue.channelName {
                    applyChatPreference(for: channel)
                } else {
                    showChat = false
                    closeDetachedChat()
                }
            } else {
                // Si on passe clip/vod, on coupe le chat.
                if newValue.kind != .liveChannel {
                    showChat = false
                    closeDetachedChat()
                }
            }
        }
        .task {
            await loadStream()
        }
        .onDisappear {
            // Important: stopper le player natif quand on quitte la vue (navigation ailleurs)
            isPlaying = false
            streamURL = nil
            closeDetachedChat()
        }
        .onReceive(NotificationCenter.default.publisher(for: .detachedChatAttachRequested)) { notification in
            guard let channel = notification.userInfo?["channel"] as? String else { return }
            guard channel == playback.channelName else { return }
            isChatDetached = false
            detachedChannelName = nil
            showChat = true
            setChatPreference(.inline, for: channel)
            programmaticChatCloseChannel = channel
        }
        .onReceive(NotificationCenter.default.publisher(for: .detachedChatDidClose)) { notification in
            guard let channel = notification.userInfo?["channel"] as? String else { return }
            if programmaticChatCloseChannel == channel {
                programmaticChatCloseChannel = nil
            } else {
                setChatPreference(.hidden, for: channel)
            }
            if channel == detachedChannelName {
                isChatDetached = false
                detachedChannelName = nil
                showChat = false
            }
        }
    }
    
    private func loadStream() async {
        streamlink.isLoading = true
        do {
            let url = try await streamlink.getStreamURL(target: playback.streamlinkTarget)
            await MainActor.run {
                self.streamURL = url
                streamlink.isLoading = false
            }
        } catch {
            await MainActor.run {
                streamlink.error = error.localizedDescription
                streamlink.isLoading = false
                showError = true
            }
        }
    }

    private func detachChat(_ channel: String) {
        if let current = detachedChannelName {
            programmaticChatCloseChannel = current
            NotificationCenter.default.post(name: .detachedChatShouldClose, object: nil, userInfo: ["channel": current])
        } else {
            NotificationCenter.default.post(name: .detachedChatShouldClose, object: nil)
        }
        detachedChannelName = channel
        isChatDetached = true
        showChat = false
        setChatPreference(.detached, for: channel)
        openWindow(id: "chat", value: ChatWindowContext(channelName: channel))
    }

    private func attachChat() {
        isChatDetached = false
        detachedChannelName = nil
        showChat = true
        if let channel = playback.channelName {
            setChatPreference(.inline, for: channel)
            programmaticChatCloseChannel = channel
            NotificationCenter.default.post(name: .detachedChatShouldClose, object: nil, userInfo: ["channel": channel])
        } else {
            NotificationCenter.default.post(name: .detachedChatShouldClose, object: nil)
        }
    }

    private func closeDetachedChat() {
        guard isChatDetached else { return }
        if let current = detachedChannelName {
            programmaticChatCloseChannel = current
            NotificationCenter.default.post(name: .detachedChatShouldClose, object: nil, userInfo: ["channel": current])
        } else {
            NotificationCenter.default.post(name: .detachedChatShouldClose, object: nil)
        }
        isChatDetached = false
        detachedChannelName = nil
    }

    private func toggleChatVisibility(channel: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            showChat.toggle()
        }
        setChatPreference(showChat ? .inline : .hidden, for: channel)
    }

    private func applyChatPreference(for channel: String) {
        let mode = chatPreference(for: channel) ?? .inline
        switch mode {
        case .inline:
            if isChatDetached {
                closeDetachedChat()
            }
            showChat = true
        case .hidden:
            showChat = false
            if isChatDetached {
                closeDetachedChat()
            }
        case .detached:
            if detachedChannelName != channel || !isChatDetached {
                detachChat(channel)
            }
        }
    }

    private func chatPreference(for channel: String) -> ChatDisplayMode? {
        let key = channel.lowercased()
        let stored = UserDefaults.standard.dictionary(forKey: Self.chatPreferencesKey) as? [String: String] ?? [:]
        guard let raw = stored[key] else { return nil }
        return ChatDisplayMode(rawValue: raw)
    }

    private func setChatPreference(_ mode: ChatDisplayMode, for channel: String) {
        let key = channel.lowercased()
        var stored = UserDefaults.standard.dictionary(forKey: Self.chatPreferencesKey) as? [String: String] ?? [:]
        stored[key] = mode.rawValue
        UserDefaults.standard.set(stored, forKey: Self.chatPreferencesKey)
    }
    
}

private struct ResizeHandle: View {
    @State private var cursorPushed = false
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(isHovered ? 0.08 : 0.04))
            .frame(height: 6)
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(isHovered ? 0.3 : 0.15))
                    .frame(width: 32, height: 3)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) { isHovered = hovering }
                if hovering && !cursorPushed {
                    NSCursor.resizeUpDown.push()
                    cursorPushed = true
                } else if !hovering && cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
    }
}

// Chat Twitch (iframe embed officiel)
struct TwitchChatView: NSViewRepresentable {
    let channelName: String
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        
        // Chat embed officiel Twitch
        let chatURL = URL(string: "https://www.twitch.tv/embed/\(channelName)/chat?parent=localhost&darkpopout")!
        webView.load(URLRequest(url: chatURL))
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Reload if channel changed
        let chatURL = URL(string: "https://www.twitch.tv/embed/\(channelName)/chat?parent=localhost&darkpopout")!
        if nsView.url?.host != chatURL.host || !(nsView.url?.absoluteString.contains("/embed/\(channelName)/chat") ?? false) {
            nsView.load(URLRequest(url: chatURL))
        }
    }
}

// Infos de la chaîne (About, panels, etc.) via page Twitch
struct ChannelInfoView: NSViewRepresentable {
    let channelName: String
    let onOpenSubscription: () -> Void
    let onOpenGiftSub: () -> Void
    let onSelectPlayback: (NativePlaybackRequest) -> Void
    let notificationEnabled: Bool
    let onNotificationToggle: (Bool) -> Void
    let onRecordRequest: () -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onOpenSubscription: () -> Void
        let onOpenGiftSub: () -> Void
        let channelName: String
        let onSelectPlayback: (NativePlaybackRequest) -> Void
        let onNotificationToggle: (Bool) -> Void
        let onRecordRequest: () -> Void

        init(channelName: String, onOpenSubscription: @escaping () -> Void, onOpenGiftSub: @escaping () -> Void, onSelectPlayback: @escaping (NativePlaybackRequest) -> Void, onNotificationToggle: @escaping (Bool) -> Void, onRecordRequest: @escaping () -> Void) {
            self.channelName = channelName
            self.onOpenSubscription = onOpenSubscription
            self.onOpenGiftSub = onOpenGiftSub
            self.onSelectPlayback = onSelectPlayback
            self.onNotificationToggle = onNotificationToggle
            self.onRecordRequest = onRecordRequest
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "openSubscription":
                DispatchQueue.main.async { self.onOpenSubscription() }
            case "openGiftSub":
                DispatchQueue.main.async { self.onOpenGiftSub() }
            case "channelNotification":
                if let dict = message.body as? [String: Any],
                   let enabledValue = dict["enabled"] {
                    let enabled: Bool
                    if let boolVal = enabledValue as? Bool {
                        enabled = boolVal
                    } else if let strVal = enabledValue as? String {
                        enabled = strVal.lowercased() == "true"
                    } else {
                        enabled = true
                    }
                    DispatchQueue.main.async { self.onNotificationToggle(enabled) }
                }
            default:
                return
            }
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

            if let request = nativePlaybackRequest(url: url) {
                DispatchQueue.main.async {
                    self.onSelectPlayback(request)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func nativePlaybackRequest(url: URL) -> NativePlaybackRequest? {
            let host = (url.host ?? "").lowercased()

            if host == "clips.twitch.tv" {
                return NativePlaybackRequest(kind: .clip, streamlinkTarget: url.absoluteString, channelName: channelName)
            }

            guard host.hasSuffix("twitch.tv") else { return nil }

            let parts = url.path.split(separator: "/").map(String.init)
            guard let first = parts.first else { return nil }

            if first.lowercased() == "videos", parts.count >= 2, parts[1].allSatisfy({ $0.isNumber }) {
                return NativePlaybackRequest(kind: .vod, streamlinkTarget: url.absoluteString, channelName: channelName)
            }

            if first.lowercased() == "clip", parts.count >= 2 {
                return NativePlaybackRequest(kind: .clip, streamlinkTarget: url.absoluteString, channelName: channelName)
            }
            if parts.count >= 3, parts[1].lowercased() == "clip" {
                return NativePlaybackRequest(kind: .clip, streamlinkTarget: url.absoluteString, channelName: channelName)
            }

            return nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            channelName: channelName,
            onOpenSubscription: onOpenSubscription,
            onOpenGiftSub: onOpenGiftSub,
            onSelectPlayback: onSelectPlayback,
            onNotificationToggle: onNotificationToggle,
            onRecordRequest: onRecordRequest
        )
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Empêcher l'auto-play dans la WebView "About" (sinon audio/vidéo en background sans contrôles).
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        contentController.add(context.coordinator, name: "openSubscription")
        contentController.add(context.coordinator, name: "openGiftSub")
        contentController.add(context.coordinator, name: "channelNotification")
        
        let blockMediaScript = WKUserScript(
            source: """
            (function() {
              if (window.__glitcho_block_media) { return; }
              window.__glitcho_block_media = true;

              function pauseAll() {
                try {
                  document.querySelectorAll('video,audio').forEach(el => {
                    try { el.pause(); } catch (e) {}
                    try { el.muted = true; } catch (e) {}
                    try { el.volume = 0; } catch (e) {}
                    try { el.removeAttribute('autoplay'); } catch (e) {}
                  });
                } catch (e) {}
              }

              // Empêcher les play() programmatiques.
              try {
                const origPlay = HTMLMediaElement.prototype.play;
                HTMLMediaElement.prototype.play = function() {
                  try { this.pause(); } catch (e) {}
                  try { this.muted = true; this.volume = 0; } catch (e) {}
                  return Promise.reject(new Error('Blocked by Glitcho'));
                };
                // Garder une référence au cas où (debug)
                window.__glitcho_origPlay = origPlay;
              } catch (e) {}

              pauseAll();
              const observer = new MutationObserver(pauseAll);
              observer.observe(document.documentElement, { childList: true, subtree: true });
              setInterval(pauseAll, 500);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )

        // Hide page initially until customization is done
        let initialHideScript = WKUserScript(
            source: """
            (function() {
              if (document.getElementById('glitcho-channel-hide')) { return; }
              const style = document.createElement('style');
              style.id = 'glitcho-channel-hide';
              style.textContent = 'html { background: transparent !important; } body { opacity: 0 !important; transition: opacity 0.12s ease-out !important; } body.glitcho-ready { opacity: 1 !important; }';
              document.documentElement.appendChild(style);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )

        // Script pour n'afficher que le contenu "About" et le placer au top.
        let aboutOnlyScript = WKUserScript(
            source: """
            (function() {
                if (window.__glitcho_about_only) { return; }
                window.__glitcho_about_only = true;

                const css = `
                    html, body {
                        background: transparent !important;
                        background-color: transparent !important;
                        margin: 0 !important;
                        padding: 0 !important;
                        overflow-x: hidden !important;
                    }
                    body {
                        color-scheme: dark;
                        -webkit-font-smoothing: antialiased;
                        text-rendering: optimizeLegibility;
                    }
                    /* Si Twitch applique une couleur de fond/overlay, on neutralise */
                    body::before, body::after,
                    #root::before, #root::after {
                        background: transparent !important;
                        background-color: transparent !important;
                    }
                    footer { display: none !important; }
                    /* Sécurité: masquer le player/chat si jamais ils apparaissent */
                    [data-a-target="video-player"],
                    [data-a-target="player-overlay-click-handler"],
                    [data-a-target="right-column"],
                    [data-a-target="chat-shell"],
                    video,
                    .video-player,
                    .persistent-player,
                    aside[aria-label*="Chat"] {
                        display: none !important;
                    }
                    /* Le contenu doit démarrer en haut, sans padding excessif */
                    main, [data-test-selector="main-page-scrollable-area"] {
                        margin: 0 !important;
                        padding: 0 !important;
                        max-width: 100% !important;
                        background: transparent !important;
                    }
                    [data-glitcho-about-block="1"] {
                        padding: 18px 18px 22px !important;
                        margin: 0 !important;
                        background: rgba(18, 18, 22, 0.35) !important;
                        border: 1px solid rgba(255, 255, 255, 0.08) !important;
                        border-radius: 18px !important;
                    }
                    [data-glitcho-about-block="1"] a {
                        color: rgba(180, 140, 255, 0.95) !important;
                    }
                    [data-glitcho-about-block="1"] a:visited {
                        color: rgba(180, 140, 255, 0.85) !important;
                    }
                    /* Boutons d'action (Follow / notif / Gift / Resubscribe) */
                    [data-glitcho-actions="1"] button,
                    [data-glitcho-actions="1"] a,
                    [data-glitcho-actions="1"] [role="button"] {
                        border-radius: 999px !important;
                        border: 1px solid rgba(255, 255, 255, 0.14) !important;
                        background: rgba(255, 255, 255, 0.08) !important;
                        box-shadow: none !important;
                        backdrop-filter: blur(10px) !important;
                    }
                    [data-glitcho-actions="1"] button:hover,
                    [data-glitcho-actions="1"] a:hover,
                    [data-glitcho-actions="1"] [role="button"]:hover {
                        background: rgba(255, 255, 255, 0.12) !important;
                        border-color: rgba(255, 255, 255, 0.18) !important;
                    }
                    [data-glitcho-actions="1"] svg {
                        filter: drop-shadow(0 1px 0 rgba(0,0,0,0.35));
                    }
                    /* Hide channel tabs we don't want if they slip into About */
                    a[href$="/chat"], a[href*="/chat?"], a[href*="/chat/"],
                    a[href$="/home"], a[href*="/home?"], a[href*="/home/"] {
                        display: none !important;
                    }
                    /* Hide the top channel header block (avatar/live banner) if it slips into extracted content */
                    [data-a-target="channel-header"],
                    [data-test-selector="channel-header"],
                    [data-a-target="channel-info-bar"],
                    [data-test-selector="channel-info-bar"] {
                        display: none !important;
                        height: 0 !important;
                        margin: 0 !important;
                        padding: 0 !important;
                    }
                    /* Disable channel name links that navigate to streamer page */
                    a[href^="/"]:not([href*="/videos"]):not([href*="/clip"]):not([href*="/schedule"]):not([href*="/about"]):not([href*="http"]) {
                        pointer-events: none !important;
                        cursor: default !important;
                    }
                    /* Re-enable external links and specific action links */
                    a[href^="http"], a[href*="/videos"], a[href*="/clip"] {
                        pointer-events: auto !important;
                        cursor: pointer !important;
                    }
                `;

                function ensureStyle() {
                    let style = document.getElementById('glitcho-about-only-style');
                    if (!style) {
                        style = document.createElement('style');
                        style.id = 'glitcho-about-only-style';
                        style.textContent = css;
                        (document.head || document.documentElement).appendChild(style);
                    }
                }

                function normalizeText(s) {
                    try {
                        return (s || '')
                            .toLowerCase()
                            .normalize('NFD')
                            .replace(/[\\u0300-\\u036f]/g, '')
                            .trim();
                    } catch (_) {
                        return (s || '').toLowerCase().trim();
                    }
                }

                function isAboutText(t) {
                    const s = normalizeText(t);
                    return s.startsWith('about') || s.startsWith('a propos') || s.includes('a propos de') || s.includes('about ');
                }

                function findAboutMarker(main) {
                    const headingish = Array.from(main.querySelectorAll('h1,h2,h3,[role="heading"]'));
                    const direct = headingish.find(el => isAboutText(el.textContent));
                    if (direct) { return direct; }

                    // Fallback: chercher un élément "petit" qui contient About/À propos (pas tout le main)
                    const all = Array.from(main.querySelectorAll('*'));
                    for (const el of all) {
                        const text = (el.textContent || '').trim();
                        if (!text || text.length > 120) { continue; }
                        if (isAboutText(text)) { return el; }
                    }
                    return null;
                }

                function pickAboutContainer(marker, main) {
                    if (!marker) { return null; }
                    const preferred = marker.closest('section') || marker.closest('[data-test-selector]') || marker.closest('[data-a-target]');
                    if (preferred && preferred !== document.body && preferred !== main) { return preferred; }
                    const block = marker.closest('div') || marker.parentElement;
                    if (block && block !== document.body && block !== main) { return block; }
                    return marker;
                }

                function closestUnderMain(el, main) {
                    if (!el || !main) { return null; }
                    let cur = el;
                    while (cur && cur.parentElement && cur.parentElement !== main) {
                        cur = cur.parentElement;
                    }
                    return cur && cur.parentElement === main ? cur : null;
                }

                function hide(el) {
                    if (!el) { return; }
                    el.style.display = 'none';
                    el.style.height = '0';
                    el.style.opacity = '0';
                    el.style.pointerEvents = 'none';
                }

                function extractAboutOnly() {
                    const main = document.querySelector('main') || document.querySelector('[role="main"]') || document.body;
                    if (!main) { return false; }
                    const marker = findAboutMarker(main);
                    if (!marker) { return false; }
                    const container = pickAboutContainer(marker, main);
                    if (!container) { return false; }


                    // Si le container est trop petit, la page n'est peut-être pas encore hydratée.
                    try {
                        const rect = container.getBoundingClientRect();
                        if (rect && rect.height && rect.height < 40) { return false; }
                    } catch (_) {}

                    function closestButton(el) {
                        if (!el) { return null; }
                        return el.closest('button,[role="button"],a') || el;
                    }

                    function findFollowButton(root) {
                        const scope = root || document;
                        const direct = scope.querySelector('[data-a-target*="follow"], button[aria-label*="Follow"], button[aria-label*="Suivre"], button[aria-label*="Following"], button[aria-label*="Abonné"], button[aria-label*="Abonne"]');
                        if (direct) { return closestButton(direct); }
                        const list = Array.from(scope.querySelectorAll('button,[role="button"],a')).slice(0, 240);
                        for (const el of list) {
                            const t = normalizeText(el.getAttribute('aria-label') || el.textContent || '');
                            if (t === 'follow' || t === 'suivre' || t === 'following' || t === 'abonne' || t === 'abonné') {
                                return closestButton(el);
                            }
                        }
                        return null;
                    }

                    function findBellButton(root) {
                        const scope = root || document;
                        const direct = scope.querySelector('[data-a-target="notifications-button"], [data-a-target="notification-button"], button[aria-label*="Notification"], button[aria-label*="Notifications"], button[aria-label*="Notific"]');
                        return closestButton(direct);
                    }

                    function cloneActions() {
                        const selectors = [
                          '[data-a-target="channel-actions"]',
                          '[data-a-target*="channel-actions"]',
                          '[data-test-selector*="channel-actions"]',
                          '[data-test-selector="channel-info-bar-actions"]',
                          '[data-test-selector*="channel-info-bar"] [data-a-target*="actions"]'
                        ];
                        for (const sel of selectors) {
                          const node = document.querySelector(sel);
                          if (node) { return node.cloneNode(true); }
                        }
                        const follow = findFollowButton(document);
                        const bell = findBellButton(document);
                        if (!follow && !bell) { return null; }
                        const wrapper = document.createElement('div');
                        wrapper.setAttribute('data-glitcho-actions', '1');
                        wrapper.style.display = 'flex';
                        wrapper.style.flexWrap = 'wrap';
                        wrapper.style.alignItems = 'center';
                        wrapper.style.gap = '10px';
                        if (follow) { wrapper.appendChild(follow.cloneNode(true)); }
                        if (bell) { wrapper.appendChild(bell.cloneNode(true)); }
                        return wrapper;
                    }

                    const actionsClone = cloneActions();
                    if (!actionsClone) { return false; }

                    // Version "propre" : extraire UNIQUEMENT le bloc About pour éviter de remettre tout le layout Twitch.
                    try {
                        const root = document.createElement('div');
                        root.id = 'glitcho-about-root';
                        const shell = document.createElement('div');
                        shell.setAttribute('data-glitcho-about-block', '1');
                        actionsClone.setAttribute('data-glitcho-actions', '1');
                        actionsClone.style.marginBottom = '14px';
                        shell.appendChild(actionsClone);
                        shell.appendChild(container);
                        root.appendChild(shell);
                        document.body.innerHTML = '';
                        document.body.appendChild(root);

                        // Enlever uniquement les tabs non désirés (Home/Chat) et limiter la tab-bar.
                        const killSelectors = [
                          '[data-a-target="channel-header"]',
                          '[data-test-selector="channel-header"]',
                          '[data-a-target="channel-info-bar"]',
                          '[data-test-selector="channel-info-bar"]'
                        ];
                        killSelectors.forEach(sel => {
                          try {
                            root.querySelectorAll(sel).forEach(el => {
                              if (el.matches('[data-glitcho-actions="1"]') || el.querySelector('[data-glitcho-actions="1"]')) {
                                return;
                              }
                              el.remove();
                            });
                          } catch (_) {}
                        });

                        const norm = (s) => {
                          try { return (s || '').toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').trim(); }
                          catch (_) { return (s || '').toLowerCase().trim(); }
                        };
                        Array.from(root.querySelectorAll('button,a,[role="button"],[role="tab"]')).forEach(el => {
                          const t = norm(el.textContent);
                          if (!t) { return; }
                          const hit =
                            t === 'home' ||
                            t === 'chat' ||
                            t === 'following';
                          if (hit) {
                            // Pour les tabs, on cache le <li> mais on garde la barre (About/Videos)
                            const li = el.closest('li');
                            if (li) {
                              li.remove();
                            } else {
                              const wrapper = el.closest('div') || el;
                              wrapper.remove();
                            }
                          }
                        });

                        // Extra: hide/remove by href patterns.
                        Array.from(root.querySelectorAll('a[href]')).forEach(a => {
                          const href = (a.getAttribute('href') || '').toLowerCase();
                          if (!href) { return; }
                          if (href.endsWith('/chat') || href.includes('/chat?') || href.includes('/chat/')) {
                            const li = a.closest('li');
                            if (li) li.remove(); else (a.closest('div') || a).remove();
                          }
                          if (href.endsWith('/following') || href.includes('/following?') || href.includes('/following/')) {
                            const li = a.closest('li');
                            if (li) li.remove(); else (a.closest('div') || a).remove();
                          }
                          if (href.endsWith('/home') || href.includes('/home?') || href.includes('/home/')) {
                            const li = a.closest('li');
                            if (li) li.remove(); else (a.closest('div') || a).remove();
                          }
                        });

                        // Si la barre de tabs existe, ne garder que About + Schedule + Videos.
                        try {
                          const allowed = new Set(['about', 'a propos', 'à propos', 'schedule', 'videos', 'vidéos']);
                          const tabs = Array.from(root.querySelectorAll('[role="tab"], a, button'));
                          tabs.forEach(el => {
                            const t = norm(el.textContent);
                            if (!t) { return; }
                            if (t === 'home' || t === 'chat' || t === 'following') { return; }
                            // si ça ressemble à un tab label mais pas About/Videos, on le retire
                            const isTabby = el.getAttribute('role') === 'tab' || (el.closest('[role="tablist"]') != null);
                            if (isTabby) {
                              const ok = Array.from(allowed).some(a => t === a);
                              if (!ok) {
                                const li = el.closest('li');
                                if (li) li.remove(); else el.remove();
                              }
                            }
                          });
                        } catch (_) {}

                        // Collapse any empty top rows left after removals.
                        try {
                          const isEmptyish = (el) => {
                            if (!el) return true;
                            const text = norm(el.textContent || '');
                            const hasMedia = !!el.querySelector('img,svg,video,audio,button,[role=\"button\"],a');
                            return text.length === 0 && !hasMedia;
                          };
                          let guardCount = 0;
                          while (guardCount++ < 12) {
                            const first = shell.firstElementChild;
                            if (!first) break;
                            const rect = first.getBoundingClientRect ? first.getBoundingClientRect() : null;
                            const small = !rect || rect.height < 140;
                            if (small && isEmptyish(first)) {
                              first.remove();
                              continue;
                            }
                            break;
                          }
                        } catch (_) {}
                    } catch (_) { return false; }

                    try {
                      if (window.__glitcho_decorateChannelActions) {
                        window.__glitcho_decorateChannelActions();
                      }
                    } catch (_) {}

                    try { window.scrollTo(0, 0); } catch (_) {}
                    return true;
                }

                ensureStyle();
                let tries = 0;
                const maxTries = 60; // ~12s (React hydrate parfois lentement)
                const timer = setInterval(() => {
                    ensureStyle();
                    const ok = extractAboutOnly();
                    tries++;
                    if (ok || tries >= maxTries) {
                        clearInterval(timer);
                        // Reveal page after customization
                        document.body.classList.add('glitcho-ready');
                    }
                }, 200);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        let subscriptionInterceptScript = WKUserScript(
            source: """
            (function() {
              if (window.__glitcho_subscribe_intercept) { return; }
              window.__glitcho_subscribe_intercept = true;

              function normalize(s) {
                try {
                  return (s || '').toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').trim();
                } catch (_) {
                  return (s || '').toLowerCase().trim();
                }
              }

              function isSubscribeElement(el) {
                if (!el) { return false; }
                const hit = el.closest([
                  '[data-a-target="subscribe-button"]',
                  '[data-a-target="subscribe-button__text"]',
                  'a[href*="/subs/"]',
                  'button[aria-label*="Subscribe"]',
                  'button[aria-label*="sub"]'
                ].join(','));
                if (hit) { return true; }

                // Fallback: texte du bouton (FR/EN)
                const t = normalize(el.textContent || '');
                return t === 'subscribe' || t === 'sub' || t === "s'abonner" || t === 'sabonner';
              }

              document.addEventListener('click', function(e) {
                const target = e.target;
                if (!isSubscribeElement(target)) { return; }
                e.preventDefault();
                e.stopPropagation();
                try {
                  window.webkit.messageHandlers.openSubscription.postMessage({ channel: "\(channelName)" });
                } catch (_) {}
              }, true);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        let giftInterceptScript = WKUserScript(
            source: """
            (function() {
              if (window.__glitcho_gift_intercept) { return; }
              window.__glitcho_gift_intercept = true;

              function normalize(s) {
                try {
                  return (s || '').toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').trim();
                } catch (_) {
                  return (s || '').toLowerCase().trim();
                }
              }

              function isGiftElement(el) {
                if (!el) { return false; }
                const hit = el.closest([
                  'a[href*="/subs/"]',
                  'button',
                  '[role="button"]'
                ].join(','));
                if (!hit) { return false; }
                const t = normalize(hit.textContent || el.textContent || '');
                return t.includes('gift a sub') || t.includes('gift sub') || t.includes('offrir un sub');
              }

              document.addEventListener('click', function(e) {
                const target = e.target;
                if (!isGiftElement(target)) { return; }
                e.preventDefault();
                e.stopPropagation();
                try {
                  window.webkit.messageHandlers.openGiftSub.postMessage({ channel: "\(channelName)" });
                } catch (_) {}
              }, true);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        // Block clicks on channel name links that would navigate away
        let blockChannelLinksScript = WKUserScript(
            source: """
            (function() {
              if (window.__glitcho_block_channel_links) { return; }
              window.__glitcho_block_channel_links = true;

              document.addEventListener('click', function(e) {
                const link = e.target.closest('a[href]');
                if (!link) { return; }
                const href = link.getAttribute('href') || '';
                // Block links to channel root (e.g., /channelname or /channelname/home)
                if (href.match(/^\\/[^\\/]+\\/?$/) || href.match(/^\\/[^\\/]+\\/home\\/?$/)) {
                  e.preventDefault();
                  e.stopPropagation();
                  return;
                }
                // Block links to the current channel root
                if (href === '/\(channelName)' || href === '/\(channelName)/' || href === '/\(channelName)/home') {
                  e.preventDefault();
                  e.stopPropagation();
                  return;
                }
              }, true);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        let channelActionsScript = WKUserScript(
            source: """
            (function() {
              if (window.__glitcho_channel_actions) { return; }
              window.__glitcho_channel_actions = true;

              const login = "\(channelName)".toLowerCase();

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

              function rootNode() {
                return document.querySelector('[data-glitcho-about-block="1"]');
              }

              function closestButton(el) {
                if (!el) { return null; }
                return el.closest('button,[role="button"],a') || el;
              }

              function findBellButton(root) {
                if (!root) { return null; }
                const el = root.querySelector(
                  '[data-a-target="notifications-button"], [data-a-target="notification-button"], [aria-label*="Notification"], [aria-label*="Notifications"], [aria-label*="Notific"]'
                );
                return closestButton(el);
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
                if (!login) { return; }
                const root = rootNode();
                if (!root) { return; }
                const button = findBellButton(root);
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
                if (!rootNode()) { return; }
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

              window.__glitcho_setBellState = function(loginValue, enabled) {
                const normalized = (loginValue || '').toLowerCase();
                if (!normalized || normalized !== login) { return; }
                const root = rootNode();
                if (!root) { return; }
                const button = root.querySelector('[data-glitcho-bell="1"]');
                if (button) { setBellState(button, !!enabled); }
              };
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        contentController.addUserScript(initialHideScript)
        contentController.addUserScript(blockMediaScript)
        contentController.addUserScript(aboutOnlyScript)
        contentController.addUserScript(subscriptionInterceptScript)
        contentController.addUserScript(giftInterceptScript)
        contentController.addUserScript(blockChannelLinksScript)
        contentController.addUserScript(channelActionsScript)
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        
        // Charger la page About (l'utilisateur peut ensuite cliquer Videos/Schedule)
        let url = URL(string: "https://www.twitch.tv/\(channelName)/about")!
        webView.load(URLRequest(url: url))
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Reload if channel changed
        let url = URL(string: "https://www.twitch.tv/\(channelName)/about")!
        let currentPath = nsView.url?.path ?? ""
        if !currentPath.lowercased().hasPrefix("/\(channelName.lowercased())") {
            nsView.load(URLRequest(url: url))
        }
        let normalized = channelName.lowercased()
        let js = "window.__glitcho_setBellState && window.__glitcho_setBellState('\(normalized)', \(notificationEnabled ? "true" : "false"));"
        nsView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// WebView pour afficher la page complète de la chaîne
struct ChannelPageWebView: NSViewRepresentable {
    let channelName: String
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // Script AGRESSIF pour masquer complètement le player vidéo et le chat
        let hidePlayerScript = WKUserScript(
            source: """
            (function() {
                console.log('[Glitcho] Starting aggressive player/chat removal');
                
                const css = `
                    /* Masquer SEULEMENT le player vidéo */
                    [data-a-target="video-player"],
                    [data-a-target="player-overlay-click-handler"],
                    .video-player,
                    .persistent-player,
                    video {
                        display: none !important;
                        height: 0 !important;
                        visibility: hidden !important;
                    }
                    
                    /* Masquer SEULEMENT le chat */
                    [data-a-target="right-column"],
                    [data-a-target="chat-shell"],
                    aside[aria-label*="Chat"] {
                        display: none !important;
                        width: 0 !important;
                    }
                    
                    /* Ajuster le layout */
                    main {
                        max-width: 100% !important;
                        padding-top: 0 !important;
                    }
                `;
                
                // Injecter le CSS immédiatement
                if (!document.getElementById('glitcho-hide-all')) {
                    const style = document.createElement('style');
                    style.id = 'glitcho-hide-all';
                    style.textContent = css;
                    (document.head || document.documentElement).appendChild(style);
                }
                
                // Fonction ciblée pour supprimer SEULEMENT player et chat
                function nukePlayerAndChat() {
                    let removed = 0;
                    
                    // 1. Supprimer le player vidéo (zone du haut)
                    const playerSelectors = [
                        '[data-a-target="video-player"]',
                        '[data-a-target="player-overlay-click-handler"]',
                        'video',
                        '.video-player',
                        '.persistent-player',
                        '[class*="video-player"]'
                    ];
                    
                    playerSelectors.forEach(selector => {
                        try {
                            document.querySelectorAll(selector).forEach(el => {
                                // Vérifier que c'est bien un élément player (pas du contenu)
                                if (el.tagName === 'VIDEO' || 
                                    el.querySelector('video') || 
                                    el.clientHeight > 200) {
                                    el.remove();
                                    removed++;
                                }
                            });
                        } catch (e) {}
                    });
                    
                    // 2. Supprimer la colonne de droite (chat)
                    const chatSelectors = [
                        '[data-a-target="right-column"]',
                        '[data-a-target="chat-shell"]',
                        'aside[aria-label*="Chat"]'
                    ];
                    
                    chatSelectors.forEach(selector => {
                        try {
                            document.querySelectorAll(selector).forEach(el => {
                                el.remove();
                                removed++;
                            });
                        } catch (e) {}
                    });
                    
                    // 3. Supprimer les iframes de player
                    document.querySelectorAll('iframe').forEach(iframe => {
                        if (iframe.src && iframe.src.includes('player')) {
                            iframe.remove();
                            removed++;
                        }
                    });
                    
                    if (removed > 0) {
                        console.log(`[Glitcho] Removed ${removed} player/chat elements`);
                    }
                }
                
                // Exécuter immédiatement
                nukePlayerAndChat();
                
                // Répéter toutes les 200ms (très agressif)
                setInterval(nukePlayerAndChat, 200);
                
                // Observer les mutations
                const observer = new MutationObserver(nukePlayerAndChat);
                observer.observe(document.documentElement, { 
                    childList: true, 
                    subtree: true,
                    attributes: false 
                });
                
                console.log('[Glitcho] Aggressive removal active');
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        
        contentController.addUserScript(hidePlayerScript)
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        
        // Charger la page principale de la chaîne (pas /about)
        let url = URL(string: "https://www.twitch.tv/\(channelName)")!
        webView.load(URLRequest(url: url))
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Reload if channel changed
        let url = URL(string: "https://www.twitch.tv/\(channelName)")!
        let currentPath = nsView.url?.path ?? ""
        if !currentPath.lowercased().hasPrefix("/\(channelName.lowercased())") {
            nsView.load(URLRequest(url: url))
        }
    }
}
