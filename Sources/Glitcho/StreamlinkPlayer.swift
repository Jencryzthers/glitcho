#if canImport(SwiftUI)
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
    private let streamlinkPathKey = "streamlinkPath"
    private let ffmpegPathKey = "ffmpegPath"
    
    func getStreamURL(for channel: String, quality: String = "best") async throws -> URL {
        return try await getStreamURL(target: "twitch.tv/\(channel)", quality: quality)
    }

    func getStreamURL(target: String, quality: String = "best") async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let streamlinkExecutable: URL
                do {
                    streamlinkExecutable = try self.resolveStreamlinkExecutable()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let process = Process()
                let pipe = Pipe()
                let errorPipe = Pipe()
                
                process.executableURL = streamlinkExecutable
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
                    self.process = process
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

    private func resolveStreamlinkExecutable() throws -> URL {
        if let custom = resolvedCustomPath(forKey: streamlinkPathKey) {
            if isExecutableFile(atPath: custom) {
                return URL(fileURLWithPath: custom)
            }
            throw streamlinkError("Streamlink not executable at \(custom). Check Settings → Streamlink Path.")
        }

        if let path = resolveExecutable(named: "streamlink") {
            return URL(fileURLWithPath: path)
        }

        throw streamlinkError("Streamlink not found. Install it or set a custom path in Settings.")
    }

    private func resolveFFmpegExecutable() -> URL? {
        if let custom = resolvedCustomPath(forKey: ffmpegPathKey), isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if let path = resolveExecutable(named: "ffmpeg") {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func resolveExecutable(named name: String) -> String? {
        let fallbackPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathEntries = pathEnvironment.split(separator: ":").map(String.init)
        let searchPaths = pathEntries + fallbackPaths
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func resolvedCustomPath(forKey key: String) -> String? {
        let rawPath = UserDefaults.standard.string(forKey: key) ?? ""
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    private func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private func streamlinkError(_ message: String) -> Error {
        NSError(domain: "StreamlinkError", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Vue player vidéo natif avec AVPlayer
struct NativeVideoPlayer: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    let pipController: PictureInPictureController?

    /// Digital zoom (1.0 = normal). Applied to the underlying video layer (not the whole UI).
    @Binding var zoom: CGFloat
    /// Pan offset in points (only meaningful when zoom > 1).
    @Binding var pan: CGSize

    var minZoom: CGFloat = 1.0
    var maxZoom: CGFloat = 4.0

    init(
        url: URL,
        isPlaying: Binding<Bool>,
        pipController: PictureInPictureController? = nil,
        zoom: Binding<CGFloat> = .constant(1.0),
        pan: Binding<CGSize> = .constant(.zero),
        minZoom: CGFloat = 1.0,
        maxZoom: CGFloat = 4.0
    ) {
        self.url = url
        self._isPlaying = isPlaying
        self.pipController = pipController
        self._zoom = zoom
        self._pan = pan
        self.minZoom = minZoom
        self.maxZoom = maxZoom
    }

    final class ZoomableAVPlayerView: AVPlayerView {
        var onLayout: ((ZoomableAVPlayerView) -> Void)?

        override func layout() {
            super.layout()
            onLayout?(self)
        }
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var endObserver: Any?
        let pipController: PictureInPictureController?

        var parent: NativeVideoPlayer
        private var magnifyStartZoom: CGFloat = 1.0
        private var panStart: CGSize = .zero

        weak var resolvedVideoLayer: CALayer?
        weak var playerView: ZoomableAVPlayerView?

        init(parent: NativeVideoPlayer, pipController: PictureInPictureController?) {
            self.parent = parent
            self.pipController = pipController
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            // Avoid interfering with AVPlayerView controls: only pan when Option is held.
            if gestureRecognizer is NSPanGestureRecognizer {
                return NSEvent.modifierFlags.contains(.option)
            }
            return true
        }

        @objc func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
            guard let view = recognizer.view as? AVPlayerView else { return }
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            switch recognizer.state {
            case .began:
                magnifyStartZoom = parent.zoom
            case .changed:
                let raw = magnifyStartZoom * (1.0 + recognizer.magnification)
                let clamped = clampZoom(raw)
                if parent.zoom != clamped {
                    parent.zoom = clamped
                }
                parent.pan = clampPan(parent.pan, in: bounds, zoom: parent.zoom)
                applyZoomAndPan(to: view)
            case .ended, .cancelled, .failed:
                parent.zoom = clampZoom(parent.zoom)
                parent.pan = clampPan(parent.pan, in: bounds, zoom: parent.zoom)
                applyZoomAndPan(to: view)
            default:
                break
            }
        }

        @objc func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let view = recognizer.view as? AVPlayerView else { return }
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            // Only allow panning when zoomed in.
            if parent.zoom <= (parent.minZoom + 0.001) {
                if parent.pan != .zero {
                    parent.pan = .zero
                    applyZoomAndPan(to: view)
                }
                return
            }

            switch recognizer.state {
            case .began:
                panStart = parent.pan
            case .changed:
                let t = recognizer.translation(in: view)
                let raw = CGSize(width: panStart.width + t.x, height: panStart.height + t.y)
                let clamped = clampPan(raw, in: bounds, zoom: parent.zoom)
                if parent.pan != clamped {
                    parent.pan = clamped
                }
                applyZoomAndPan(to: view)
            case .ended, .cancelled, .failed:
                parent.pan = clampPan(parent.pan, in: bounds, zoom: parent.zoom)
                applyZoomAndPan(to: view)
            default:
                break
            }
        }

        @objc func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let view = recognizer.view as? AVPlayerView else { return }
            parent.zoom = 1.0
            parent.pan = .zero
            applyZoomAndPan(to: view)
        }

        func applyZoomAndPan(to view: AVPlayerView) {
            view.wantsLayer = true
            view.layer?.masksToBounds = true

            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            let z = clampZoom(parent.zoom)
            let p = clampPan(parent.pan, in: bounds, zoom: z)

            guard let videoLayer = resolveVideoLayer(in: view) else { return }

            let containerBounds = videoLayer.superlayer?.bounds ?? view.layer?.bounds ?? bounds
            let center = CGPoint(x: containerBounds.midX, y: containerBounds.midY)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            videoLayer.position = CGPoint(x: center.x + p.width, y: center.y + p.height)
            videoLayer.setAffineTransform(CGAffineTransform(scaleX: z, y: z))
            CATransaction.commit()
        }

        private func clampZoom(_ value: CGFloat) -> CGFloat {
            min(max(value, parent.minZoom), parent.maxZoom)
        }

        private func clampPan(_ value: CGSize, in bounds: CGRect, zoom: CGFloat) -> CGSize {
            if zoom <= (parent.minZoom + 0.001) { return .zero }
            let maxX = (zoom - 1.0) * bounds.width / 2.0
            let maxY = (zoom - 1.0) * bounds.height / 2.0
            if maxX <= 0 || maxY <= 0 { return .zero }
            return CGSize(
                width: min(max(value.width, -maxX), maxX),
                height: min(max(value.height, -maxY), maxY)
            )
        }

        private func resolveVideoLayer(in view: AVPlayerView) -> CALayer? {
            if let existing = resolvedVideoLayer { return existing }

            if let root = view.layer {
                if root is AVPlayerLayer {
                    resolvedVideoLayer = root
                    return root
                }
                if let found = findFirstAVPlayerLayer(in: root) {
                    resolvedVideoLayer = found
                    return found
                }
            }

            return nil
        }

        private func findFirstAVPlayerLayer(in layer: CALayer) -> CALayer? {
            if layer is AVPlayerLayer { return layer }
            for sub in layer.sublayers ?? [] {
                if let found = findFirstAVPlayerLayer(in: sub) {
                    return found
                }
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self, pipController: pipController) }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = ZoomableAVPlayerView()
        playerView.controlsStyle = .floating
        playerView.showsFrameSteppingButtons = false
        playerView.showsFullScreenToggleButton = true
        playerView.wantsLayer = true
        playerView.layer?.masksToBounds = true

        let player = AVPlayer(url: url)
        playerView.player = player

        // Gestures: pinch to zoom, drag to pan, double-click to reset.
        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnify(_:)))
        magnify.delegate = context.coordinator
        playerView.addGestureRecognizer(magnify)

        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.buttonMask = 0x1 // left mouse / primary
        playerView.addGestureRecognizer(pan)

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.delegate = context.coordinator
        doubleClick.numberOfClicksRequired = 2
        playerView.addGestureRecognizer(doubleClick)

        playerView.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.applyZoomAndPan(to: view)
        }

        context.coordinator.playerView = playerView

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
        context.coordinator.applyZoomAndPan(to: playerView)
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        context.coordinator.parent = self

        if let current = playerView.player?.currentItem?.asset as? AVURLAsset, current.url != url {
            playerView.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        if isPlaying {
            playerView.player?.play()
        } else {
            playerView.player?.pause()
        }
        context.coordinator.pipController?.attach(playerView)
        context.coordinator.applyZoomAndPan(to: playerView)
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        if let token = coordinator.endObserver {
            NotificationCenter.default.removeObserver(token)
            coordinator.endObserver = nil
        }
        (playerView as? ZoomableAVPlayerView)?.onLayout = nil
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
    @ObservedObject var recordingManager: RecordingManager
    var onOpenSubscription: ((String) -> Void)?
    var onOpenGiftSub: ((String) -> Void)?
    var notificationEnabled: Bool = true
    var onNotificationToggle: ((Bool) -> Void)?
    var isRecording: Bool = false
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
    @State private var recordingError: String?

    @State private var videoZoom: CGFloat = 1.0
    @State private var videoPan: CGSize = .zero
    @StateObject private var aboutStore = ChannelAboutStore()

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
                                    NativeVideoPlayer(
                                        url: url,
                                        isPlaying: $isPlaying,
                                        pipController: pipController,
                                        zoom: $videoZoom,
                                        pan: $videoPan
                                    )
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
                                    .lineLimit(1)

                                HStack(spacing: 8) {
                                    Image(systemName: "plus.magnifyingglass")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))

                                    Slider(
                                        value: Binding(
                                            get: { Double(videoZoom) },
                                            set: { newValue in
                                                videoZoom = CGFloat(newValue)
                                                if videoZoom <= 1.001 {
                                                    videoPan = .zero
                                                }
                                            }
                                        ),
                                        in: 1.0...4.0,
                                        step: 0.05
                                    )
                                    .frame(width: 110)
                                    .controlSize(.mini)
                                    .tint(.white.opacity(0.8))

                                    Text(String(format: "%.2f×", Double(videoZoom)))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .frame(width: 52, alignment: .trailing)

                                    Button(action: { resetVideoZoom() }) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Reset zoom")
                                }
                                .help("Pinch to zoom • Option-drag to pan • Double-click to reset")

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

                                if playback.kind == .liveChannel, playback.channelName != nil {
                                    Button(action: { onRecordRequest?() }) {
                                        RecordingControlBadge(
                                            isRecording: recordingManager.isRecording,
                                            label: recordingManager.isRecording ? "Stop" : "Record"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help(recordingManager.isRecording ? "Stop recording" : "Start recording")
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
                        ChannelAboutPanelView(
                            channelName: channel,
                            store: aboutStore,
                            onOpenSubscription: { onOpenSubscription?(channel) },
                            onOpenGiftSub: { onOpenGiftSub?(channel) }
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
        .alert("Recording Error", isPresented: Binding<Bool>(
            get: { recordingError != nil },
            set: { if !$0 { recordingError = nil } }
        )) {
            Button("OK") { recordingError = nil }
        } message: {
            Text(recordingError ?? "Recording failed.")
        }
        .onAppear {
            lastChannelName = playback.channelName
            if playback.kind == .liveChannel, let channel = playback.channelName {
                applyChatPreference(for: channel)
                aboutStore.load(channelName: channel)
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
                    aboutStore.load(channelName: channel)
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
            if recordingManager.isRecording {
                recordingManager.stopRecording()
            }
        }
        .onReceive(recordingManager.$errorMessage) { error in
            if let error {
                recordingError = error
            }
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

    private func resetVideoZoom() {
        videoZoom = 1.0
        videoPan = .zero
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

private struct RecordingControlBadge: View {
    let isRecording: Bool
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRecording ? Color.red : Color.white.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isRecording ? 0.9 : 0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isRecording ? 0.15 : 0.08))
        )
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

struct ChannelAboutPanel: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let body: String
    let imageURL: URL?
    let links: [ChannelAboutLink]
}

struct ChannelAboutLink: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: URL
    let imageURL: URL?
}

final class ChannelAboutStore: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var panels: [ChannelAboutPanel] = []
    @Published var isLoading = false
    @Published var lastError: String?

    private var webView: WKWebView?
    private var currentChannel: String?

    override init() {
        super.init()
        webView = makeWebView()
    }

    func attachWebView() -> WKWebView {
        if let webView { return webView }
        let view = makeWebView()
        webView = view
        return view
    }

    func load(channelName: String) {
        let normalized = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard normalized != currentChannel else { return }
        currentChannel = normalized
        isLoading = true
        lastError = nil
        panels = []
        let url = URL(string: "https://www.twitch.tv/\(normalized)/about")!
        webView?.load(URLRequest(url: url))
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]

        contentController.add(self, name: "aboutPanels")
        contentController.addUserScript(Self.scrapePanelsScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        return webView
    }

    private static let scrapePanelsScript = WKUserScript(
        source: """
        (function() {
          if (window.__glitcho_about_scrape) { return; }
          window.__glitcho_about_scrape = true;

          function trim(s) {
            return (s || '').replace(/\\s+/g, ' ').trim();
          }

          function findContainer() {
            return document.querySelector('[data-test-selector="channel-panels"]') ||
              document.querySelector('[data-a-target="channel-panels"]') ||
              document.querySelector('[data-test-selector="channel-info-content"]') ||
              document.querySelector('[data-a-target="channel-info-content"]') ||
              document.querySelector('section[aria-label*="About"]') ||
              document.querySelector('section[aria-label*="À propos"]') ||
              document.querySelector('section[aria-label*="A propos"]') ||
              document.querySelector('main') ||
              document.querySelector('[role="main"]');
          }

          function extractPanels() {
            const container = findContainer();
            if (!container) { return []; }
            let panelNodes = Array.from(container.querySelectorAll('[data-test-selector="channel-panel"], [data-a-target="channel-panel"], [data-test-selector*="panel"], [data-a-target*="panel"]'));
            if (!panelNodes.length) {
              panelNodes = Array.from(container.querySelectorAll('section'));
            }
            if (!panelNodes.length) {
              panelNodes = Array.from(container.children || []);
            }

            const panels = [];
            for (const panel of panelNodes) {
              const titleEl = panel.querySelector('[data-test-selector="channel-panel-title"]') ||
                panel.querySelector('h1,h2,h3,[role="heading"]');
              const title = trim(titleEl ? titleEl.textContent : '');

              let bodyEl = panel.querySelector('[data-test-selector="channel-panel-content"]') ||
                panel.querySelector('[data-a-target="channel-panel-content"]') ||
                panel.querySelector('p') ||
                panel;
              const body = trim(bodyEl ? bodyEl.textContent : '');
              if (!title && !body) { continue; }

              const imageEl = panel.querySelector('img[src]');
              const imageURL = imageEl ? imageEl.getAttribute('src') || '' : '';

              const linkNodes = Array.from(panel.querySelectorAll('a[href]'));
              const links = linkNodes.map(link => {
                const linkImage = link.querySelector('img[src]');
                return {
                  title: trim(link.textContent || link.getAttribute('href') || ''),
                  url: link.getAttribute('href') || '',
                  imageURL: linkImage ? (linkImage.getAttribute('src') || '') : ''
                };
              }).filter(item => item.url);

              panels.push({ title: title, body: body, imageURL: imageURL, links: links });
            }

            return panels;
          }

          function postPanels() {
            const panels = extractPanels();
            try {
              window.webkit.messageHandlers.aboutPanels.postMessage({ panels: panels });
            } catch (_) {}
          }

          postPanels();
          const observer = new MutationObserver(postPanels);
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setTimeout(postPanels, 1000);
          setTimeout(postPanels, 2000);
          setTimeout(postPanels, 4000);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__glitcho_about_scrape && true;", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "aboutPanels" else { return }
        guard let dict = message.body as? [String: Any] else { return }
        guard let items = dict["panels"] as? [[String: Any]] else { return }

        let panels = items.compactMap { item -> ChannelAboutPanel? in
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = (item["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let imageURLString = (item["imageURL"] as? String) ?? ""
            let imageURL = imageURLString.isEmpty ? nil : URL(string: imageURLString)
            let linkItems = item["links"] as? [[String: String]] ?? []
            let links = linkItems.compactMap { link -> ChannelAboutLink? in
                guard let urlString = link["url"], let url = URL(string: urlString) else { return nil }
                let label = (link["title"] ?? urlString).trimmingCharacters(in: .whitespacesAndNewlines)
                let linkImageString = (link["imageURL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let linkImageURL = linkImageString.isEmpty ? nil : URL(string: linkImageString)
                return ChannelAboutLink(title: label.isEmpty ? urlString : label, url: url, imageURL: linkImageURL)
            }
            guard !title.isEmpty || !body.isEmpty || !links.isEmpty else { return nil }
            return ChannelAboutPanel(title: title, body: body, imageURL: imageURL, links: links)
        }

        DispatchQueue.main.async {
            self.panels = panels
            self.isLoading = false
        }
    }
}

struct ChannelAboutScraperView: NSViewRepresentable {
    @ObservedObject var store: ChannelAboutStore

    func makeNSView(context: Context) -> WKWebView {
        let view = store.attachWebView()
        view.isHidden = false
        view.alphaValue = 0.0
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.isHidden = false
        nsView.alphaValue = 0.0
    }
}

struct ChannelAboutPanelView: View {
    let channelName: String
    @ObservedObject var store: ChannelAboutStore
    let onOpenSubscription: () -> Void
    let onOpenGiftSub: () -> Void

    private let gridColumns = [
        GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("About \(channelName)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Button("Subscribe", action: onOpenSubscription)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Gift Sub", action: onOpenGiftSub)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                if store.isLoading && store.panels.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading channel info…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                } else if store.panels.isEmpty {
                    Text("No channel panels found yet.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                        ForEach(store.panels) { panel in
                            VStack(alignment: .leading, spacing: 10) {
                                if !panel.title.isEmpty {
                                    Text(panel.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                if let imageURL = panel.imageURL {
                                    AsyncImage(url: imageURL) { image in
                                        image
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxHeight: 160)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    } placeholder: {
                                        Color.white.opacity(0.08)
                                            .frame(height: 110)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                }
                                if !panel.body.isEmpty {
                                    Text(panel.body)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.75))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if !panel.links.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(panel.links) { link in
                                            HStack(spacing: 8) {
                                                if let imageURL = link.imageURL {
                                                    AsyncImage(url: imageURL) { image in
                                                        image
                                                            .resizable()
                                                            .scaledToFill()
                                                            .frame(width: 42, height: 42)
                                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                    } placeholder: {
                                                        Color.white.opacity(0.08)
                                                            .frame(width: 42, height: 42)
                                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                    }
                                                }
                                                Link(link.title, destination: link.url)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.purple.opacity(0.9))
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .overlay(
            ChannelAboutScraperView(store: store)
                .frame(width: 0, height: 0)
        )
        .onAppear {
            store.load(channelName: channelName)
        }
        .onChange(of: channelName) { newValue in
            store.load(channelName: newValue)
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

    // Bump this when changing injected cleanup logic so we can re-apply reliably.
    private static let cleanupScriptVersion = "channel-info-cleanup-v4"

    private static let channelInfoCleanupEvalScript = """
    (function() {
      // Allow re-applying the cleanup on demand (Twitch is an SPA).
      try {
        if (window.__glitcho_channel_info_cleanup_apply) {
          window.__glitcho_channel_info_cleanup_apply();
          return;
        }
      } catch (_) {}

      const css = `
        html, body { background: transparent !important; background-color: transparent !important; margin: 0 !important; padding: 0 !important; }
        body, #root, .tw-root, .twilight-minimal-root { background: transparent !important; background-color: transparent !important; }

        /* Hide Twitch chrome */
        header, .top-nav, [data-a-target="top-nav-container"], [data-test-selector="top-nav-container"], [data-a-target="side-nav"], [data-a-target="left-nav"], [data-test-selector="left-nav"], nav[aria-label="Primary Navigation"], #sideNav {
          display: none !important;
          height: 0 !important;
          min-height: 0 !important;
          width: 0 !important;
          min-width: 0 !important;
          opacity: 0 !important;
          pointer-events: none !important;
        }

        /* Hide the channel header/info bar above the About/Schedule/Videos section */
        [data-a-target="channel-header"],
        [data-test-selector="channel-header"],
        [data-a-target="channel-info-bar"],
        [data-test-selector="channel-info-bar"],
        [data-a-target="channel-info-content"],
        [data-test-selector="channel-info-content"],
        [data-a-target="stream-info-card"],
        [data-test-selector="stream-info-card"],
        [data-a-target*="stream-info"],
        [data-a-target*="channel-root"],
        [data-test-selector*="channel-root"],
        [data-test-selector*="channel-header"],
        [data-test-selector*="channel-info-bar"] {
          display: none !important;
          height: 0 !important;
          min-height: 0 !important;
          margin: 0 !important;
          padding: 0 !important;
          opacity: 0 !important;
          pointer-events: none !important;
        }

        /* Hide player + chat; keep About/Schedule/Videos content */
        [data-a-target="video-player"],
        [data-a-target="player-overlay-click-handler"],
        [data-a-target="player"],
        [data-a-target*="player"],
        [data-test-selector*="player"],
        .video-player,
        .persistent-player,
        video {
          display: none !important;
          height: 0 !important;
          min-height: 0 !important;
          visibility: hidden !important;
          opacity: 0 !important;
          pointer-events: none !important;
        }
        [data-a-target="right-column"],
        [data-a-target="chat-shell"],
        aside[aria-label*="Chat"],
        [role="complementary"] {
          display: none !important;
          width: 0 !important;
          min-width: 0 !important;
          opacity: 0 !important;
          pointer-events: none !important;
        }

        /* Expand main content */
        main, [data-test-selector="main-page-scrollable-area"], [data-a-target="content"], .root-scrollable {
          margin: 0 !important;
          padding: 0 !important;
          max-width: 100% !important;
        }
      `;

      function ensureStyle() {
        let style = document.getElementById('glitcho-channel-info-cleanup-style');
        if (!style) {
          style = document.createElement('style');
          style.id = 'glitcho-channel-info-cleanup-style';
          style.textContent = css;
          (document.head || document.documentElement).appendChild(style);
        }
      }

      function normalize(s) {
        // Keep this simple to avoid fragile unicode escape sequences inside Swift multiline strings.
        try {
          return (s || '').toLowerCase().trim();
        } catch (_) {
          return '';
        }
      }

      function hideEl(el) {
        if (!el) { return; }
        try {
          el.style.display = 'none';
          el.style.height = '0';
          el.style.minHeight = '0';
          el.style.margin = '0';
          el.style.padding = '0';
          el.style.opacity = '0';
          el.style.pointerEvents = 'none';
        } catch (_) {}
      }

      function closestUnderRoot(el, root) {
        if (!el || !root) { return null; }
        let cur = el;
        while (cur && cur.parentElement && cur.parentElement !== root) {
          cur = cur.parentElement;
        }
        return cur && cur.parentElement === root ? cur : null;
      }

      function detectKeepRoot() {
        // Twitch usually renders the channel content inside this scrollable container.
        return document.querySelector('[data-test-selector="main-page-scrollable-area"]')
          || document.querySelector('main')
          || document.querySelector('[role="main"]')
          || null;
      }

      function findTabsAnchor(scope) {
        const root = scope || document;

        // 1) First choice: ARIA tablist (most reliable if present)
        const tablists = Array.from(root.querySelectorAll('[role="tablist"]'));
        for (const tl of tablists) {
          const tabs = tl.querySelectorAll('[role="tab"],a,button');
          if (tabs && tabs.length >= 3) {
            return tl;
          }
        }

        // 2) Next: a nav/container that links to /about /schedule /videos (avoid relying on visible text)
        const containers = Array.from(root.querySelectorAll('nav,section,div'));
        for (const c of containers) {
          const hrefs = Array.from(c.querySelectorAll('a[href]'))
            .map(a => (a.getAttribute('href') || '').toLowerCase());
          if (!hrefs.length) { continue; }
          const hasAbout = hrefs.some(h => h.includes('/about'));
          const hasSchedule = hrefs.some(h => h.includes('/schedule'));
          const hasVideos = hrefs.some(h => h.includes('/videos'));
          if (hasAbout && (hasSchedule || hasVideos)) {
            return c;
          }
        }

        // 3) Last resort: an "About <channel>" heading
        const headings = Array.from(root.querySelectorAll('h1,h2,h3,[role="heading"]'));
        for (const h of headings) {
          const t = normalize(h.textContent);
          if (!t) continue;
          if (t.startsWith('about') || t.startsWith('a propos') || t.startsWith('à propos')) {
            return h;
          }
        }

        return null;
      }

      function keepOnlyPathTo(target) {
        if (!target || !document.body) { return; }

        const path = [];
        let cur = target;
        while (cur && cur !== document.body) {
          path.push(cur);
          cur = cur.parentElement;
        }
        path.push(document.body);

        const pathSet = new Set(path);

        // Hide everything that is not on the ancestor chain to target.
        for (let i = 0; i < path.length - 1; i++) {
          const node = path[i];
          const parent = node.parentElement;
          if (!parent) { continue; }
          Array.from(parent.children).forEach(child => {
            if (child !== node && !pathSet.has(child)) {
              hideEl(child);
            }
          });
        }

        // Also hide any remaining body children not on the path.
        Array.from(document.body.children).forEach(child => {
          if (!pathSet.has(child) && !child.contains(target)) {
            hideEl(child);
          }
        });
      }

      function hidePrecedingSiblings(root, anchor) {
        if (!root || !anchor) { return; }

        // Hide everything that comes before the anchor at each nesting level.
        // This reliably removes the channel header/info bar even when Twitch nests it
        // in the same React tree as the tab bar.
        let cur = anchor;
        while (cur && cur !== root) {
          const parent = cur.parentElement;
          if (!parent) { break; }
          let sib = parent.firstElementChild;
          while (sib && sib !== cur) {
            hideEl(sib);
            sib = sib.nextElementSibling;
          }
          cur = parent;
        }
      }

      function apply() {
        const keepRoot = detectKeepRoot();
        if (!keepRoot) {
          try { document.body && document.body.classList.add('glitcho-ready'); } catch (_) {}
          return;
        }

        try { ensureStyle(); } catch (_) {}
        try { keepOnlyPathTo(keepRoot); } catch (_) {}

        const anchor = findTabsAnchor(keepRoot);
        if (anchor) {
          try { hidePrecedingSiblings(keepRoot, anchor); } catch (_) {}
        }

        try { document.body && document.body.classList.add('glitcho-ready'); } catch (_) {}
      }

      window.__glitcho_channel_info_cleanup_apply = apply;
      apply();
      const observer = new MutationObserver(apply);
      observer.observe(document.documentElement, { childList: true, subtree: true });

      // SPA URL changes
      let lastUrl = location.href;
      setInterval(function() {
        const url = location.href;
        if (url !== lastUrl) {
          lastUrl = url;
          apply();
        }
      }, 400);
    })();
    """

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

        private func log(_ message: String) {
            print("[ChannelInfoView] \(message)")
        }

        private func debugSnapshot(_ webView: WKWebView, label: String) {
            let url = webView.url?.absoluteString ?? "nil"
            log("\(label) url=\(url)")
            let js = """
            (function() {
              const ready = !!(document.body && document.body.classList.contains('glitcho-ready'));
              const root = !!document.getElementById('glitcho-about-root');
              const lastErr = window.__glitcho_lastError || null;
              const bodyLen = (document.body && document.body.innerText) ? document.body.innerText.length : 0;
              const title = document.title || null;
              return { ready, root, lastErr, bodyLen, title };
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, error in
                if let error {
                    self?.log("debug js error: \(error.localizedDescription)")
                    return
                }
                if let dict = result as? [String: Any] {
                    self?.log("debug state: \(dict)")
                    return
                }
                self?.log("debug state: \(result ?? "nil")")
            }
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
            case "recordStream":
                DispatchQueue.main.async { self.onRecordRequest() }
            default:
                return
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            debugSnapshot(webView, label: "didFinish")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("didFail: \(error.localizedDescription)")
            debugSnapshot(webView, label: "didFail")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("didFailProvisional: \(error.localizedDescription)")
            debugSnapshot(webView, label: "didFailProvisional")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            log("webContentProcessDidTerminate")
            debugSnapshot(webView, label: "didTerminate")

            // Twitch can occasionally crash/restart the web content process.
            // When that happens the view can remain blank (black) unless we reload.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                webView.reload()
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
        contentController.add(context.coordinator, name: "recordStream")

        let debugScript = WKUserScript(
            source: """
            (function() {
              if (window.__glitcho_debug) { return; }
              window.__glitcho_debug = true;
              window.__glitcho_lastError = null;
              window.addEventListener('error', function(e) {
                try {
                  window.__glitcho_lastError = (e.message || 'error') + ' @ ' + (e.filename || '') + ':' + (e.lineno || '') + ':' + (e.colno || '');
                } catch (_) {}
              });
              window.addEventListener('unhandledrejection', function(e) {
                try {
                  var reason = e && e.reason;
                  window.__glitcho_lastError = 'promise rejection: ' + (reason && reason.message ? reason.message : String(reason));
                } catch (_) {}
              });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )

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

        // Keep page visible; extraction runs opportunistically.
        let initialHideScript = WKUserScript(
            source: """
            (function() {
              if (document.getElementById('glitcho-channel-hide')) { return; }
              const style = document.createElement('style');
              style.id = 'glitcho-channel-hide';
              style.textContent = 'html { background: transparent !important; } body { opacity: 1 !important; } body.glitcho-ready { opacity: 1 !important; }';
              document.documentElement.appendChild(style);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )

        // Script to show only the About content and keep it at the top.
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
                    /* Neutralize overlays */
                    body::before, body::after,
                    #root::before, #root::after {
                        background: transparent !important;
                        background-color: transparent !important;
                    }
                    footer { display: none !important; }
                    /* Hide player/chat if they appear */
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
                    /* Keep content flush to top */
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
                    /* Action buttons (Follow / notif / Gift / Resubscribe) */
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
                    /* Hide the top channel header block */
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

                function findPanelsContainer(main) {
                    const root = main || document;
                    const selectors = [
                        '[data-a-target="channel-panels"]',
                        '[data-test-selector="channel-panels"]',
                        '[data-a-target*="about-panel"]',
                        '[data-test-selector*="about-panel"]',
                        '[data-a-target="channel-info-content"]',
                        '[data-test-selector="channel-info-content"]',
                        'section[aria-label*="About"]',
                        'section[aria-label*="À propos"]',
                        'section[aria-label*="A propos"]'
                    ];
                    for (const sel of selectors) {
                        const hit = root.querySelector(sel);
                        if (hit) { return hit; }
                    }
                    return null;
                }

                function findAboutMarker(main) {
                    const headingish = Array.from(main.querySelectorAll('h1,h2,h3,[role="heading"]'));
                    const direct = headingish.find(el => isAboutText(el.textContent));
                    if (direct) { return direct; }

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

                function sanitizeHTML(html) {
                    if (!html) { return ''; }
                    return String(html)
                      .replace(/<script[\\s\\S]*?<\\/script>/gi, '')
                      .replace(/<style[\\s\\S]*?<\\/style>/gi, '');
                }

                function extractAboutOnly() {
                    const main = document.querySelector('main') || document.querySelector('[role="main"]') || document.body;
                    if (!main) { return false; }
                    let container = findPanelsContainer(main);
                    if (!container) {
                        const marker = findAboutMarker(main);
                        if (!marker) { return false; }
                        container = pickAboutContainer(marker, main);
                        if (!container) { return false; }
                    }

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

                    try {
                        const root = document.createElement('div');
                        root.id = 'glitcho-about-root';
                        const shell = document.createElement('div');
                        shell.setAttribute('data-glitcho-about-block', '1');
                        if (actionsClone) {
                            actionsClone.setAttribute('data-glitcho-actions', '1');
                            actionsClone.style.marginBottom = '14px';
                        }

                        const contentWrapper = document.createElement('div');
                        contentWrapper.setAttribute('data-glitcho-about-content', '1');
                        const rawHTML = sanitizeHTML(container.innerHTML || container.outerHTML || '');
                        contentWrapper.innerHTML = rawHTML;

                        if (actionsClone) {
                            shell.appendChild(actionsClone);
                        }
                        shell.appendChild(contentWrapper);
                        root.appendChild(shell);
                        document.body.innerHTML = '';
                        document.body.appendChild(root);

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
                            const li = el.closest('li');
                            if (li) {
                              li.remove();
                            } else {
                              const wrapper = el.closest('div') || el;
                              wrapper.remove();
                            }
                          }
                        });

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

                        try {
                          const allowed = new Set(['about', 'a propos', 'à propos', 'schedule', 'videos', 'vidéos']);
                          const tabs = Array.from(root.querySelectorAll('[role="tab"], a, button'));
                          tabs.forEach(el => {
                            const t = norm(el.textContent);
                            if (!t) { return; }
                            if (t === 'home' || t === 'chat' || t === 'following') { return; }
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

                        try {
                          const isEmptyish = (el) => {
                            if (!el) return true;
                            const text = norm(el.textContent || '');
                            const hasMedia = !!el.querySelector('img,svg,video,audio,button,[role="button"],a');
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
                const maxTries = 60;
                const timer = setInterval(() => {
                    ensureStyle();
                    const ok = extractAboutOnly();
                    tries++;
                    if (ok || tries >= maxTries) {
                        clearInterval(timer);
                        document.body.classList.add('glitcho-ready');
                        if (!ok) {
                            try {
                                document.body.style.opacity = '1';
                            } catch (_) {}
                        }
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
                // Keep this simple to avoid fragile unicode escape sequences inside Swift multiline strings.
                try {
                  return (s || '').toLowerCase().trim();
                } catch (_) {
                  return '';
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
                // Keep this simple to avoid fragile unicode escape sequences inside Swift multiline strings.
                try {
                  return (s || '').toLowerCase().trim();
                } catch (_) {
                  return '';
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

              function findActionsContainer(root) {
                if (!root) { return null; }
                return root.querySelector('[data-glitcho-actions="1"]') || root;
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

              function insertRecordButton() {
                const root = rootNode();
                if (!root) { return; }
                if (root.querySelector('[data-glitcho-record="1"]')) { return; }
                const container = findActionsContainer(root);
                if (!container) { return; }
                const button = document.createElement('button');
                button.type = 'button';
                button.setAttribute('data-glitcho-record', '1');
                button.style.display = 'inline-flex';
                button.style.alignItems = 'center';
                button.style.gap = '6px';
                const dot = document.createElement('span');
                dot.textContent = '●';
                dot.style.color = '#ff4d4d';
                dot.style.fontSize = '12px';
                const label = document.createElement('span');
                label.textContent = 'Record';
                button.appendChild(dot);
                button.appendChild(label);
                button.addEventListener('click', function(e) {
                  e.preventDefault();
                  e.stopPropagation();
                  try {
                    window.webkit.messageHandlers.recordStream.postMessage({ login: login });
                  } catch (_) {}
                }, true);
                container.appendChild(button);
              }

              function decorate() {
                if (!rootNode()) { return; }
                ensureStyle();
                purgeRecordButtons();
                decorateBellButton();
                insertRecordButton();
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

        let revealFallbackScript = WKUserScript(
            source: """
            (function() {
              if (window.__glitcho_ready_failsafe) { return; }
              window.__glitcho_ready_failsafe = true;
              setTimeout(function() {
                try { document.body && document.body.classList.add('glitcho-ready'); } catch (_) {}
              }, 3000);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        contentController.addUserScript(debugScript)
        contentController.addUserScript(initialHideScript)
        contentController.addUserScript(blockMediaScript)
        contentController.addUserScript(aboutOnlyScript)
        contentController.addUserScript(subscriptionInterceptScript)
        contentController.addUserScript(giftInterceptScript)
        contentController.addUserScript(blockChannelLinksScript)
        contentController.addUserScript(channelActionsScript)
        contentController.addUserScript(revealFallbackScript)
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        
        // Load the About page (users can switch tabs to Videos/Schedule)
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
        let enabled = notificationEnabled ? "true" : "false"
        let js = "window.__glitcho_setBellState && window.__glitcho_setBellState('\(normalized)', \(enabled));"
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

#endif
