#if canImport(SwiftUI)
import Foundation
import AppKit
import AVKit
import Darwin
import Metal
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
        let resolvedTarget: String = {
            let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("http://") || t.hasPrefix("https://") { return t }
            return "https://\(t)"
        }()

        let authArgs = await streamlinkAuthArgumentsIfAvailable(for: resolvedTarget)

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

                // Streamlink options first, then URL + quality.
                process.arguments = [
                    "--stream-url",
                    "--twitch-disable-ads",
                    "--twitch-low-latency"
                ] + authArgs + [
                    resolvedTarget,
                    quality
                ]

                process.standardOutput = pipe
                process.standardError = errorPipe

                do {
                    self.process = process
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let stdoutOutput = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus == 0, let url = URL(string: stdoutOutput) {
                        continuation.resume(returning: url)
                    } else {
                        // NOTE: streamlink often prints errors to STDOUT (not STDERR).
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                        var message = stderrOutput
                        if message.isEmpty {
                            message = stdoutOutput
                        }
                        if message.isEmpty {
                            message = "Streamlink failed (exit code \(process.terminationStatus))."
                        }

                        // Try TwitchNoSub fallback for subscriber-only VODs
                        if let vodId = self.extractVODId(from: resolvedTarget) {

                            // Use a detached task to avoid continuation issues
                            Task.detached { [weak self] in
                                guard let self = self else {
                                    continuation.resume(throwing: NSError(
                                        domain: "StreamlinkError",
                                        code: Int(process.terminationStatus),
                                        userInfo: [NSLocalizedDescriptionKey: message]
                                    ))
                                    return
                                }

                                do {
                                    let mutedURL = try await self.generateMutedVODPlaylist(vodId: vodId)
                                    continuation.resume(returning: mutedURL)
                                } catch {
                                    let fallbackError = NSError(
                                        domain: "TwitchNoSub",
                                        code: Int(process.terminationStatus),
                                        userInfo: [NSLocalizedDescriptionKey: "Streamlink failed and TwitchNoSub fallback also failed: \(error.localizedDescription)"]
                                    )
                                    continuation.resume(throwing: fallbackError)
                                }
                            }
                        } else {
                            continuation.resume(throwing: NSError(
                                domain: "StreamlinkError",
                                code: Int(process.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: message]
                            ))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func streamlinkAuthArgumentsIfAvailable(for resolvedTarget: String) async -> [String] {
        guard let url = URL(string: resolvedTarget) else { return [] }
        let host = (url.host ?? "").lowercased()
        let isTwitch = host.hasSuffix("twitch.tv") || host == "clips.twitch.tv"
        guard isTwitch else { return [] }

        let cookies = await webKitCookies()
        let authTokenCookieNames: Set<String> = ["auth-token", "auth_token", "auth-token-next", "auth_token_next"]
        let token = cookies.first(where: {
            authTokenCookieNames.contains($0.name.lowercased()) && $0.domain.lowercased().contains("twitch.tv")
        })?.value

        guard let token, !token.isEmpty else {
            return []
        }

        // Twitch web uses an OAuth token (stored in cookies when logged in). Streamlink can forward this via API headers.
        return [
            "--twitch-api-header",
            "Authorization=OAuth \(token)",
        ]
    }


    // MARK: - TwitchNoSub Fallback for Subscriber-Only VODs

    private func extractVODId(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let components = url.path.split(separator: "/").map(String.init)
        if components.count >= 2, components[0].lowercased() == "videos" {
            return components[1]
        }
        return nil
    }

    private func fetchTwitchVODMetadata(vodId: String) async throws -> (domain: String, vodSpecialId: String, broadcastType: String, channelLogin: String, createdAt: Date) {
        let query = #"query { video(id: "\#(vodId)") { broadcastType, createdAt, seekPreviewsURL, owner { login } }}"#
        let body = ["query": query]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let videoData = json?["data"] as? [String: Any],
              let video = videoData["video"] as? [String: Any],
              let seekPreviewsURL = video["seekPreviewsURL"] as? String,
              let broadcastType = video["broadcastType"] as? String,
              let createdAtString = video["createdAt"] as? String,
              let owner = video["owner"] as? [String: Any],
              let channelLogin = owner["login"] as? String,
              let previewURL = URL(string: seekPreviewsURL) else {
            throw NSError(domain: "TwitchNoSub", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to fetch VOD metadata"])
        }

        let domain = previewURL.host ?? ""
        let pathComponents = previewURL.pathComponents
        guard let storyboardIndex = pathComponents.firstIndex(where: { $0.contains("storyboards") }),
              storyboardIndex > 0 else {
            throw NSError(domain: "TwitchNoSub", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to parse VOD URL structure"])
        }
        let vodSpecialId = pathComponents[storyboardIndex - 1]

        let formatter = ISO8601DateFormatter()
        let createdAt = formatter.date(from: createdAtString) ?? Date()

        return (domain, vodSpecialId, broadcastType, channelLogin, createdAt)
    }

    private func generateMutedVODPlaylist(vodId: String) async throws -> URL {
        let metadata = try await fetchTwitchVODMetadata(vodId: vodId)

        let now = Date()
        let daysSinceCreation = now.timeIntervalSince(metadata.createdAt) / (24 * 3600)
        let broadcastType = metadata.broadcastType.lowercased()

        // Try to find the best available quality
        let qualities = ["chunked", "1080p60", "720p60", "480p30", "360p30"]

        for quality in qualities {
            let playlistURL: String

            if broadcastType == "highlight" {
                playlistURL = "https://\(metadata.domain)/\(metadata.vodSpecialId)/\(quality)/highlight-\(vodId).m3u8"
            } else if broadcastType == "upload" && daysSinceCreation > 7 {
                playlistURL = "https://\(metadata.domain)/\(metadata.channelLogin)/\(vodId)/\(metadata.vodSpecialId)/\(quality)/index-dvr.m3u8"
            } else {
                playlistURL = "https://\(metadata.domain)/\(metadata.vodSpecialId)/\(quality)/index-dvr.m3u8"
            }

            // Test if the quality exists
            guard let url = URL(string: playlistURL) else { continue }

            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    return url
                }
            } catch {
                continue
            }
        }

        throw NSError(domain: "TwitchNoSub", code: 3, userInfo: [NSLocalizedDescriptionKey: "No working quality found for VOD"])
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

        if let path = Glitcho.resolveExecutable(named: "streamlink") {
            return URL(fileURLWithPath: path)
        }

        throw streamlinkError("Streamlink not found. Install it or set a custom path in Settings.")
    }

    private func resolveFFmpegExecutable() -> URL? {
        if let custom = resolvedCustomPath(forKey: ffmpegPathKey), isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if let path = Glitcho.resolveExecutable(named: "ffmpeg") {
            return URL(fileURLWithPath: path)
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

private struct NativeHoverPlayerView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        let player = AVPlayer()
        let view = AVPlayerView()
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.view.controlsStyle = .none
        coordinator.view.showsFullScreenToggleButton = false
        coordinator.view.player = coordinator.player
        coordinator.view.videoGravity = .resizeAspectFill
        return coordinator
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = context.coordinator.view
        view.player = context.coordinator.player
        context.coordinator.player.isMuted = true
        context.coordinator.player.volume = 0
        context.coordinator.player.replaceCurrentItem(with: AVPlayerItem(url: url))
        context.coordinator.player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let current = (context.coordinator.player.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            context.coordinator.player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        context.coordinator.player.isMuted = true
        context.coordinator.player.volume = 0
        context.coordinator.player.play()
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player.pause()
        coordinator.player.replaceCurrentItem(with: nil)
    }
}

private func isStreamOfflineErrorMessage(_ message: String) -> Bool {
    let s = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.isEmpty { return false }

    // Streamlink commonly returns something like:
    // "error: No playable streams found on this URL"
    // when a Twitch channel is offline.
    let offlineMarkers: [String] = [
        "no playable streams found",
        "no streams found",
        "the channel is offline",
        "is offline",
        "not live",
        "not currently live",
        "stream is offline",
        "hors ligne"
    ]

    return offlineMarkers.contains(where: { s.contains($0) })
}

enum VideoAspectCropMode: String, CaseIterable, Hashable {
    case source
    case aspect21x9
    case aspect32x9

    var label: String {
        switch self {
        case .source:
            return "Auto"
        case .aspect21x9:
            return "21:9"
        case .aspect32x9:
            return "32:9"
        }
    }

    var targetAspectRatio: CGFloat? {
        switch self {
        case .source:
            return nil
        case .aspect21x9:
            return 21.0 / 9.0
        case .aspect32x9:
            return 32.0 / 9.0
        }
    }
}

struct MotionSmootheningCapability: Equatable {
    struct Environment: Equatable {
        let refreshRate: Int
        let hasMetalDevice: Bool
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
        let supportsAIInterpolation: Bool
    }

    let supported: Bool
    let aiInterpolationSupported: Bool
    let maxRefreshRate: Int
    let reason: String

    var targetRefreshRate: Int {
        max(60, min(maxRefreshRate, 120))
    }

    static func evaluate(screen: NSScreen?) -> MotionSmootheningCapability {
        let refresh = max(0, screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        return evaluate(
            environment: .init(
                refreshRate: refresh,
                hasMetalDevice: MTLCreateSystemDefaultDevice() != nil,
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState,
                supportsAIInterpolation: MotionAIInterpolationSupport.isAvailable()
            )
        )
    }

    static func evaluate(environment: Environment) -> MotionSmootheningCapability {
        let refresh = max(0, environment.refreshRate)
        guard refresh >= 60 else {
            return MotionSmootheningCapability(
                supported: false,
                aiInterpolationSupported: false,
                maxRefreshRate: refresh,
                reason: "Display refresh rate is \(refresh)Hz. 60Hz+ is required."
            )
        }
        guard environment.hasMetalDevice else {
            return MotionSmootheningCapability(
                supported: false,
                aiInterpolationSupported: false,
                maxRefreshRate: refresh,
                reason: "Metal GPU support is unavailable on this device."
            )
        }
        guard environment.supportsAIInterpolation else {
            return MotionSmootheningCapability(
                supported: false,
                aiInterpolationSupported: false,
                maxRefreshRate: refresh,
                reason: "AI interpolation is unavailable on this device."
            )
        }
        if environment.lowPowerModeEnabled {
            return MotionSmootheningCapability(
                supported: false,
                aiInterpolationSupported: true,
                maxRefreshRate: refresh,
                reason: "Low Power Mode is enabled."
            )
        }
        let thermal = environment.thermalState
        if thermal == .serious || thermal == .critical {
            return MotionSmootheningCapability(
                supported: false,
                aiInterpolationSupported: true,
                maxRefreshRate: refresh,
                reason: "Thermal state is \(thermal.description)."
            )
        }
        return MotionSmootheningCapability(
            supported: true,
            aiInterpolationSupported: true,
            maxRefreshRate: refresh,
            reason: "AI motion smoothening available."
        )
    }
}

private extension ProcessInfo.ThermalState {
    var description: String {
        switch self {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}

/// Vue player vidéo natif avec AVPlayer
struct NativeVideoPlayer: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var volume: Double
    @Binding var muted: Bool
    @Binding var fullscreenRequestToken: Int
    let pipController: PictureInPictureController?

    /// Digital zoom (1.0 = normal). Applied to the underlying video layer (not the whole UI).
    @Binding var zoom: CGFloat
    /// Pan offset in points (only meaningful when zoom > 1).
    @Binding var pan: CGSize
    var motionSmootheningEnabled: Bool = false
    var motionCapability: MotionSmootheningCapability = MotionSmootheningCapability.evaluate(screen: nil)
    var motionConfiguration: MotionInterpolationConfiguration = .productionDefault
    var videoAspectMode: VideoAspectCropMode = .source
    var upscaler4KEnabled: Bool = false
    var imageOptimizeEnabled: Bool = false
    var imageOptimizationConfiguration: ImageOptimizationConfiguration = .productionDefault

    var minZoom: CGFloat = 1.0
    var maxZoom: CGFloat = 4.0

    init(
        url: URL,
        isPlaying: Binding<Bool>,
        volume: Binding<Double> = .constant(1.0),
        muted: Binding<Bool> = .constant(false),
        fullscreenRequestToken: Binding<Int> = .constant(0),
        pipController: PictureInPictureController? = nil,
        zoom: Binding<CGFloat> = .constant(1.0),
        pan: Binding<CGSize> = .constant(.zero),
        motionSmootheningEnabled: Bool = false,
        motionCapability: MotionSmootheningCapability = MotionSmootheningCapability.evaluate(screen: nil),
        motionConfiguration: MotionInterpolationConfiguration = .productionDefault,
        videoAspectMode: VideoAspectCropMode = .source,
        upscaler4KEnabled: Bool = false,
        imageOptimizeEnabled: Bool = false,
        imageOptimizationConfiguration: ImageOptimizationConfiguration = .productionDefault,
        minZoom: CGFloat = 1.0,
        maxZoom: CGFloat = 4.0
    ) {
        self.url = url
        self._isPlaying = isPlaying
        self._volume = volume
        self._muted = muted
        self._fullscreenRequestToken = fullscreenRequestToken
        self.pipController = pipController
        self._zoom = zoom
        self._pan = pan
        self.motionSmootheningEnabled = motionSmootheningEnabled
        self.motionCapability = motionCapability
        self.motionConfiguration = motionConfiguration
        self.videoAspectMode = videoAspectMode
        self.upscaler4KEnabled = upscaler4KEnabled
        self.imageOptimizeEnabled = imageOptimizeEnabled
        self.imageOptimizationConfiguration = imageOptimizationConfiguration
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
        private var lastAppliedZoom: CGFloat = -.greatestFiniteMagnitude
        private var lastAppliedPan: CGSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        private var lastAppliedBounds: CGRect = .zero
        private var lastPlaybackState: Bool?
        private var lastMotionEnabled: Bool?
        private var lastMotionSupportReason: String?
        private var lastMotionPipelineSignature: MotionPipelineSignature?
        private var lastAspectMode: VideoAspectCropMode = .source
        private var lastUpscalerEnabled = false
        private var lastImageOptimizeEnabled = false
        private var lastImageOptimizationConfiguration = ImageOptimizationConfiguration.productionDefault
        private var lastAppliedVolume: Double = -1
        private var lastAppliedMuted = false
        private var lastFullscreenRequestToken: Int
        let interpolationController = MotionInterpolationController()

        weak var resolvedVideoLayer: CALayer?
        weak var playerView: ZoomableAVPlayerView?

        struct MotionPipelineSignature: Equatable {
            let processingEnabled: Bool
            let interpolationEnabled: Bool
            let upscalerEnabled: Bool
            let imageOptimizeEnabled: Bool
            let itemID: ObjectIdentifier?
        }

        init(parent: NativeVideoPlayer, pipController: PictureInPictureController?) {
            self.parent = parent
            self.pipController = pipController
            self.lastFullscreenRequestToken = parent.fullscreenRequestToken
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            if gestureRecognizer is NSPanGestureRecognizer {
                guard parent.zoom > (parent.minZoom + 0.001) else { return false }
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
                parent.pan = clampPan(parent.pan, in: bounds, zoom: parent.zoom, videoLayer: resolveVideoLayer(in: view))
                applyZoomAndPan(to: view)
            case .ended, .cancelled, .failed:
                parent.zoom = clampZoom(parent.zoom)
                parent.pan = clampPan(parent.pan, in: bounds, zoom: parent.zoom, videoLayer: resolveVideoLayer(in: view))
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
                let clamped = clampPan(raw, in: bounds, zoom: parent.zoom, videoLayer: resolveVideoLayer(in: view))
                if parent.pan != clamped {
                    parent.pan = clamped
                }
                applyZoomAndPan(to: view)
            case .ended, .cancelled, .failed:
                parent.pan = clampPan(parent.pan, in: bounds, zoom: parent.zoom, videoLayer: resolveVideoLayer(in: view))
                applyZoomAndPan(to: view)
            default:
                break
            }
        }

        @objc func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let view = recognizer.view as? AVPlayerView else { return }
            parent.zoom = parent.zoom <= (parent.minZoom + 0.01) ? min(max(parent.minZoom * 2.0, 2.0), parent.maxZoom) : parent.minZoom
            parent.pan = .zero
            applyZoomAndPan(to: view)
        }

        func applyZoomAndPan(to view: AVPlayerView) {
            view.wantsLayer = true
            view.layer?.masksToBounds = true

            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            let z = clampZoom(parent.zoom)
            guard let videoLayer = resolveVideoLayer(in: view) else { return }
            let effectiveZoom = z * aspectCropZoomMultiplier(videoLayer: videoLayer, bounds: bounds)
            let p = clampPan(parent.pan, in: bounds, zoom: effectiveZoom, videoLayer: videoLayer)

            if parent.pan != p {
                parent.pan = p
            }
            if abs(lastAppliedZoom - z) < 0.0001,
               abs(lastAppliedPan.width - p.width) < 0.25,
               abs(lastAppliedPan.height - p.height) < 0.25,
               abs(lastAppliedBounds.width - bounds.width) < 0.25,
               abs(lastAppliedBounds.height - bounds.height) < 0.25,
               lastAspectMode == parent.videoAspectMode,
               lastUpscalerEnabled == parent.upscaler4KEnabled,
               lastImageOptimizeEnabled == parent.imageOptimizeEnabled,
               lastImageOptimizationConfiguration == parent.imageOptimizationConfiguration {
                return
            }

            let containerBounds = videoLayer.superlayer?.bounds ?? view.layer?.bounds ?? bounds
            let center = CGPoint(x: containerBounds.midX, y: containerBounds.midY)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            videoLayer.position = CGPoint(x: center.x + p.width, y: center.y + p.height)
            videoLayer.setAffineTransform(CGAffineTransform(scaleX: effectiveZoom, y: effectiveZoom))
            CATransaction.commit()

            lastAppliedZoom = z
            lastAppliedPan = p
            lastAppliedBounds = bounds
            lastAspectMode = parent.videoAspectMode
            lastUpscalerEnabled = parent.upscaler4KEnabled
            lastImageOptimizeEnabled = parent.imageOptimizeEnabled
            lastImageOptimizationConfiguration = parent.imageOptimizationConfiguration
            interpolationController.updateViewport(
                zoom: z,
                pan: p,
                aspectMode: parent.videoAspectMode,
                upscaler4KEnabled: parent.upscaler4KEnabled,
                imageOptimizeEnabled: parent.imageOptimizeEnabled,
                imageOptimizationConfiguration: parent.imageOptimizationConfiguration
            )
        }

        func updatePlaybackStateIfNeeded(on view: AVPlayerView) {
            guard let player = view.player else { return }
            if lastPlaybackState == parent.isPlaying {
                return
            }
            lastPlaybackState = parent.isPlaying
            if parent.isPlaying {
                player.play()
            } else {
                player.pause()
            }
        }

        func applyMotionSettingsIfNeeded(to view: AVPlayerView) {
            guard let player = view.player else { return }
            let interpolationEnabled = parent.motionSmootheningEnabled && parent.motionCapability.supported
            let allowProcessingWithoutAI = (parent.upscaler4KEnabled || parent.imageOptimizeEnabled) && !parent.motionCapability.aiInterpolationSupported
            let isEnabled = interpolationEnabled || parent.upscaler4KEnabled || parent.imageOptimizeEnabled
            let supportReason = parent.motionCapability.reason
            let nextPipelineSignature = MotionPipelineSignature(
                processingEnabled: isEnabled,
                interpolationEnabled: interpolationEnabled,
                upscalerEnabled: parent.upscaler4KEnabled,
                imageOptimizeEnabled: parent.imageOptimizeEnabled,
                itemID: player.currentItem.map(ObjectIdentifier.init)
            )
            let shouldNudgePlayback = Self.shouldNudgePlaybackAfterPipelineChange(
                previous: lastMotionPipelineSignature,
                next: nextPipelineSignature,
                isPlaying: parent.isPlaying
            )
            defer {
                lastMotionPipelineSignature = nextPipelineSignature
            }
            if lastMotionEnabled == isEnabled, lastMotionSupportReason == supportReason {
                if isEnabled {
                    interpolationController.enable(
                        on: view,
                        player: player,
                        capability: parent.motionCapability,
                        configuration: parent.motionConfiguration,
                        interpolationEnabled: interpolationEnabled,
                        imageOptimizeEnabled: parent.imageOptimizeEnabled,
                        imageOptimizationConfiguration: parent.imageOptimizationConfiguration,
                        allowWithoutAISupport: allowProcessingWithoutAI
                    )
                }
                if shouldNudgePlayback {
                    interpolationController.refreshOutput()
                    nudgePlaybackIfNeeded(player)
                }
                return
            }
            lastMotionEnabled = isEnabled
            lastMotionSupportReason = supportReason

            if isEnabled {
                player.automaticallyWaitsToMinimizeStalling = false
                player.currentItem?.preferredForwardBufferDuration = 0
                interpolationController.enable(
                    on: view,
                    player: player,
                    capability: parent.motionCapability,
                    configuration: parent.motionConfiguration,
                    interpolationEnabled: interpolationEnabled,
                    imageOptimizeEnabled: parent.imageOptimizeEnabled,
                    imageOptimizationConfiguration: parent.imageOptimizationConfiguration,
                    allowWithoutAISupport: allowProcessingWithoutAI
                )
                GlitchoTelemetry.track(
                    "motion_smoothening_active",
                    metadata: [
                        "refresh_hz": "\(parent.motionCapability.maxRefreshRate)",
                        "target_hz": "\(parent.motionCapability.targetRefreshRate)",
                        "supported": "true",
                        "ai_supported": parent.motionCapability.aiInterpolationSupported ? "true" : "false",
                        "image_optimize_enabled": parent.imageOptimizeEnabled ? "true" : "false",
                        "upscaler_4k_enabled": parent.upscaler4KEnabled ? "true" : "false",
                        "thermal": ProcessInfo.processInfo.thermalState.description
                    ]
                )
                if shouldNudgePlayback {
                    interpolationController.refreshOutput()
                    nudgePlaybackIfNeeded(player)
                }
            } else {
                player.automaticallyWaitsToMinimizeStalling = true
                player.currentItem?.preferredForwardBufferDuration = 1.5
                interpolationController.disable()
                GlitchoTelemetry.track(
                    "motion_smoothening_fallback",
                    metadata: [
                        "supported": parent.motionCapability.supported ? "true" : "false",
                        "ai_supported": parent.motionCapability.aiInterpolationSupported ? "true" : "false",
                        "image_optimize_enabled": parent.imageOptimizeEnabled ? "true" : "false",
                        "upscaler_4k_enabled": parent.upscaler4KEnabled ? "true" : "false",
                        "reason": supportReason,
                        "thermal": ProcessInfo.processInfo.thermalState.description
                    ]
                )
            }
        }

        static func shouldNudgePlaybackAfterPipelineChange(
            previous: MotionPipelineSignature?,
            next: MotionPipelineSignature,
            isPlaying: Bool
        ) -> Bool {
            guard isPlaying, next.processingEnabled else { return false }
            guard let previous else { return true }
            guard previous != next else { return false }
            if !previous.processingEnabled && next.processingEnabled {
                return true
            }
            if previous.itemID != next.itemID {
                return true
            }
            if previous.interpolationEnabled != next.interpolationEnabled {
                return true
            }
            if previous.upscalerEnabled != next.upscalerEnabled {
                return true
            }
            if previous.imageOptimizeEnabled != next.imageOptimizeEnabled {
                return true
            }
            return false
        }

        private func nudgePlaybackIfNeeded(_ player: AVPlayer) {
            guard parent.isPlaying else { return }
            DispatchQueue.main.async {
                player.playImmediately(atRate: 1.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak player] in
                    guard let player else { return }
                    if player.timeControlStatus != .playing {
                        player.play()
                    }
                }
            }
        }

        func updateAudioStateIfNeeded(on view: AVPlayerView) {
            guard let player = view.player else { return }
            let clampedVolume = max(0.0, min(1.0, parent.volume))
            let shouldMute = parent.muted || clampedVolume <= 0.0001
            if abs(lastAppliedVolume - clampedVolume) < 0.0001, lastAppliedMuted == shouldMute {
                return
            }
            player.volume = Float(clampedVolume)
            player.isMuted = shouldMute
            lastAppliedVolume = clampedVolume
            lastAppliedMuted = shouldMute
        }

        func updatePlayerFullscreenIfNeeded(on view: AVPlayerView) {
            guard parent.fullscreenRequestToken != lastFullscreenRequestToken else { return }
            lastFullscreenRequestToken = parent.fullscreenRequestToken
            DispatchQueue.main.async {
                if view.isInFullScreenMode {
                    view.exitFullScreenMode(options: nil)
                    self.updatePlayerNativeChromeForFullscreenState(on: view)
                    return
                }

                // Native AVPlayerView fullscreen (player-only), with native controls enabled.
                view.controlsStyle = .floating
                view.showsFullScreenToggleButton = true
                view.window?.makeFirstResponder(view)
                if let screen = view.window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
                    view.enterFullScreenMode(screen, withOptions: nil)
                    self.updatePlayerNativeChromeForFullscreenState(on: view)
                } else if let window = view.window ?? NSApp.keyWindow ?? NSApp.mainWindow {
                    // Last-resort fallback if no screen is available.
                    window.toggleFullScreen(nil)
                }
            }
        }

        func updatePlayerNativeChromeForFullscreenState(on view: AVPlayerView) {
            view.controlsStyle = .floating
            view.showsFullScreenToggleButton = true
        }

        private func clampZoom(_ value: CGFloat) -> CGFloat {
            min(max(value, parent.minZoom), parent.maxZoom)
        }

        private func aspectCropZoomMultiplier(videoLayer: CALayer, bounds: CGRect) -> CGFloat {
            guard let targetAspect = parent.videoAspectMode.targetAspectRatio, targetAspect > 0 else {
                return 1.0
            }
            let sourceAspect: CGFloat = {
                if let playerLayer = videoLayer as? AVPlayerLayer {
                    let rect = playerLayer.videoRect
                    if rect.width > 0.1, rect.height > 0.1 {
                        return rect.width / rect.height
                    }
                }
                if bounds.height > 0 {
                    return bounds.width / bounds.height
                }
                return 16.0 / 9.0
            }()
            guard sourceAspect > 0 else { return 1.0 }
            guard targetAspect > sourceAspect else { return 1.0 }
            return targetAspect / sourceAspect
        }

        private func clampPan(_ value: CGSize, in bounds: CGRect, zoom: CGFloat, videoLayer: CALayer?) -> CGSize {
            if zoom <= (parent.minZoom + 0.001) { return .zero }
            let videoSize: CGSize = {
                if let playerLayer = videoLayer as? AVPlayerLayer {
                    let rect = playerLayer.videoRect
                    if rect.width > 0.1, rect.height > 0.1 {
                        return rect.size
                    }
                }
                return bounds.size
            }()

            let maxX = (zoom - 1.0) * videoSize.width / 2.0
            let maxY = (zoom - 1.0) * videoSize.height / 2.0
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
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.masksToBounds = true

        let player = AVPlayer(url: url)
        playerView.player = player

        // Gestures: pinch to zoom, drag to pan, double-click to toggle zoom.
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

        context.coordinator.updatePlaybackStateIfNeeded(on: playerView)
        context.coordinator.updateAudioStateIfNeeded(on: playerView)
        context.coordinator.applyMotionSettingsIfNeeded(to: playerView)

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
        context.coordinator.updatePlayerNativeChromeForFullscreenState(on: playerView)
        context.coordinator.updatePlaybackStateIfNeeded(on: playerView)
        context.coordinator.updateAudioStateIfNeeded(on: playerView)
        context.coordinator.updatePlayerFullscreenIfNeeded(on: playerView)
        context.coordinator.applyMotionSettingsIfNeeded(to: playerView)
        context.coordinator.pipController?.attach(playerView)
        context.coordinator.applyZoomAndPan(to: playerView)
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        if let token = coordinator.endObserver {
            NotificationCenter.default.removeObserver(token)
            coordinator.endObserver = nil
        }
        (playerView as? ZoomableAVPlayerView)?.onLayout = nil
        coordinator.interpolationController.teardown()
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
    @State private var isStreamOffline = false
    
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
                    Text(isStreamOffline ? "Le stream est hors ligne" : "Cliquez pour charger le stream")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.7))

                    Button(isStreamOffline ? "Réessayer" : "Charger avec Streamlink") {
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
        await MainActor.run {
            showError = false
            isStreamOffline = false
            streamlink.error = nil
            streamlink.isLoading = true
        }

        do {
            let url = try await streamlink.getStreamURL(for: channelName)
            await MainActor.run {
                self.streamURL = url
                streamlink.isLoading = false
                isStreamOffline = false
            }
        } catch {
            let message = error.localizedDescription
            let offline = isStreamOfflineErrorMessage(message)
            await MainActor.run {
                streamlink.error = message
                streamlink.isLoading = false
                if offline {
                    isStreamOffline = true
                    showError = false
                } else {
                    showError = true
                }
            }
        }
    }
}

enum ManualRecordingControlAction: Equatable {
    case start
    case stop

    var confirmationTitle: String {
        switch self {
        case .start:
            return "Start Recording?"
        case .stop:
            return "Stop Recording?"
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case .start:
            return "Start Recording"
        case .stop:
            return "Stop Recording"
        }
    }
}

private enum MotionInterpolationPreset: String, CaseIterable, Hashable {
    case quality
    case balanced
    case performance
    case custom

    var label: String {
        switch self {
        case .quality:
            return "Quality"
        case .balanced:
            return "Balanced"
        case .performance:
            return "Performance"
        case .custom:
            return "Custom"
        }
    }
}

private struct MotionRuntimeSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let status: MotionInterpolationRuntimeStatus
}

/// Vue hybride : Player natif + Chat + Infos de la chaîne
struct HybridTwitchView: View {
    @Binding var playback: NativePlaybackRequest
    @ObservedObject var recordingManager: RecordingManager
    var onOpenSubscription: ((String) -> Void)?
    var onOpenGiftSub: ((String) -> Void)?
    var onFollowChannel: ((String) -> Void)?
    var followedChannels: [TwitchChannel] = []
    var notificationEnabled: Bool = true
    var onNotificationToggle: ((Bool) -> Void)?
    var isRecording: Bool = false
    var showRecordingControl: Bool = true
    var onRecordRequest: ((ManualRecordingControlAction) -> Void)?
    @Environment(\.openWindow) private var openWindow
    @StateObject private var streamlink = StreamlinkManager()
    @StateObject private var pipController = PictureInPictureController()
    @State private var streamURL: URL?
    @State private var isPlaying = true
    @State private var showError = false
    @State private var isStreamOffline = false
    @State private var playbackInlineError: String?
    @State private var showChat = true
    @State private var isChatDetached = false
    @State private var detachedChannelName: String?
    @State private var programmaticChatCloseChannel: String?
    @AppStorage("hybridPlayerHeightRatio") private var playerHeightRatio: Double = 0.8
    @AppStorage("hybridDetailsCollapsed") private var isDetailsSectionCollapsed = false
    @State private var dragStartRatio: Double?
    @State private var lastChannelName: String?
    @State private var recordingError: String?
    @AppStorage("player.volume") private var playerVolume = 0.9
    @AppStorage("player.muted") private var playerMuted = false
    @State private var isHoveringVideoSurface = false
    @State private var showOverlayMorePopover = false
    @State private var playerFullscreenRequestToken = 0

    @State private var videoZoom: CGFloat = 1.0
    @State private var videoPan: CGSize = .zero
    @AppStorage("motionSmoothening120Enabled") private var motionSmoothening120Enabled = false
    @AppStorage("video.aspectCropMode") private var videoAspectModeRaw = VideoAspectCropMode.source.rawValue
    @AppStorage("video.upscaler4kEnabled") private var videoUpscaler4KEnabled = false
    @AppStorage("video.imageOptimizeEnabled") private var videoImageOptimizeEnabled = false
    @AppStorage("video.imageOptimize.contrast") private var imageOptimizeContrast = ImageOptimizationConfiguration.productionDefault.contrast
    @AppStorage("video.imageOptimize.lighting") private var imageOptimizeLighting = ImageOptimizationConfiguration.productionDefault.lighting
    @AppStorage("video.imageOptimize.denoiser") private var imageOptimizeDenoiser = ImageOptimizationConfiguration.productionDefault.denoiser
    @AppStorage("video.imageOptimize.neuralClarity") private var imageOptimizeNeuralClarity = ImageOptimizationConfiguration.productionDefault.neuralClarity
    @AppStorage("motionSmoothening.autoPreset") private var motionAutoPresetEnabled = true
    @AppStorage("motionSmoothening.preset") private var motionPresetRaw = MotionInterpolationPreset.balanced.rawValue
    @AppStorage("motionSmoothening.forceFrameGenDebug") private var motionForceFrameGenDebug = false
    @AppStorage("motionSmoothening.lowMotionThreshold") private var motionLowMotionThreshold = 0.08
    @AppStorage("motionSmoothening.highMotionThreshold") private var motionHighMotionThreshold = 3.2
    @AppStorage("motionSmoothening.extremeMotionThreshold") private var motionExtremeMotionThreshold = 7.5
    @AppStorage("motionSmoothening.midpointShiftFactor") private var motionMidpointShiftFactor = 0.5
    @AppStorage("motionSmoothening.maxShiftPixels") private var motionMaxShiftPixels = 20.0
    @AppStorage("motionSmoothening.maxInterpolationBudgetMs") private var motionMaxInterpolationBudgetMs = 7.8
    @AppStorage("motionSmoothening.slowFramesForGuardrail") private var motionSlowFramesForGuardrail = 3
    @AppStorage("motionSmoothening.overloadDurationSeconds") private var motionOverloadDurationSeconds = 6.0
    @AppStorage("motionSmoothening.cpuPressurePercent") private var motionCpuPressurePercent = 78.0
    @State private var motionCapability = MotionSmootheningCapability.evaluate(screen: NSScreen.main)
    @State private var motionRuntimeStatus: MotionInterpolationRuntimeStatus?
    @State private var motionRuntimeSamples: [MotionRuntimeSample] = []
    @State private var suppressMotionPresetAutoCustom = false
    @StateObject private var aboutStore = AboutTabStore()
    @StateObject private var videosStore = ChannelVideosStore()
    @StateObject private var scheduleStore = ChannelScheduleStore()

    private enum ChannelDetailsTab: String, CaseIterable {
        case about = "About"
        case videos = "Videos"
        case schedule = "Schedule"
    }

    @State private var detailsTab: ChannelDetailsTab = .about

    private enum ChatDisplayMode: String {
        case inline
        case hidden
        case detached
    }

    private static let chatPreferencesKey = "glitcho.chatPreferencesByChannel"

    private var motionPreset: MotionInterpolationPreset {
        MotionInterpolationPreset(rawValue: motionPresetRaw) ?? .balanced
    }

    private var motionPresetBinding: Binding<MotionInterpolationPreset> {
        Binding(
            get: { motionPreset },
            set: { next in
                guard next != motionPreset else { return }
                motionAutoPresetEnabled = false
                motionPresetRaw = next.rawValue
                if next != .custom {
                    applyMotionPreset(next)
                }
                trackMotionConfigurationChange(trigger: "preset")
            }
        )
    }

    private var motionConfiguration: MotionInterpolationConfiguration {
        let low = max(0.01, min(Float(motionLowMotionThreshold), Float(motionHighMotionThreshold - 0.05)))
        let high = max(low + 0.05, min(Float(motionHighMotionThreshold), Float(motionExtremeMotionThreshold - 0.05)))
        let extreme = max(high + 0.1, Float(motionExtremeMotionThreshold))
        return MotionInterpolationConfiguration(
            lowMotionThreshold: low,
            highMotionThreshold: high,
            extremeMotionThreshold: extreme,
            midpointShiftFactor: max(0.2, min(CGFloat(motionMidpointShiftFactor), 0.75)),
            maxMidpointShiftPixels: max(8.0, min(CGFloat(motionMaxShiftPixels), 36.0)),
            maxInterpolationBudgetMs: max(4.0, min(motionMaxInterpolationBudgetMs, 14.0)),
            consecutiveSlowFramesForGuardrail: max(1, min(motionSlowFramesForGuardrail, 8)),
            overloadGuardrailDurationSeconds: max(2.0, min(motionOverloadDurationSeconds, 20.0)),
            cpuPressurePercent: max(45.0, min(motionCpuPressurePercent, 95.0)),
            guardrailsEnabled: !motionForceFrameGenDebug
        )
    }

    private var videoAspectMode: VideoAspectCropMode {
        VideoAspectCropMode(rawValue: videoAspectModeRaw) ?? .source
    }

    private var recommendedMotionPreset: MotionInterpolationPreset {
        recommendedMotionPreset(screen: NSScreen.main, capability: motionCapability)
    }

    private var isMotionSmootheningActive: Bool {
        motionSmoothening120Enabled
    }

    private var isUpscaler4KActive: Bool {
        videoUpscaler4KEnabled
    }

    private var isImageOptimizeActive: Bool {
        videoImageOptimizeEnabled
    }

    private var effectiveVideoAspectMode: VideoAspectCropMode {
        videoAspectMode
    }

    private var imageOptimizationConfiguration: ImageOptimizationConfiguration {
        ImageOptimizationConfiguration(
            contrast: imageOptimizeContrast,
            lighting: imageOptimizeLighting,
            denoiser: imageOptimizeDenoiser,
            neuralClarity: imageOptimizeNeuralClarity
        ).clamped
    }

    private var motionDeviceSummary: String {
        let refresh = motionCapability.maxRefreshRate
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let silicon = isAppleSiliconRuntime() ? "Apple Silicon" : "Intel"
        return "\(silicon) • \(cores)c • \(Int(memoryGB.rounded()))GB • \(refresh)Hz"
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Colonne principale : Player + Infos
            GeometryReader { geo in
                let minPlayerHeight: CGFloat = 280
                let minAboutHeight: CGFloat = isDetailsSectionCollapsed ? 0 : 160
                let maxPlayerHeight = max(geo.size.height - minAboutHeight, minPlayerHeight)
                let desiredPlayerHeight = CGFloat(playerHeightRatio) * geo.size.height
                let playerHeight = isDetailsSectionCollapsed
                    ? maxPlayerHeight
                    : min(max(desiredPlayerHeight, minPlayerHeight), maxPlayerHeight)
                VStack(spacing: 0) {
                    // Player vidéo natif (≥ 80% de la hauteur)
                    VStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            Group {
                                if let url = streamURL {
                                    NativeVideoPlayer(
                                        url: url,
                                        isPlaying: $isPlaying,
                                        volume: $playerVolume,
                                        muted: $playerMuted,
                                        fullscreenRequestToken: $playerFullscreenRequestToken,
                                        pipController: pipController,
                                        zoom: $videoZoom,
                                        pan: $videoPan,
                                        motionSmootheningEnabled: isMotionSmootheningActive && motionCapability.supported,
                                        motionCapability: motionCapability,
                                        motionConfiguration: motionConfiguration,
                                        videoAspectMode: effectiveVideoAspectMode,
                                        upscaler4KEnabled: isUpscaler4KActive,
                                        imageOptimizeEnabled: isImageOptimizeActive,
                                        imageOptimizationConfiguration: imageOptimizationConfiguration
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

                                        if isStreamOffline {
                                            Text("Stream is offline")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.5))
                                        } else if let inline = playbackInlineError, !inline.isEmpty {
                                            Text(inline)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.55))
                                                .multilineTextAlignment(.center)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .padding(.horizontal, 18)
                                        }

                                        Button(action: { Task { await loadStream() } }) {
                                            let base = (playback.kind == .liveChannel) ? "Stream" : "Video"
                                            Text((isStreamOffline || playbackInlineError != nil) ? "Retry" : "Load \(base)")
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

                            if isMotionSmootheningActive || isUpscaler4KActive {
                                VStack {
                                    HStack(spacing: 8) {
                                        if isMotionSmootheningActive, let status = motionRuntimeStatus {
                                            motionFPSBadge(status)
                                        }
                                        if isUpscaler4KActive {
                                            upscaler4KBadge
                                        }
                                        Spacer()
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .allowsHitTesting(false)
                            }

                            if let channel = playback.channelName {
                                playerControlsToolbar(channel: channel)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                    .padding(.trailing, 12)
                                    .padding(.top, 10)
                                    .opacity(isHoveringVideoSurface ? 1 : 0)
                                    .allowsHitTesting(isHoveringVideoSurface)
                                    .animation(.easeOut(duration: 0.18), value: isHoveringVideoSurface)
                            }

                        }
                        .frame(height: playerHeight)
                        .layoutPriority(2)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            isHoveringVideoSurface = hovering
                        }
                    }

                    if !isDetailsSectionCollapsed {
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
                    }

                    if let channel = playback.channelName {
                        if !isDetailsSectionCollapsed {
                            VStack(spacing: 0) {
                                HStack(spacing: 12) {
                                    TwitchUnderlineTabs(tabs: ChannelDetailsTab.allCases, selection: $detailsTab) { $0.rawValue }
                                        .frame(width: 220, alignment: .leading)

                                    Spacer()

                                    Button(action: { setDetailsSectionCollapsed(true) }) {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help("Collapse details panel")

                                    if detailsTab == .videos {
                                        Button(action: { videosStore.reload() }) {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .help("Reload videos")
                                    } else if detailsTab == .schedule {
                                        Button(action: { scheduleStore.reload() }) {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .help("Reload schedule")
                                    }
                                    if let onFollowChannel {
                                        let isFollowing = followedChannels.contains { $0.login.lowercased() == channel.lowercased() }
                                        Button(isFollowing ? "Following" : "Follow") { onFollowChannel(channel) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .tint(isFollowing ? .purple : nil)
                                    }

                                    if let onOpenSubscription {
                                        Button("Subscribe") { onOpenSubscription(channel) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }

                                    if let onOpenGiftSub {
                                        Button("Gift Sub") { onOpenGiftSub(channel) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 10)

                                Rectangle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 1)

                                Group {
                                    switch detailsTab {
                                    case .about:
                                        AboutTabView(
                                            channelName: channel,
                                            store: aboutStore
                                        )
                                    case .videos:
                                        ChannelVideosPanelView(
                                            channelName: channel,
                                            store: videosStore,
                                            isChannelOffline: isStreamOffline,
                                            onSelectPlayback: { request in
                                                playback = request
                                            }
                                        )
                                    case .schedule:
                                        ChannelSchedulePanelView(
                                            channelName: channel,
                                            store: scheduleStore
                                        )
                                    }
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .layoutPriority(0)
                        }
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
            if MotionInterpolationPreset(rawValue: motionPresetRaw) == nil {
                applyMotionPreset(.balanced)
                motionPresetRaw = MotionInterpolationPreset.balanced.rawValue
            }
            refreshMotionCapability()
            if motionAutoPresetEnabled {
                applyAutoMotionPresetIfNeeded(reason: "startup")
            } else if motionPreset != .custom {
                applyMotionPreset(motionPreset)
            }
            sanitizeMotionConfigurationValues()
            if playback.kind == .liveChannel, let channel = playback.channelName {
                applyChatPreference(for: channel)
                aboutStore.load(channelName: channel)
                scheduleStore.load(channelName: channel)
            } else {
                showChat = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshMotionCapability()
            applyAutoMotionPresetIfNeeded(reason: "screen_change")
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            refreshMotionCapability()
            applyAutoMotionPresetIfNeeded(reason: "thermal_change")
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            refreshMotionCapability()
            applyAutoMotionPresetIfNeeded(reason: "power_change")
        }
        .onReceive(NotificationCenter.default.publisher(for: .motionInterpolationRuntimeUpdated)) { notification in
            guard let status = notification.object as? MotionInterpolationRuntimeStatus else { return }
            motionRuntimeStatus = status
            appendMotionRuntimeStatus(status)
        }
        .onChange(of: playback) { newValue in
            // Mettre à jour le player sans "ouvrir Twitch" en bas:
            // on remplace uniquement la source streamlinkTarget.
            Task { await loadStream() }

            // Si on change de chaîne, reset les onglets du bas.
            if newValue.channelName != lastChannelName {
                lastChannelName = newValue.channelName
                detailsTab = .about
                if newValue.kind == .liveChannel, let channel = newValue.channelName {
                    applyChatPreference(for: channel)
                    aboutStore.load(channelName: channel)
                    scheduleStore.load(channelName: channel)
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
        .onChange(of: detailsTab) { tab in
            guard tab == .videos else { return }
            guard playback.kind == .liveChannel, let channel = playback.channelName else { return }
            videosStore.load(channelName: channel, section: videosStore.section, isChannelOffline: isStreamOffline)
        }
        .onChange(of: isStreamOffline) { offline in
            guard detailsTab == .videos else { return }
            guard playback.kind == .liveChannel, let channel = playback.channelName else { return }
            videosStore.load(channelName: channel, section: videosStore.section, isChannelOffline: offline)
        }
        .onChange(of: motionSmoothening120Enabled) { enabled in
            if !enabled && !videoUpscaler4KEnabled && !videoImageOptimizeEnabled {
                motionRuntimeStatus = nil
                motionRuntimeSamples.removeAll()
            }
            GlitchoTelemetry.track(
                "motion_smoothening_toggle",
                metadata: [
                    "enabled": enabled ? "true" : "false",
                    "supported": motionCapability.supported ? "true" : "false",
                    "ai_supported": motionCapability.aiInterpolationSupported ? "true" : "false"
                ]
            )
        }
        .onChange(of: videoAspectModeRaw) { raw in
            if VideoAspectCropMode(rawValue: raw) == nil {
                videoAspectModeRaw = VideoAspectCropMode.source.rawValue
                return
            }
            videoPan = .zero
            GlitchoTelemetry.track(
                "video_crop_mode_changed",
                metadata: ["mode": videoAspectMode.rawValue]
            )
        }
        .onChange(of: videoUpscaler4KEnabled) { enabled in
            if !enabled && !motionSmoothening120Enabled && !videoImageOptimizeEnabled {
                motionRuntimeStatus = nil
                motionRuntimeSamples.removeAll()
            }
            GlitchoTelemetry.track(
                "video_upscaler_4k_toggle",
                metadata: [
                    "enabled": enabled ? "true" : "false"
                ]
            )
        }
        .onChange(of: videoImageOptimizeEnabled) { enabled in
            if !enabled && !motionSmoothening120Enabled && !videoUpscaler4KEnabled {
                motionRuntimeStatus = nil
                motionRuntimeSamples.removeAll()
            }
            GlitchoTelemetry.track(
                "video_image_optimize_toggle",
                metadata: [
                    "enabled": enabled ? "true" : "false"
                ]
            )
        }
        .onChange(of: motionAutoPresetEnabled) { enabled in
            if enabled {
                applyAutoMotionPresetIfNeeded(reason: "auto_toggle")
            }
            GlitchoTelemetry.track(
                "motion_smoothening_auto_preset_toggle",
                metadata: ["enabled": enabled ? "true" : "false"]
            )
        }
        .onChange(of: motionForceFrameGenDebug) { enabled in
            trackMotionConfigurationChange(trigger: enabled ? "debug_force_on" : "debug_force_off")
            GlitchoTelemetry.track(
                "motion_smoothening_force_framegen_toggle",
                metadata: ["enabled": enabled ? "true" : "false"]
            )
        }
        .onChange(of: motionLowMotionThreshold) { _ in markMotionPresetCustomAndTrack() }
        .onChange(of: motionHighMotionThreshold) { _ in markMotionPresetCustomAndTrack() }
        .onChange(of: motionExtremeMotionThreshold) { _ in markMotionPresetCustomAndTrack() }
        .onChange(of: motionMidpointShiftFactor) { _ in markMotionPresetCustomAndTrack() }
        .onChange(of: motionMaxShiftPixels) { _ in markMotionPresetCustomAndTrack() }
        .onChange(of: motionMaxInterpolationBudgetMs) { _ in markMotionPresetCustomAndTrack() }
        .onChange(of: motionSlowFramesForGuardrail) { _ in markMotionPresetCustomAndTrack() }
        .onChange(of: motionOverloadDurationSeconds) { _ in markMotionPresetCustomAndTrack() }
        .onChange(of: motionCpuPressurePercent) { _ in markMotionPresetCustomAndTrack() }
        .task {
            await loadStream()
        }
        .onDisappear {
            // Important: stopper le player natif quand on quitte la vue (navigation ailleurs)
            isPlaying = false
            streamURL = nil
            motionRuntimeStatus = nil
            motionRuntimeSamples.removeAll()
            closeDetachedChat()
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
        await MainActor.run {
            showError = false
            isStreamOffline = false
            playbackInlineError = nil
            streamlink.error = nil
            streamlink.isLoading = true
        }

        do {
            let url = try await streamlink.getStreamURL(target: playback.streamlinkTarget)
            await MainActor.run {
                self.streamURL = url
                streamlink.isLoading = false
                isStreamOffline = false
                playbackInlineError = nil
            }
        } catch {
            let message = error.localizedDescription
            let noPlayable = isStreamOfflineErrorMessage(message)
            let offline = (playback.kind == .liveChannel) && noPlayable

            await MainActor.run {
                streamlink.error = message
                streamlink.isLoading = false

                if offline {
                    isStreamOffline = true
                    playbackInlineError = nil
                    showError = false
                    return
                }

                // For VODs/clips, Streamlink often reports "No playable streams" when the manifest is restricted.
                if noPlayable {
                    isStreamOffline = false
                    switch playback.kind {
                    case .vod:
                        playbackInlineError = "This video is restricted (sub-only / login required) or unavailable."
                    case .clip:
                        playbackInlineError = "This clip is restricted (login required) or unavailable."
                    case .liveChannel:
                        playbackInlineError = message
                    }
                    showError = false
                    return
                }

                // Unexpected error: show modal.
                playbackInlineError = message
                showError = true
            }
        }
    }

    private func resetVideoZoom() {
        videoZoom = 1.0
        videoPan = .zero
    }

    @ViewBuilder
    private func playerControlsToolbar(channel: String) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                    if playback.kind == .liveChannel {
                    Button(action: { toggleDetailsSectionCollapsed() }) {
                        Image(systemName: isDetailsSectionCollapsed ? "chevron.up.square" : "chevron.down.square")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.84))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(isDetailsSectionCollapsed ? "Show details panel" : "Collapse details panel")

                    if !isChatDetached {
                        Button(action: { toggleChatVisibility(channel: channel) }) {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(showChat ? 0.84 : 0.45))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(showChat ? "Collapse chat" : "Show chat")
                    }

                    Button(action: { isChatDetached ? attachChat() : detachChat(channel) }) {
                        Image(systemName: isChatDetached ? "rectangle.on.rectangle" : "arrow.up.right.square")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(isChatDetached ? "Attach chat" : "Chat popup")

                    if showRecordingControl {
                        let channelLogin = channel.lowercased()
                        let isLocalRecording = recordingManager.isRecording(channelLogin: channelLogin)
                        let isBackgroundRecording = recordingManager.isRecordingInBackgroundAgent(channelLogin: channelLogin)
                        let isChannelRecording = isLocalRecording || isBackgroundRecording
                        let badgeLabel = isChannelRecording ? "Stop" : "Record"
                        let manualAction: ManualRecordingControlAction = isChannelRecording ? .stop : .start
                        Button(action: { onRecordRequest?(manualAction) }) {
                            RecordingControlBadge(
                                isRecording: isChannelRecording,
                                label: badgeLabel
                            )
                        }
                        .buttonStyle(.plain)
                        .help(isChannelRecording ? "Stop recording this channel" : "Start recording this channel")
                    }
                }

                if pipController.isAvailable {
                    Button(action: { pipController.toggle() }) {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.84))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Picture in Picture")
                }

                Button(action: requestPlayerFullscreenToggle) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Player fullscreen")

                Button(action: { showOverlayMorePopover.toggle() }) {
                    Label("More", systemImage: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .help("More controls")
                .popover(isPresented: $showOverlayMorePopover, arrowEdge: .bottom) {
                    overlayMorePopover(channel: channel)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
        }
    }

    @ViewBuilder
    private func overlayMorePopover(channel: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More Controls")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Zoom")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    OverlayValueSlider(
                        value: Binding(
                            get: { Double(videoZoom) },
                            set: { newValue in
                                let stepped = (newValue * 20).rounded() / 20
                                videoZoom = CGFloat(min(max(1.0, stepped), 4.0))
                                if videoZoom <= 1.001 {
                                    videoPan = .zero
                                }
                            }
                        ),
                        range: 1.0...4.0
                    )
                    .frame(width: 180, height: 16)
                    Text(String(format: "%.2f×", Double(videoZoom)))
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 52, alignment: .trailing)
                    Button("Reset") { resetVideoZoom() }
                        .buttonStyle(.borderless)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text("AirPlay")
                    .font(.system(size: 11, weight: .medium))
                AirPlayRoutePicker()
                    .frame(width: 24, height: 24)
            }

            HStack(spacing: 10) {
                Button("Reload Stream") { Task { await loadStream() } }
            }
            .buttonStyle(.borderless)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Pro Video")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                    Picker("Crop mode", selection: $videoAspectModeRaw) {
                        ForEach(VideoAspectCropMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Motion smoothening", isOn: $motionSmoothening120Enabled)
                        .disabled(!motionCapability.supported)
                    Toggle("4K upscaler", isOn: $videoUpscaler4KEnabled)
                    Toggle("Image optimize", isOn: $videoImageOptimizeEnabled)

                    Picker("Preset", selection: motionPresetBinding) {
                        ForEach(MotionInterpolationPreset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func requestPlayerFullscreenToggle() {
        playerFullscreenRequestToken &+= 1
    }

    private func toggleDetailsSectionCollapsed() {
        setDetailsSectionCollapsed(!isDetailsSectionCollapsed)
    }

    private func setDetailsSectionCollapsed(_ collapsed: Bool) {
        guard collapsed != isDetailsSectionCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isDetailsSectionCollapsed = collapsed
        }
        GlitchoTelemetry.track(
            "player_details_panel_toggled",
            metadata: [
                "collapsed": collapsed ? "true" : "false",
                "tab": detailsTab.rawValue.lowercased()
            ]
        )
    }

    private func refreshMotionCapability() {
        let next = MotionSmootheningCapability.evaluate(screen: NSScreen.main)
        if motionCapability != next {
            motionCapability = next
            GlitchoTelemetry.track(
                "motion_smoothening_capability",
                metadata: [
                    "supported": next.supported ? "true" : "false",
                    "ai_supported": next.aiInterpolationSupported ? "true" : "false",
                    "refresh_hz": "\(next.maxRefreshRate)",
                    "reason": next.reason,
                    "thermal": ProcessInfo.processInfo.thermalState.description
                ]
            )
        }
        if !next.supported {
            motionSmoothening120Enabled = false
        }
    }

    @ViewBuilder
    private func motionFPSBadge(_ status: MotionInterpolationRuntimeStatus) -> some View {
        HStack(spacing: 8) {
            Text("FPS \(String(format: "%.1f", status.effectiveFPS))")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private var upscaler4KBadge: some View {
        HStack(spacing: 6) {
            Text("4K")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
            Text("Upscale")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.cyan.opacity(0.5), lineWidth: 1)
                )
        )
    }


    private func applyMotionPreset(_ preset: MotionInterpolationPreset) {
        let config: MotionInterpolationConfiguration
        switch preset {
        case .quality:
            config = .quality
        case .balanced:
            config = .balanced
        case .performance:
            config = .performance
        case .custom:
            return
        }
        suppressMotionPresetAutoCustom = true
        motionLowMotionThreshold = Double(config.lowMotionThreshold)
        motionHighMotionThreshold = Double(config.highMotionThreshold)
        motionExtremeMotionThreshold = Double(config.extremeMotionThreshold)
        motionMidpointShiftFactor = Double(config.midpointShiftFactor)
        motionMaxShiftPixels = Double(config.maxMidpointShiftPixels)
        motionMaxInterpolationBudgetMs = config.maxInterpolationBudgetMs
        motionSlowFramesForGuardrail = config.consecutiveSlowFramesForGuardrail
        motionOverloadDurationSeconds = config.overloadGuardrailDurationSeconds
        motionCpuPressurePercent = config.cpuPressurePercent
        DispatchQueue.main.async {
            suppressMotionPresetAutoCustom = false
        }
    }

    private func appendMotionRuntimeStatus(_ status: MotionInterpolationRuntimeStatus) {
        let now = Date()
        motionRuntimeSamples.append(MotionRuntimeSample(timestamp: now, status: status))
        let cutoff = now.addingTimeInterval(-60)
        motionRuntimeSamples.removeAll { $0.timestamp < cutoff }
        if motionRuntimeSamples.count > 360 {
            motionRuntimeSamples.removeFirst(motionRuntimeSamples.count - 360)
        }
    }

    private func sanitizeMotionConfigurationValues() {
        let sanitizedLow = max(0.01, min(motionLowMotionThreshold, 0.6))
        let sanitizedHigh = max(sanitizedLow + 0.05, min(motionHighMotionThreshold, 6.0))
        let sanitizedExtreme = max(sanitizedHigh + 0.1, min(motionExtremeMotionThreshold, 12.0))
        motionLowMotionThreshold = sanitizedLow
        motionHighMotionThreshold = sanitizedHigh
        motionExtremeMotionThreshold = sanitizedExtreme
        motionMidpointShiftFactor = max(0.2, min(motionMidpointShiftFactor, 0.75))
        motionMaxShiftPixels = max(8.0, min(motionMaxShiftPixels, 36.0))
        motionMaxInterpolationBudgetMs = max(4.0, min(motionMaxInterpolationBudgetMs, 14.0))
        motionSlowFramesForGuardrail = max(1, min(motionSlowFramesForGuardrail, 8))
        motionOverloadDurationSeconds = max(2.0, min(motionOverloadDurationSeconds, 20.0))
        motionCpuPressurePercent = max(45.0, min(motionCpuPressurePercent, 95.0))
    }

    private func markMotionPresetCustomAndTrack() {
        if suppressMotionPresetAutoCustom {
            return
        }
        sanitizeMotionConfigurationValues()
        motionAutoPresetEnabled = false
        if motionPreset != .custom {
            motionPresetRaw = MotionInterpolationPreset.custom.rawValue
        }
        trackMotionConfigurationChange(trigger: "adjust")
    }

    private func trackMotionConfigurationChange(trigger: String) {
        GlitchoTelemetry.track(
            "motion_smoothening_config_changed",
            metadata: [
                "trigger": trigger,
                "preset": motionPreset.rawValue,
                "target_hz": "\(motionCapability.targetRefreshRate)",
                "low": String(format: "%.2f", motionConfiguration.lowMotionThreshold),
                "high": String(format: "%.2f", motionConfiguration.highMotionThreshold),
                "extreme": String(format: "%.2f", motionConfiguration.extremeMotionThreshold),
                "shift": String(format: "%.2f", motionConfiguration.midpointShiftFactor),
                "max_shift": String(format: "%.1f", motionConfiguration.maxMidpointShiftPixels),
                "budget_ms": String(format: "%.2f", motionConfiguration.maxInterpolationBudgetMs),
                "cpu_guardrail": String(format: "%.1f", motionConfiguration.cpuPressurePercent),
                "guardrails_enabled": motionConfiguration.guardrailsEnabled ? "true" : "false",
                "crop_mode": videoAspectMode.rawValue,
                "upscaler_4k": videoUpscaler4KEnabled ? "true" : "false",
                "image_optimize": videoImageOptimizeEnabled ? "true" : "false"
            ]
        )
    }

    private func applyAutoMotionPresetIfNeeded(reason: String) {
        guard motionAutoPresetEnabled else { return }

        let recommended = recommendedMotionPreset
        let presetChanged = motionPreset != recommended

        if presetChanged {
            motionPresetRaw = recommended.rawValue
        }
        applyMotionPreset(recommended)

        GlitchoTelemetry.track(
            "motion_smoothening_auto_preset",
            metadata: [
                "reason": reason,
                "preset": recommended.rawValue,
                "device": motionDeviceSummary,
                "supported": motionCapability.supported ? "true" : "false"
            ]
        )
        if presetChanged {
            trackMotionConfigurationChange(trigger: "auto_\(reason)")
        }
    }

    private func recommendedMotionPreset(
        screen: NSScreen?,
        capability: MotionSmootheningCapability
    ) -> MotionInterpolationPreset {
        if !capability.supported {
            return .performance
        }

        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .performance
        }

        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let refresh = max(60, screen?.maximumFramesPerSecond ?? capability.maxRefreshRate)
        let appleSilicon = isAppleSiliconRuntime()

        if appleSilicon, memoryGB >= 16, cores >= 8, refresh >= 60 {
            return .quality
        }

        if (appleSilicon && memoryGB >= 10 && cores >= 8) || (memoryGB >= 12 && cores >= 8) {
            return .balanced
        }

        if memoryGB >= 8, cores >= 6, refresh >= 60 {
            return .balanced
        }

        return .performance
    }

    private func isAppleSiliconRuntime() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
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

private struct OverlayValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var accent: Color = Color.white.opacity(0.92)
    var trackBackground: Color = Color.white.opacity(0.16)

    private var clampedValue: Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var normalized: Double {
        let span = range.upperBound - range.lowerBound
        guard span > .ulpOfOne else { return 0 }
        return (clampedValue - range.lowerBound) / span
    }

    var body: some View {
        GeometryReader { geo in
            let knobSize: CGFloat = 11
            let width = max(1, geo.size.width)
            let available = max(1, width - knobSize)
            let knobX = CGFloat(normalized) * available
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackBackground)
                    .frame(height: 4)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.62)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(5, CGFloat(normalized) * width), height: 4)
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.16), lineWidth: 0.6)
                    )
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: Color.black.opacity(0.28), radius: 2, x: 0, y: 1)
                    .offset(x: knobX, y: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let location = min(max(0, drag.location.x - knobSize / 2), available)
                        let fraction = location / available
                        value = range.lowerBound + (range.upperBound - range.lowerBound) * Double(fraction)
                    }
            )
        }
        .frame(height: 16)
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

private struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView(frame: .zero)
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
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

private struct MotionDiagnosticsPanel: View {
    let samples: [MotionRuntimeSample]
    let latest: MotionInterpolationRuntimeStatus?
    let interpolationBudgetMs: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diagnostics (60s)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let latest {
                    Text(latest.method.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            MotionDiagnosticsGraph(samples: samples, interpolationBudgetMs: interpolationBudgetMs)
                .frame(height: 92)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 12) {
                legendLabel(color: .green, text: "CPU")
                legendLabel(color: .blue, text: "GPU")
                legendLabel(color: .orange, text: "Interpolation")
                Spacer()
                if let latest {
                    Text(latest.fallbackReason == "none"
                        ? "No fallback"
                        : "Fallback: \(latest.fallbackReason.replacingOccurrences(of: "_", with: " "))")
                        .font(.system(size: 10))
                        .foregroundColor(latest.fallbackReason == "none" ? .secondary : .orange)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    @ViewBuilder
    private func legendLabel(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MotionDiagnosticsGraph: View {
    let samples: [MotionRuntimeSample]
    let interpolationBudgetMs: Double

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let now = samples.last?.timestamp ?? Date()
                let start = now.addingTimeInterval(-60)
                let visible = samples.filter { $0.timestamp >= start }
                guard !visible.isEmpty else { return }

                let cpuPoints = visible.map { sample -> CGPoint in
                    let x = xPosition(sample.timestamp, start: start, width: size.width)
                    let normalized = CGFloat((sample.status.cpuLoadPercent ?? 0) / 100.0)
                    return CGPoint(x: x, y: size.height * (1 - normalized))
                }

                let gpuPoints = visible.map { sample -> CGPoint in
                    let x = xPosition(sample.timestamp, start: start, width: size.width)
                    let normalized = CGFloat(min(1.0, (sample.status.gpuRenderMs ?? 0) / max(1, interpolationBudgetMs * 2)))
                    return CGPoint(x: x, y: size.height * (1 - normalized))
                }

                let interpolationPoints = visible.map { sample -> CGPoint in
                    let x = xPosition(sample.timestamp, start: start, width: size.width)
                    let normalized = CGFloat(min(1.0, sample.status.interpolationMs / max(1, interpolationBudgetMs * 2)))
                    return CGPoint(x: x, y: size.height * (1 - normalized))
                }

                drawLine(points: cpuPoints, color: .green, context: &context)
                drawLine(points: gpuPoints, color: .blue, context: &context)
                drawLine(points: interpolationPoints, color: .orange, context: &context)
            }
        }
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func xPosition(_ timestamp: Date, start: Date, width: CGFloat) -> CGFloat {
        let delta = timestamp.timeIntervalSince(start)
        let clamped = max(0, min(60, delta))
        return width * CGFloat(clamped / 60.0)
    }

    private func drawLine(points: [CGPoint], color: Color, context: inout GraphicsContext) {
        guard points.count >= 2 else { return }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(color), lineWidth: 1.3)
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
    let id: String
    let title: String
    let body: String
    let imageURL: URL?
    let links: [ChannelAboutLink]

    init(title: String, body: String, imageURL: URL?, links: [ChannelAboutLink]) {
        self.title = title
        self.body = body
        self.imageURL = imageURL
        self.links = links
        self.id = ChannelAboutPanel.makeStableID(title: title, body: body, imageURL: imageURL, links: links)
    }

    private static func makeStableID(title: String, body: String, imageURL: URL?, links: [ChannelAboutLink]) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = imageURL?.absoluteString ?? ""
        let bodyHash = String(normalizedBody.hashValue)
        let linkIDs = links.map { $0.id }.joined(separator: ",")
        return [normalizedTitle, image, bodyHash, linkIDs].joined(separator: "|")
    }
}

struct ChannelAboutLink: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
    let imageURL: URL?
    let isImageLink: Bool

    init(
        id: String? = nil,
        title: String,
        url: URL,
        imageURL: URL?,
        isImageLink: Bool,
        occurrence: Int = 0
    ) {
        self.title = title
        self.url = url
        self.imageURL = imageURL
        self.isImageLink = isImageLink
        self.id = id ?? ChannelAboutLink.makeStableID(
            url: url,
            title: title,
            imageURL: imageURL,
            isImageLink: isImageLink,
            occurrence: occurrence
        )
    }

    private static func makeStableID(
        url: URL,
        title: String,
        imageURL: URL?,
        isImageLink: Bool,
        occurrence: Int
    ) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let imageKey = imageURL?.absoluteString ?? ""
        let kind = isImageLink ? "image" : "text"
        return [url.absoluteString, normalizedTitle, imageKey, kind, String(occurrence)].joined(separator: "|")
    }

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class ChannelAboutStore: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var panels: [ChannelAboutPanel] = []
    @Published var isLoading = false
    @Published var lastError: String?

    private var webView: WKWebView?
    private var currentChannel: String?
    private var loadingDeadlineWorkItem: DispatchWorkItem?

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

        loadingDeadlineWorkItem?.cancel()
        isLoading = true
        lastError = nil
        panels = []

        scheduleLoadingDeadline(for: normalized)

        let url = URL(string: "https://www.twitch.tv/\(normalized)/about")!
        webView?.load(URLRequest(url: url))
    }

    private func scheduleLoadingDeadline(for channel: String) {
        loadingDeadlineWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentChannel == channel else { return }
            if self.isLoading && self.panels.isEmpty {
                self.isLoading = false
            }
        }

        loadingDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
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
        source: #"""
        (function() {
          if (window.__glitcho_about_scrape) { return; }
          window.__glitcho_about_scrape = true;

          function trim(s) {
            return (s || '').replace(/\s+/g, ' ').trim();
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
                const textValue = trim(link.textContent || '');
                const imageValue = linkImage ? (linkImage.getAttribute('src') || '') : '';
                const isImageLink = !!imageValue;
                return {
                  title: isImageLink ? textValue : trim(link.textContent || link.getAttribute('href') || ''),
                  url: link.getAttribute('href') || '',
                  imageURL: imageValue,
                  isImageLink: isImageLink
                };
              }).filter(item => item.url);

              panels.push({ title: title, body: body, imageURL: imageURL, links: links });
            }

            return panels;
          }

          let lastSent = null;
          let pending = false;

          function postPanelsIfChanged() {
            const panels = extractPanels();
            let serialized = null;
            try { serialized = JSON.stringify(panels); } catch (_) { serialized = null; }
            if (serialized === lastSent) { return; }
            lastSent = serialized;
            try {
              window.webkit.messageHandlers.aboutPanels.postMessage({ panels: panels });
            } catch (_) {}
          }

          function schedulePost() {
            if (pending) { return; }
            pending = true;
            setTimeout(function() {
              pending = false;
              postPanelsIfChanged();
            }, 350);
          }

          postPanelsIfChanged();
          const observer = new MutationObserver(schedulePost);
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setTimeout(postPanelsIfChanged, 1000);
          setTimeout(postPanelsIfChanged, 2000);
          setTimeout(postPanelsIfChanged, 4000);
        })();
        """#,
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
            let linkItems = item["links"] as? [[String: Any]] ?? []
            let links = linkItems.enumerated().compactMap { index, link -> ChannelAboutLink? in
                guard let urlString = link["url"] as? String, let url = URL(string: urlString) else { return nil }
                let isImageLink = (link["isImageLink"] as? Bool) ?? false
                let rawTitle = (link["title"] as? String) ?? (isImageLink ? "" : urlString)
                let label = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let linkImageString = ((link["imageURL"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let linkImageURL = linkImageString.isEmpty ? nil : URL(string: linkImageString)
                let linkID = [url.absoluteString, label.lowercased(), linkImageString, isImageLink ? "image" : "text", String(index)]
                    .joined(separator: "|")
                return ChannelAboutLink(
                    id: linkID,
                    title: label.isEmpty ? (isImageLink ? "" : urlString) : label,
                    url: url,
                    imageURL: linkImageURL,
                    isImageLink: isImageLink,
                    occurrence: index
                )
            }
            guard !title.isEmpty || !body.isEmpty || !links.isEmpty else { return nil }
            return ChannelAboutPanel(title: title, body: body, imageURL: imageURL, links: links)
        }

        DispatchQueue.main.async {
            // Avoid flicker: Twitch mutates the DOM frequently and we can temporarily scrape 0 panels.
            if panels.isEmpty {
                if !self.panels.isEmpty {
                    return
                }
                // Keep the loading state until the timeout fires.
                return
            }

            self.loadingDeadlineWorkItem?.cancel()
            self.loadingDeadlineWorkItem = nil

            if self.panels != panels {
                self.panels = panels
            }
            self.isLoading = false
        }
    }
}

struct ChannelAboutScraperView: NSViewRepresentable {
    @ObservedObject var store: ChannelAboutStore

    func makeNSView(context: Context) -> WKWebView {
        let view = store.attachWebView()
        view.isHidden = false
        // Keep a tiny non-zero alpha so WebKit doesn’t treat it as fully invisible/offscreen.
        view.alphaValue = 0.01
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.isHidden = false
        nsView.alphaValue = 0.01
    }
}

struct ChannelAboutPanelView: View {
    let channelName: String
    @ObservedObject var store: ChannelAboutStore

    private let gridColumns = [
        GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .frame(maxHeight: 180)
                                            .clipped()
                                    } placeholder: {
                                        Color.white.opacity(0.08)
                                            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 160)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                            if link.isImageLink, let imageURL = link.imageURL {
                                                Link(destination: link.url) {
                                                    VStack(alignment: .leading, spacing: 6) {
                                                        AsyncImage(url: imageURL) { image in
                                                            image
                                                                .resizable()
                                                                .scaledToFill()
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                                                .clipped()
                                                        } placeholder: {
                                                            Color.white.opacity(0.08)
                                                                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 180)
                                                        }
                                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                                        let caption = displayLinkTitle(link)
                                                        if !caption.isEmpty {
                                                            Text(caption)
                                                                .font(.system(size: 11, weight: .medium))
                                                                .foregroundStyle(.white.opacity(0.72))
                                                                .lineLimit(2)
                                                        }
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                            } else {
                                                Link(displayLinkTitle(link), destination: link.url)
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
                            .clipped()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(
            ChannelAboutScraperView(store: store)
                .frame(width: 800, height: 600)
                .allowsHitTesting(false)
                .opacity(0.001)
        )
        .onAppear {
            store.load(channelName: channelName)
        }
        .onChange(of: channelName) { newValue in
            store.load(channelName: newValue)
        }
    }

    private func displayLinkTitle(_ link: ChannelAboutLink) -> String {
        let title = link.normalizedTitle
        if title.isEmpty {
            return link.url.host ?? link.url.absoluteString
        }
        if isRawURLText(title) {
            return link.url.host ?? title
        }
        return title
    }

    private func isRawURLText(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.contains("://")
    }
}

struct ChannelVideoItem: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
    let thumbnailURL: URL?
    let subtitle: String?
    let duration: String?
    let kind: NativePlaybackRequest.Kind
}

final class ChannelVideosStore: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    enum Section: String, CaseIterable {
        case videos = "Videos"
        case clips = "Clips"
    }
    private struct GQLConfig {
        static let endpoint = URL(string: "https://gql.twitch.tv/gql")!
        static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    }

    @Published var isLoading = false
    @Published var lastError: String?
    @Published var vods: [ChannelVideoItem] = []
    @Published var clips: [ChannelVideoItem] = []
    @Published var section: Section = .videos

    private var webView: WKWebView?
    private var currentChannel: String?
    private var currentOfflineState = false
    private var loadingDeadlineWorkItem: DispatchWorkItem?
    private var gqlFallbackAttempts: Set<String> = []
    private var routeFallbackAttempts: Set<String> = []

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

    func load(channelName: String, section: Section, isChannelOffline: Bool = false) {
        let normalized = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let didChangeChannel = (normalized != currentChannel)
        let didChangeOffline = (isChannelOffline != currentOfflineState)
        let didChangeSection = (section != self.section)
        currentChannel = normalized
        currentOfflineState = isChannelOffline
        self.section = section

        lastError = nil
        loadingDeadlineWorkItem?.cancel()
        isLoading = true

        if didChangeChannel || didChangeOffline || didChangeSection {
            vods = []
            clips = []
            gqlFallbackAttempts.removeAll()
            routeFallbackAttempts.removeAll()
        }

        scheduleLoadingDeadline(for: normalized, section: section, offline: isChannelOffline)
        scheduleGQLFallback(for: normalized, section: section, offline: isChannelOffline)

        let url = preferredRouteURL(channel: normalized, section: section, offline: isChannelOffline)

        if let currentURL = webView?.url {
            let sameChannel = currentURL.absoluteString.contains("/\(normalized)/")
            let samePath = currentURL.path.lowercased() == url.path.lowercased()
            let currentQuery = currentURL.query ?? ""
            let targetQuery = url.query ?? ""
            if sameChannel && samePath && currentQuery == targetQuery {
                webView?.evaluateJavaScript("window.__glitcho_scrapeChannelVideos && window.__glitcho_scrapeChannelVideos();", completionHandler: nil)
            } else {
                webView?.load(URLRequest(url: url))
            }
        } else {
            webView?.load(URLRequest(url: url))
        }
    }

    private func scheduleLoadingDeadline(for channel: String, section: Section, offline: Bool) {
        loadingDeadlineWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentChannel == channel else { return }
            guard self.section == section else { return }
            guard self.currentOfflineState == offline else { return }
            if self.isLoading {
                let items: [ChannelVideoItem]
                switch section {
                case .videos: items = self.vods
                case .clips: items = self.clips
                }
                if (items.isEmpty || self.isLowConfidenceVideosPayload(items, section: section)),
                   let fallbackURL = self.fallbackRouteURL(channel: channel, section: section, offline: offline) {
                    let fallbackKey = self.routeAttemptKey(channel: channel, section: section, offline: offline, fallback: true)
                    if !self.routeFallbackAttempts.contains(fallbackKey) {
                        self.routeFallbackAttempts.insert(fallbackKey)
                        self.webView?.load(URLRequest(url: fallbackURL))
                        self.scheduleLoadingDeadline(for: channel, section: section, offline: offline)
                        return
                    }
                }
                self.isLoading = false
            }
        }

        loadingDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    private func scheduleGQLFallback(for channel: String, section: Section, offline: Bool) {
        let key = "\(channel.lowercased())|\(section.rawValue)|offline=\(offline ? "1" : "0")"
        guard !gqlFallbackAttempts.contains(key) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self else { return }
            guard self.currentChannel == channel else { return }
            guard self.section == section else { return }
            guard self.currentOfflineState == offline else { return }

            let itemsEmpty: Bool
            switch section {
            case .videos: itemsEmpty = self.vods.isEmpty
            case .clips: itemsEmpty = self.clips.isEmpty
            }
            if itemsEmpty {
                self.gqlFallbackAttempts.insert(key)
                Task { await self.fetchGQLFallback(channel: channel, section: section) }
            }
        }
    }

    private func fetchGQLFallback(channel: String, section: Section) async {
        let token = await twitchAuthToken()
        do {
            let items: [ChannelVideoItem]
            switch section {
            case .videos:
                items = try await fetchGQLVideos(channel: channel, token: token)
            case .clips:
                items = try await fetchGQLClips(channel: channel, token: token)
            }

            guard !items.isEmpty else { return }

            DispatchQueue.main.async {
                guard self.currentChannel == channel else { return }
                guard self.section == section else { return }
                switch section {
                case .videos:
                    if self.vods.isEmpty {
                        self.vods = items
                    }
                case .clips:
                    if self.clips.isEmpty {
                        self.clips = items
                    }
                }
                self.isLoading = false
            }
        } catch {
            DispatchQueue.main.async {
                if self.lastError == nil || self.lastError?.isEmpty == true {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func fetchGQLVideos(channel: String, token: String?) async throws -> [ChannelVideoItem] {
        let query = """
        query($login: String!, $first: Int!) {
          user(login: $login) {
            videos(first: $first) {
              edges {
                node {
                  id
                  title
                  lengthSeconds
                  previewThumbnailURL(width: 320, height: 180)
                  game { displayName name }
                }
              }
            }
          }
        }
        """

        let variables: [String: Any] = ["login": channel, "first": 40]
        let json = try await performGQLRequest(query: query, variables: variables, token: token)
        return parseGQLVideos(json: json)
    }

    private func fetchGQLClips(channel: String, token: String?) async throws -> [ChannelVideoItem] {
        let query = """
        query($login: String!, $first: Int!, $criteria: UserClipsInput) {
          user(login: $login) {
            clips(first: $first, criteria: $criteria) {
              edges {
                node {
                  id
                  slug
                  title
                  durationSeconds
                  thumbnailURL(width: 320, height: 180)
                  game { displayName name }
                }
              }
            }
          }
        }
        """

        let criteria: [String: Any] = [
            "period": "ALL_TIME",
            "sort": "VIEWS_DESC"
        ]
        let variables: [String: Any] = [
            "login": channel,
            "first": 40,
            "criteria": criteria
        ]
        let json = try await performGQLRequest(query: query, variables: variables, token: token)
        return parseGQLClips(json: json)
    }

    private func performGQLRequest(query: String, variables: [String: Any], token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: GQLConfig.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GQLConfig.clientID, forHTTPHeaderField: "Client-Id")
        if let token, !token.isEmpty {
            request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "query": query,
            "variables": variables
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, _) = try await URLSession.shared.data(for: request)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        return obj as? [String: Any] ?? [:]
    }

    private func parseGQLVideos(json: [String: Any]) -> [ChannelVideoItem] {
        guard let data = json["data"] as? [String: Any],
              let user = data["user"] as? [String: Any],
              let videos = user["videos"] as? [String: Any],
              let edges = videos["edges"] as? [[String: Any]] else {
            return []
        }

        return edges.compactMap { edge in
            guard let node = edge["node"] as? [String: Any] else { return nil }
            let id = String(describing: node["id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }

            let title = (node["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let length = node["lengthSeconds"] as? Int
            let thumb = node["previewThumbnailURL"] as? String

            var subtitle: String?
            if let game = node["game"] as? [String: Any] {
                subtitle = (game["displayName"] as? String) ?? (game["name"] as? String)
            }

            let url = URL(string: "https://www.twitch.tv/videos/\(id)")!
            return ChannelVideoItem(
                id: id,
                title: title?.isEmpty == false ? title! : "Video \(id)",
                url: url,
                thumbnailURL: thumb.flatMap { URL(string: $0) },
                subtitle: subtitle,
                duration: formatDuration(length),
                kind: .vod
            )
        }
    }

    private func parseGQLClips(json: [String: Any]) -> [ChannelVideoItem] {
        guard let data = json["data"] as? [String: Any],
              let user = data["user"] as? [String: Any],
              let clips = user["clips"] as? [String: Any],
              let edges = clips["edges"] as? [[String: Any]] else {
            return []
        }

        return edges.compactMap { edge in
            guard let node = edge["node"] as? [String: Any] else { return nil }
            let slug = (node["slug"] as? String) ?? (node["id"] as? String) ?? ""
            let id = slug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }

            let title = (node["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let length = node["durationSeconds"] as? Int
            let thumb = node["thumbnailURL"] as? String

            var subtitle: String?
            if let game = node["game"] as? [String: Any] {
                subtitle = (game["displayName"] as? String) ?? (game["name"] as? String)
            }

            let url = URL(string: "https://clips.twitch.tv/\(id)")!
            return ChannelVideoItem(
                id: id,
                title: title?.isEmpty == false ? title! : "Clip \(id)",
                url: url,
                thumbnailURL: thumb.flatMap { URL(string: $0) },
                subtitle: subtitle,
                duration: formatDuration(length),
                kind: .clip
            )
        }
    }

    private func formatDuration(_ seconds: Int?) -> String? {
        guard let seconds else { return nil }
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    private func twitchAuthToken() async -> String? {
        let cookies = await webKitCookies()
        let names: Set<String> = ["auth-token", "auth_token", "auth-token-next", "auth_token_next"]
        return cookies.first(where: {
            names.contains($0.name.lowercased()) && $0.domain.lowercased().contains("twitch.tv")
        })?.value
    }

    private func webKitCookies() async -> [HTTPCookie] {
        await Glitcho.webKitCookies()
    }

    func reload() {
        webView?.reload()
    }

    static func preferredRouteURLForTests(channel: String, section: Section, offline: Bool) -> URL {
        preferredRouteURL(channel: channel, section: section, offline: offline)
    }

    private static func preferredRouteURL(channel: String, section: Section, offline _: Bool) -> URL {
        switch section {
        case .videos:
            return URL(string: "https://www.twitch.tv/\(channel)/videos")!
        case .clips:
            return URL(string: "https://www.twitch.tv/\(channel)/clips")!
        }
    }

    private func preferredRouteURL(channel: String, section: Section, offline: Bool) -> URL {
        Self.preferredRouteURL(channel: channel, section: section, offline: offline)
    }

    private func fallbackRouteURL(channel: String, section: Section, offline: Bool) -> URL? {
        switch section {
        case .videos:
            return URL(string: "https://www.twitch.tv/\(channel)/videos?filter=archives&sort=time")
        case .clips:
            return URL(string: "https://www.twitch.tv/\(channel)/clips?range=all")
        }
    }

    private func routeAttemptKey(channel: String, section: Section, offline: Bool, fallback: Bool) -> String {
        "\(channel.lowercased())|\(section.rawValue)|offline=\(offline ? "1" : "0")|fallback=\(fallback ? "1" : "0")"
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.isLoading = true
            if let channel = self.currentChannel {
                self.scheduleLoadingDeadline(for: channel, section: self.section, offline: self.currentOfflineState)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__glitcho_scrapeChannelVideos && window.__glitcho_scrapeChannelVideos();", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async {
            self.loadingDeadlineWorkItem?.cancel()
            self.loadingDeadlineWorkItem = nil
            self.lastError = error.localizedDescription
            self.isLoading = false
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async {
            self.loadingDeadlineWorkItem?.cancel()
            self.loadingDeadlineWorkItem = nil
            self.lastError = error.localizedDescription
            self.isLoading = false
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "channelVideos" else { return }
        guard let dict = message.body as? [String: Any] else { return }
        guard let sectionString = (dict["section"] as? String)?.lowercased() else { return }
        guard let items = dict["items"] as? [[String: Any]] else { return }

        let section: Section
        if sectionString == "clips" {
            section = .clips
        } else {
            section = .videos
        }

        let parsed = items.compactMap { item -> ChannelVideoItem? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            guard let urlString = item["url"] as? String, let url = URL(string: urlString) else { return nil }
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? urlString

            let thumbString = (item["thumbnailURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let thumb = thumbString.isEmpty ? nil : URL(string: thumbString)

            let subtitle = (item["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = (item["duration"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let kindRaw = (item["kind"] as? String)?.lowercased() ?? ""
            let kind: NativePlaybackRequest.Kind = (kindRaw == "clip") ? .clip : .vod

            return ChannelVideoItem(
                id: id,
                title: title,
                url: url,
                thumbnailURL: thumb,
                subtitle: subtitle,
                duration: duration,
                kind: kind
            )
        }

        DispatchQueue.main.async {
            if parsed.isEmpty {
                let existing: [ChannelVideoItem]
                switch section {
                case .videos: existing = self.vods
                case .clips: existing = self.clips
                }
                if existing.isEmpty {
                    self.loadingDeadlineWorkItem?.cancel()
                    self.loadingDeadlineWorkItem = nil
                    self.isLoading = false
                }
                return
            }

            if self.isLowConfidenceVideosPayload(parsed, section: section) {
                let existing: [ChannelVideoItem]
                switch section {
                case .videos: existing = self.vods
                case .clips: existing = self.clips
                }
                if !existing.isEmpty {
                    return
                }
                if let channel = self.currentChannel,
                   let fallbackURL = self.fallbackRouteURL(
                    channel: channel,
                    section: section,
                    offline: self.currentOfflineState
                   ) {
                    let fallbackKey = self.routeAttemptKey(
                        channel: channel,
                        section: section,
                        offline: self.currentOfflineState,
                        fallback: true
                    )
                    if !self.routeFallbackAttempts.contains(fallbackKey) {
                        self.routeFallbackAttempts.insert(fallbackKey)
                        self.webView?.load(URLRequest(url: fallbackURL))
                        self.scheduleLoadingDeadline(
                            for: channel,
                            section: section,
                            offline: self.currentOfflineState
                        )
                        return
                    }
                }
            }

            self.loadingDeadlineWorkItem?.cancel()
            self.loadingDeadlineWorkItem = nil

            switch section {
            case .videos:
                if self.vods != parsed {
                    self.vods = parsed
                }
            case .clips:
                if self.clips != parsed {
                    self.clips = parsed
                }
            }

            self.isLoading = false
        }
    }

    private func isLowConfidenceVideosPayload(_ items: [ChannelVideoItem], section: Section) -> Bool {
        guard section == .videos else { return false }
        guard items.count >= 3 else { return false }

        let thumbs = items.compactMap { $0.thumbnailURL?.absoluteString.lowercased() }
        if thumbs.count < min(3, items.count) {
            return true
        }

        var frequency: [String: Int] = [:]
        for thumb in thumbs {
            frequency[thumb, default: 0] += 1
        }

        let maxRepeat = frequency.values.max() ?? 0
        let repeatRatio = Double(maxRepeat) / Double(max(1, thumbs.count))
        if repeatRatio >= 0.75 {
            return true
        }

        let uniqueRatio = Double(frequency.count) / Double(max(1, thumbs.count))
        return uniqueRatio < 0.5
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]

        contentController.add(self, name: "channelVideos")
        contentController.addUserScript(Self.blockMediaScript)
        contentController.addUserScript(Self.scrapeVideosScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        return webView
    }

    private static let scrapeVideosScript = WKUserScript(
        source: #"""
        (function() {
          if (window.__glitcho_channel_videos_scrape) { return; }
          window.__glitcho_channel_videos_scrape = true;

          function trim(s) {
            return (s || '').replace(/\s+/g, ' ').trim();
          }

          function absURL(href) {
            try {
              if (!href) return '';
              if (href.startsWith('http://') || href.startsWith('https://')) return href;
              return (new URL(href, window.location.origin)).toString();
            } catch (_) {
              return '';
            }
          }

          function currentSection() {
            try {
              const p = (window.location.pathname || '').toLowerCase();
              if (p.includes('/clips')) return 'clips';
              return 'videos';
            } catch (_) {
              return 'videos';
            }
          }

          function currentChannelLogin() {
            try {
              const parts = (window.location.pathname || '').split('/').filter(Boolean);
              if (!parts.length) return '';
              const first = (parts[0] || '').toLowerCase();
              if (first === 'videos' || first === 'clip') return '';
              return first;
            } catch (_) {
              return '';
            }
          }

          function normalizeText(s) {
            try {
              return (s || '')
                .toString()
                .toLowerCase()
                .normalize('NFD')
                .replace(/[\\u0300-\\u036f]/g, '')
                .trim();
            } catch (_) {
              return (s || '').toString().toLowerCase().trim();
            }
          }

          function clickIfMatch(el, needles) {
            if (!el) return false;
            const text = normalizeText(el.textContent || el.getAttribute('aria-label') || el.getAttribute('title') || '');
            if (!text) return false;
            for (const n of needles) {
              if (text.includes(n)) {
                try { el.click(); return true; } catch (_) { return false; }
              }
            }
            return false;
          }

          function ensureFilters(section) {
            try {
              const key = '__glitcho_filters_' + section;
              const attemptsKey = key + '_attempts';
              const attempts = window[attemptsKey] || 0;
              if (attempts >= 3) return false;

              const buttons = Array.from(document.querySelectorAll('button,[role="button"],a'));
              if (!buttons.length) return false;

              if (section === 'clips') {
                const needles = ['all time', 'all-time', 'tout le temps'];
                for (const el of buttons) {
                  if (clickIfMatch(el, needles)) {
                    window[attemptsKey] = attempts + 1;
                    return true;
                  }
                }
              } else {
                const needles = ['all videos', 'past broadcasts', 'archives', 'highlights', 'uploads'];
                for (const el of buttons) {
                  if (clickIfMatch(el, needles)) {
                    window[attemptsKey] = attempts + 1;
                    return true;
                  }
                }
              }
            } catch (_) {}
            return false;
          }

          function nudgeScroll() {
            try {
              const key = '__glitcho_scroll_nudge';
              const attempts = window[key] || 0;
              if (attempts >= 4) return;
              window[key] = attempts + 1;

              const scroller = document.scrollingElement || document.documentElement || document.body;
              if (!scroller) return;
              const max = scroller.scrollHeight || 0;
              const target = Math.min(900, max);
              scroller.scrollTop = target;
              setTimeout(function() {
                scroller.scrollTop = 0;
              }, 220);
            } catch (_) {}
          }

          function dismissGates() {
            try {
              const buttons = Array.from(document.querySelectorAll('button,[role="button"],a'));
              const acceptWords = [
                'accept', 'accept all', 'agree', 'i agree', 'got it', 'ok', 'okay',
                'accepter', 'tout accepter', 'j accepte', "j'accepte", "d'accord", 'ok',
              ];
              const matureWords = [
                'start watching', 'i understand', 'i understand and wish to proceed', 'watch anyway', 'continue',
                'commencer a regarder', 'commencer a visionner', 'je comprends', 'je comprends et je souhaite continuer',
                'continuer', 'regarder quand meme'
              ];

              for (const el of buttons) {
                if (clickIfMatch(el, acceptWords)) return true;
              }
              for (const el of buttons) {
                if (clickIfMatch(el, matureWords)) return true;
              }
            } catch (_) {}
            return false;
          }

          function safeText(el) {
            try { return trim(el && el.textContent ? el.textContent : ''); } catch (_) { return ''; }
          }

          function resolveRef(state, ref) {
            if (!state || !ref) return null;
            if (typeof ref === 'string') return state[ref] || null;
            return ref;
          }
          function getApolloState() {
            try {
              if (window.__APOLLO_STATE__ && Object.keys(window.__APOLLO_STATE__).length) {
                return window.__APOLLO_STATE__;
              }
            } catch (_) {}
            try {
              if (window.__INITIAL_STATE__ && window.__INITIAL_STATE__.apolloState) {
                return window.__INITIAL_STATE__.apolloState;
              }
            } catch (_) {}
            try {
              if (window.__APOLLO_CLIENT__ && window.__APOLLO_CLIENT__.cache && typeof window.__APOLLO_CLIENT__.cache.extract === 'function') {
                const extracted = window.__APOLLO_CLIENT__.cache.extract();
                if (extracted && Object.keys(extracted).length) {
                  return extracted;
                }
              }
            } catch (_) {}
            return null;
          }

          function formatDuration(totalSeconds) {
            try {
              const s = Math.max(0, Math.floor(Number(totalSeconds) || 0));
              const h = Math.floor(s / 3600);
              const m = Math.floor((s % 3600) / 60);
              const sec = s % 60;
              if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
              return `${m}:${String(sec).padStart(2, '0')}`;
            } catch (_) {
              return '';
            }
          }

          function bestImageURL(img) {
            try {
              if (!img) return '';
              const u = (img.currentSrc || img.src || img.getAttribute('src') || '').trim();
              if (!u) return '';
              if (u.startsWith('data:')) return '';
              return u;
            } catch (_) {
              return '';
            }
          }

          function nearestVideoContainer(anchor) {
            try {
              if (!anchor) return null;
              return anchor.closest(
                'article,[role="listitem"],li,' +
                '[data-a-target*="video"],[data-test-selector*="video"],' +
                '[class*="video-card"],[class*="thumbnail"]'
              );
            } catch (_) {
              return null;
            }
          }

          function videoIDFromHref(href) {
            try {
              const u = href.startsWith('http') ? new URL(href) : new URL(href, window.location.origin);
              const m = (u.pathname || '').match(/\/videos\/(\d+)/);
              return m ? m[1] : '';
            } catch (_) {
              const m = (href || '').match(/\/videos\/(\d+)/);
              return m ? m[1] : '';
            }
          }

          function canonicalVideoURL(id) {
            return 'https://www.twitch.tv/videos/' + id;
          }

          function clipSlugFromHref(href) {
            try {
              const u = href.startsWith('http') ? new URL(href) : new URL(href, window.location.origin);
              const host = (u.host || '').toLowerCase();
              if (host === 'clips.twitch.tv') {
                const parts = (u.pathname || '').split('/').filter(Boolean);
                return parts[0] || '';
              }
              const parts = (u.pathname || '').split('/').filter(Boolean);
              const idx = parts.findIndex(p => (p || '').toLowerCase() === 'clip');
              if (idx >= 0 && parts[idx + 1]) return parts[idx + 1];
            } catch (_) {}
            const m = (href || '').match(/\/clip\/([^/?#]+)/i);
            return m ? m[1] : '';
          }

          function canonicalClipURL(slug) {
            return 'https://clips.twitch.tv/' + slug;
          }

          function pickTitle(anchor, card, img, fallback) {
            const candidates = [];
            try { candidates.push(trim(anchor.getAttribute('title') || '')); } catch (_) {}
            try { candidates.push(trim(anchor.getAttribute('aria-label') || '')); } catch (_) {}
            try { candidates.push(trim(safeText(anchor))); } catch (_) {}
            try { candidates.push(trim(img ? (img.getAttribute('alt') || '') : '')); } catch (_) {}

            try {
              const titleEl = card && (card.querySelector('[data-a-target*="title"]') || card.querySelector('h3,h2,[role="heading"]'));
              if (titleEl) { candidates.push(safeText(titleEl)); }
            } catch (_) {}

            try {
              const ps = card ? Array.from(card.querySelectorAll('p')).slice(0, 4) : [];
              for (const p of ps) { candidates.push(safeText(p)); }
            } catch (_) {}

            for (const c of candidates) {
              const t = trim(c);
              if (!t) continue;
              if (t.length < 3) continue;
              const lower = t.toLowerCase();
              if (lower === 'stream') continue;
              if (t.length > 140) return t.slice(0, 140);
              return t;
            }
            return fallback;
          }

          function findDurationIn(card) {
            if (!card) { return ''; }
            try {
              const nodes = Array.from(card.querySelectorAll('span,div')).slice(0, 120);
              for (const el of nodes) {
                const t = safeText(el);
                if (!t) continue;
                if (/^\d+:\d{2}(:\d{2})?$/.test(t)) {
                  return t;
                }
              }
            } catch (_) {}
            return '';
          }

          function findSubtitleIn(card, title, duration) {
            if (!card) { return ''; }
            try {
              const nodes = Array.from(card.querySelectorAll('p,span')).slice(0, 120);
              const candidates = [];
              for (const el of nodes) {
                const t = safeText(el);
                if (!t) continue;
                if (t === title) continue;
                if (duration && t === duration) continue;
                if (t.length < 3) continue;
                const lower = t.toLowerCase();
                if (lower === 'stream') continue;
                candidates.push(t);
              }
              return candidates.slice(0, 2).join(' • ');
            } catch (_) {}
            return '';
          }

          function extractVods() {
            const items = [];
            const seen = {};
            function extractFromApollo() {
              try {
                const state = getApolloState();
                if (!state) return false;
                const login = currentChannelLogin();
                const videoKeys = Object.keys(state).filter(k => {
                  const n = state[k];
                  return n && n.__typename === 'Video';
                });
                if (!videoKeys.length) return false;

                for (const key of videoKeys) {
                  const node = state[key];
                  if (!node || node.__typename !== 'Video') continue;
                  const owner = resolveRef(state, node.owner);
                  const ownerLogin = (owner && (owner.login || owner.displayName) || '').toString().toLowerCase();
                  if (login && ownerLogin && ownerLogin !== login) continue;

                  const id = String(node.id || '').trim();
                  if (!id || seen[id]) continue;
                  seen[id] = true;

                  const game = resolveRef(state, node.game);
                  const gameName = (game && (game.displayName || game.name)) ? (game.displayName || game.name) : '';

                  let thumb = node.previewThumbnailURL || node.thumbnailURL || '';
                  if (typeof thumb === 'string') {
                    thumb = thumb.replace('%{width}', '640').replace('%{height}', '360');
                  } else {
                    thumb = '';
                  }

                  const duration = formatDuration(node.lengthSeconds || node.durationSeconds || node.duration || 0);
                  const title = trim(node.title || `Video ${id}`);
                  const subtitle = gameName ? gameName : '';

                  items.push({
                    id: id,
                    kind: 'vod',
                    url: canonicalVideoURL(id),
                    title: title || (`Video ${id}`),
                    thumbnailURL: thumb,
                    duration: duration,
                    subtitle: subtitle
                  });
                }

                return items.length > 0;
              } catch (_) {
                return false;
              }
            }

            function pushFromCard(card) {
              try {
                if (!card) return;
                const a = card.querySelector('a[href*="/videos/"]');
                if (!a) return;

                const href = a.getAttribute('href') || '';
                const id = videoIDFromHref(href);
                if (!id) return;
                if (seen[id]) return;
                seen[id] = true;

                const img = card.querySelector('img') || a.querySelector('img');
                const thumb = bestImageURL(img);
                const title = pickTitle(a, card, img, 'Video ' + id);
                const duration = findDurationIn(card);
                const subtitle = findSubtitleIn(card, title, duration);

                items.push({
                  id: id,
                  kind: 'vod',
                  url: canonicalVideoURL(id),
                  title: title,
                  thumbnailURL: thumb,
                  duration: duration,
                  subtitle: subtitle
                });
              } catch (_) {}
            }

            // Prefer actual cards (Twitch uses virtualized grids).
            try {
              const cards = Array.from(document.querySelectorAll('article')).slice(0, 250);
              for (const card of cards) {
                pushFromCard(card);
              }
            } catch (_) {}

            if (items.length) {
              return items.slice(0, 80);
            }

            // Fallback: scan anchors.
            try {
              const anchors = Array.from(document.querySelectorAll('a[href*="/videos/"]')).slice(0, 600);
              for (const a of anchors) {
                const href = a.getAttribute('href') || '';
                const id = videoIDFromHref(href);
                if (!id) continue;
                if (seen[id]) continue;

                const card = nearestVideoContainer(a) || a.closest('article') || a;
                const img = a.querySelector('img') || (card && card.querySelector('img'));
                if (!img) continue;
                const thumb = bestImageURL(img);
                const title = pickTitle(a, card, img, 'Video ' + id);
                const duration = findDurationIn(card);
                const subtitle = findSubtitleIn(card, title, duration);

                seen[id] = true;
                items.push({
                  id: id,
                  kind: 'vod',
                  url: canonicalVideoURL(id),
                  title: title,
                  thumbnailURL: thumb,
                  duration: duration,
                  subtitle: subtitle
                });

                if (items.length >= 80) break;
              }
            } catch (_) {}

            if (items.length) {
              return items.slice(0, 80);
            }

            if (extractFromApollo()) {
              return items.slice(0, 80);
            }

            return items;
          }

          function extractClips() {
            const items = [];
            const seen = {};
            function extractFromApollo() {
              try {
                const state = window.__APOLLO_STATE__ || null;
                if (!state) return false;
                const login = currentChannelLogin();
                const clipKeys = Object.keys(state).filter(k => {
                  const n = state[k];
                  return n && n.__typename === 'Clip';
                });
                if (!clipKeys.length) return false;

                for (const key of clipKeys) {
                  const node = state[key];
                  if (!node || node.__typename !== 'Clip') continue;
                  const broadcaster = resolveRef(state, node.broadcaster);
                  const broadcasterLogin = (broadcaster && (broadcaster.login || broadcaster.displayName) || '').toString().toLowerCase();
                  if (login && broadcasterLogin && broadcasterLogin !== login) continue;

                  const slug = String(node.slug || node.id || '').trim();
                  if (!slug || seen[slug]) continue;
                  seen[slug] = true;

                  let thumb = node.thumbnailURL || node.previewImageURL || node.tinyThumbnailURL || '';
                  if (typeof thumb === 'string') {
                    thumb = thumb.replace('%{width}', '640').replace('%{height}', '360');
                  } else {
                    thumb = '';
                  }

                  const duration = formatDuration(node.durationSeconds || node.duration || 0);
                  const title = trim(node.title || `Clip ${slug}`);

                  const game = resolveRef(state, node.game);
                  const gameName = (game && (game.displayName || game.name)) ? (game.displayName || game.name) : '';
                  const subtitle = gameName ? gameName : '';

                  items.push({
                    id: slug,
                    kind: 'clip',
                    url: canonicalClipURL(slug),
                    title: title || (`Clip ${slug}`),
                    thumbnailURL: thumb,
                    duration: duration,
                    subtitle: subtitle
                  });
                }

                return items.length > 0;
              } catch (_) {
                return false;
              }
            }

            function pushFromCard(card) {
              try {
                if (!card) return;
                const a = card.querySelector('a[href*="/clip/"], a[href*="clips.twitch.tv/"]');
                if (!a) return;

                const hrefAbs = absURL(a.getAttribute('href') || '');
                if (!hrefAbs) return;

                const slug = clipSlugFromHref(hrefAbs);
                if (!slug) return;
                if (seen[slug]) return;
                seen[slug] = true;

                const img = card.querySelector('img') || a.querySelector('img');
                const thumb = bestImageURL(img);
                const title = pickTitle(a, card, img, 'Clip ' + slug);
                const duration = findDurationIn(card);
                const subtitle = findSubtitleIn(card, title, duration);

                items.push({
                  id: slug,
                  kind: 'clip',
                  url: canonicalClipURL(slug),
                  title: title,
                  thumbnailURL: thumb,
                  duration: duration,
                  subtitle: subtitle
                });
              } catch (_) {}
            }

            // Prefer actual cards.
            try {
              const cards = Array.from(document.querySelectorAll('article')).slice(0, 300);
              for (const card of cards) {
                pushFromCard(card);
              }
            } catch (_) {}

            if (items.length) {
              return items.slice(0, 80);
            }

            // Fallback: scan anchors.
            try {
              const anchors = Array.from(document.querySelectorAll('a[href]')).slice(0, 900);
              for (const a of anchors) {
                const rawHref = a.getAttribute('href') || '';
                if (!rawHref) continue;
                const hrefAbs = absURL(rawHref);
                if (!hrefAbs) continue;

                const isClip = hrefAbs.includes('clips.twitch.tv/') || rawHref.toLowerCase().includes('/clip/');
                if (!isClip) continue;

                const slug = clipSlugFromHref(hrefAbs);
                if (!slug) continue;
                if (seen[slug]) continue;

                const card = nearestVideoContainer(a) || a.closest('article') || a;
                const img = a.querySelector('img') || (card && card.querySelector('img'));
                if (!img) continue;
                const thumb = bestImageURL(img);
                const title = pickTitle(a, card, img, 'Clip ' + slug);
                const duration = findDurationIn(card);
                const subtitle = findSubtitleIn(card, title, duration);

                seen[slug] = true;
                items.push({
                  id: slug,
                  kind: 'clip',
                  url: canonicalClipURL(slug),
                  title: title,
                  thumbnailURL: thumb,
                  duration: duration,
                  subtitle: subtitle
                });

                if (items.length >= 80) break;
              }
            } catch (_) {}

            if (items.length) {
              return items.slice(0, 80);
            }

            if (extractFromApollo()) {
              return items.slice(0, 80);
            }

            return items;
          }

          let lastSent = null;
          let pending = false;

          function postIfChanged() {
            dismissGates();
            const section = currentSection();
            const items = (section === 'clips') ? extractClips() : extractVods();
            if (!items || items.length === 0) {
              ensureFilters(section);
              nudgeScroll();
            }
            let serialized = null;
            try { serialized = JSON.stringify(items); } catch (_) { serialized = null; }
            if (serialized === lastSent) { return; }
            lastSent = serialized;
            try {
              window.webkit.messageHandlers.channelVideos.postMessage({ section: section, items: items });
            } catch (_) {}
          }

          function schedulePost() {
            if (pending) { return; }
            pending = true;
            setTimeout(function() {
              pending = false;
              postIfChanged();
            }, 350);
          }

          window.__glitcho_scrapeChannelVideos = postIfChanged;

          postIfChanged();
          const observer = new MutationObserver(schedulePost);
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setTimeout(postIfChanged, 1000);
          setTimeout(postIfChanged, 2000);
          setTimeout(postIfChanged, 4000);
        })();
        """#,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private static let blockMediaScript = WKUserScript(
        source: #"""
        (function() {
          if (window.__glitcho_block_media_scraper) { return; }
          window.__glitcho_block_media_scraper = true;

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

          // Block programmatic play() calls.
          try {
            const origPlay = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function() {
              try { this.pause(); } catch (e) {}
              try { this.muted = true; this.volume = 0; } catch (e) {}
              return Promise.reject(new Error('Blocked by Glitcho'));
            };
            window.__glitcho_origPlay_scraper = origPlay;
          } catch (e) {}

          pauseAll();
          const observer = new MutationObserver(pauseAll);
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setInterval(pauseAll, 2000);
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
}

struct ChannelVideosScraperView: NSViewRepresentable {
    @ObservedObject var store: ChannelVideosStore

    func makeNSView(context: Context) -> WKWebView {
        let view = store.attachWebView()
        view.isHidden = false
        // Keep a tiny non-zero alpha so WebKit doesn’t treat it as fully invisible/offscreen.
        view.alphaValue = 0.01
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.isHidden = false
        nsView.alphaValue = 0.01
    }
}

struct ChannelScheduleItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let startAt: Date
    let endAt: Date?
    let isRecurring: Bool
    let isCanceled: Bool
}

final class ChannelScheduleStore: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var items: [ChannelScheduleItem] = []
    @Published var isLoading = false
    @Published var lastError: String?

    private var webView: WKWebView?
    private var currentChannel: String?
    private var loadingDeadlineWorkItem: DispatchWorkItem?

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

        loadingDeadlineWorkItem?.cancel()
        isLoading = true
        lastError = nil
        items = []
        scheduleLoadingDeadline(for: normalized)

        let url = URL(string: "https://www.twitch.tv/\(normalized)/schedule")!
        webView?.load(URLRequest(url: url))
    }

    private func scheduleLoadingDeadline(for channel: String) {
        loadingDeadlineWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentChannel == channel else { return }
            if self.isLoading {
                self.isLoading = false
            }
        }
        loadingDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]

        contentController.add(self, name: "channelSchedule")
        contentController.addUserScript(Self.blockMediaScript)
        contentController.addUserScript(Self.scrapeScheduleScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        return webView
    }

    private static let scrapeScheduleScript = WKUserScript(
        source: #"""
        (function() {
          if (window.__glitcho_schedule_scrape) { return; }
          window.__glitcho_schedule_scrape = true;

          function trim(s) {
            return (s || '').replace(/\s+/g, ' ').trim();
          }

          function getApolloState() {
            try {
              if (window.__APOLLO_STATE__ && Object.keys(window.__APOLLO_STATE__).length) {
                return window.__APOLLO_STATE__;
              }
            } catch (_) {}
            try {
              if (window.__INITIAL_STATE__ && window.__INITIAL_STATE__.apolloState) {
                return window.__INITIAL_STATE__.apolloState;
              }
            } catch (_) {}
            return null;
          }

          function resolveRef(state, ref) {
            if (!state || !ref) return null;
            if (typeof ref === 'string') return state[ref] || null;
            return ref;
          }

          function extractFromApollo() {
            const state = getApolloState();
            if (!state) { return []; }

            const items = [];
            const seen = new Set();
            const keys = Object.keys(state);
            for (const key of keys) {
              const node = state[key];
              if (!node || typeof node !== 'object') { continue; }
              const type = (node.__typename || '').toLowerCase();
              if (!(type.includes('schedule') && type.includes('segment'))) { continue; }

              const startAt = node.startAt || node.startTime || node.startsAt || node.startDate || '';
              if (!startAt) { continue; }

              const endAt = node.endAt || node.endTime || node.endsAt || node.endDate || '';
              const title = trim(node.title || node.description || node.name || 'Scheduled stream');
              const recurring = !!node.isRecurring;
              const canceled = !!node.isCanceled || !!node.isCancelled || !!node.canceledUntil;
              const category = resolveRef(state, node.category) || resolveRef(state, node.game);
              const subtitle = trim((category && (category.displayName || category.name)) || '');

              const id = String(node.id || key);
              if (seen.has(id)) { continue; }
              seen.add(id);

              items.push({
                id: id,
                title: title || 'Scheduled stream',
                subtitle: subtitle,
                startAt: startAt,
                endAt: endAt,
                isRecurring: recurring,
                isCanceled: canceled
              });
            }

            return items;
          }

          function extractFromDOM() {
            const cards = Array.from(document.querySelectorAll('article, [data-test-selector*="segment"], [data-a-target*="segment"]')).slice(0, 200);
            const items = [];
            const seen = new Set();

            for (const card of cards) {
              const timeEls = Array.from(card.querySelectorAll('time[datetime]'));
              const startAt = trim((timeEls[0] && timeEls[0].getAttribute('datetime')) || '');
              if (!startAt) { continue; }
              const endAt = trim((timeEls[1] && timeEls[1].getAttribute('datetime')) || '');

              const heading = card.querySelector('h1,h2,h3,[role="heading"]');
              const title = trim((heading && heading.textContent) || '');
              const subtitleNode = card.querySelector('p,span');
              const subtitle = trim((subtitleNode && subtitleNode.textContent) || '');
              const id = trim(card.getAttribute('data-a-id') || card.getAttribute('data-id') || startAt + '|' + title);
              if (!id || seen.has(id)) { continue; }
              seen.add(id);

              items.push({
                id: id,
                title: title || 'Scheduled stream',
                subtitle: subtitle,
                startAt: startAt,
                endAt: endAt,
                isRecurring: false,
                isCanceled: false
              });
            }

            return items;
          }

          function normalize(items) {
            return (items || [])
              .filter(i => i && i.startAt)
              .sort((a, b) => {
                const av = Date.parse(a.startAt || '') || 0;
                const bv = Date.parse(b.startAt || '') || 0;
                return av - bv;
              })
              .slice(0, 120);
          }

          let lastSent = null;
          let pending = false;

          function postIfChanged() {
            const apollo = extractFromApollo();
            const dom = apollo.length ? [] : extractFromDOM();
            const items = normalize(apollo.length ? apollo : dom);
            let serialized = null;
            try { serialized = JSON.stringify(items); } catch (_) { serialized = null; }
            if (serialized === lastSent) { return; }
            lastSent = serialized;
            try {
              window.webkit.messageHandlers.channelSchedule.postMessage({ items: items });
            } catch (_) {}
          }

          function schedulePost() {
            if (pending) { return; }
            pending = true;
            setTimeout(function() {
              pending = false;
              postIfChanged();
            }, 350);
          }

          window.__glitcho_scrapeChannelSchedule = postIfChanged;
          postIfChanged();
          const observer = new MutationObserver(schedulePost);
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setTimeout(postIfChanged, 1000);
          setTimeout(postIfChanged, 2000);
          setTimeout(postIfChanged, 4000);
        })();
        """#,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private static let blockMediaScript = WKUserScript(
        source: #"""
        (function() {
          if (window.__glitcho_block_media_schedule) { return; }
          window.__glitcho_block_media_schedule = true;

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

          try {
            const origPlay = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function() {
              try { this.pause(); } catch (e) {}
              try { this.muted = true; this.volume = 0; } catch (e) {}
              return Promise.reject(new Error('Blocked by Glitcho'));
            };
            window.__glitcho_origPlay_schedule = origPlay;
          } catch (e) {}

          pauseAll();
          const observer = new MutationObserver(pauseAll);
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setInterval(pauseAll, 2000);
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    func reload() {
        webView?.reload()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.isLoading = true
            if let channel = self.currentChannel {
                self.scheduleLoadingDeadline(for: channel)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__glitcho_scrapeChannelSchedule && window.__glitcho_scrapeChannelSchedule();", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async {
            self.loadingDeadlineWorkItem?.cancel()
            self.loadingDeadlineWorkItem = nil
            self.lastError = error.localizedDescription
            self.isLoading = false
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async {
            self.loadingDeadlineWorkItem?.cancel()
            self.loadingDeadlineWorkItem = nil
            self.lastError = error.localizedDescription
            self.isLoading = false
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "channelSchedule" else { return }
        guard let dict = message.body as? [String: Any] else { return }
        guard let payload = dict["items"] as? [[String: Any]] else { return }

        let parsed = payload.compactMap { raw -> ChannelScheduleItem? in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            guard let startRaw = raw["startAt"] as? String else { return nil }
            guard let startAt = Self.parseISO8601(startRaw) else { return nil }

            let title = ((raw["title"] as? String) ?? "Scheduled stream").trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = ((raw["subtitle"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let endAt = (raw["endAt"] as? String).flatMap(Self.parseISO8601)
            let isRecurring = (raw["isRecurring"] as? Bool) ?? false
            let isCanceled = (raw["isCanceled"] as? Bool) ?? false

            return ChannelScheduleItem(
                id: id,
                title: title.isEmpty ? "Scheduled stream" : title,
                subtitle: subtitle,
                startAt: startAt,
                endAt: endAt,
                isRecurring: isRecurring,
                isCanceled: isCanceled
            )
        }

        DispatchQueue.main.async {
            self.loadingDeadlineWorkItem?.cancel()
            self.loadingDeadlineWorkItem = nil

            if parsed.isEmpty {
                if self.items.isEmpty {
                    self.isLoading = false
                }
                return
            }

            if self.items != parsed {
                self.items = parsed
            }
            self.isLoading = false
        }
    }

    private static let iso8601FormatterWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601FormatterPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseISO8601(_ value: String) -> Date? {
        iso8601FormatterWithFraction.date(from: value) ?? iso8601FormatterPlain.date(from: value)
    }
}

struct ChannelScheduleScraperView: NSViewRepresentable {
    @ObservedObject var store: ChannelScheduleStore

    func makeNSView(context: Context) -> WKWebView {
        let view = store.attachWebView()
        view.isHidden = false
        view.alphaValue = 0.01
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.isHidden = false
        nsView.alphaValue = 0.01
    }
}

struct ChannelSchedulePanelView: View {
    let channelName: String
    @ObservedObject var store: ChannelScheduleStore

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.isLoading && store.items.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading schedule…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                } else if store.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No schedule available.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                        if let error = store.lastError, !error.isEmpty {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(3)
                        }
                    }
                } else {
                    ForEach(store.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(2)

                            Text(scheduleTimeText(item))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))

                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.56))
                                    .lineLimit(2)
                            }

                            if item.isRecurring || item.isCanceled {
                                HStack(spacing: 8) {
                                    if item.isRecurring {
                                        pill("Recurring")
                                    }
                                    if item.isCanceled {
                                        pill("Canceled")
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(
            ChannelScheduleScraperView(store: store)
                .frame(width: 1200, height: 900)
                .allowsHitTesting(false)
                .opacity(0.001)
        )
        .onAppear {
            store.load(channelName: channelName)
        }
        .onChange(of: channelName) { newValue in
            store.load(channelName: newValue)
        }
    }

    private func scheduleTimeText(_ item: ChannelScheduleItem) -> String {
        let start = Self.dateFormatter.string(from: item.startAt)
        if let end = item.endAt {
            return "\(start) - \(Self.dateFormatter.string(from: end))"
        }
        return start
    }

    private func pill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct TwitchUnderlineTabs<T: Hashable>: View {
    let tabs: [T]
    @Binding var selection: T
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 18) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 6) {
                        Text(title(tab))
                            .font(.system(size: 12, weight: selection == tab ? .semibold : .medium))
                            .foregroundColor(selection == tab ? .white.opacity(0.92) : .white.opacity(0.6))

                        Rectangle()
                            .fill(selection == tab ? Color.purple.opacity(0.95) : Color.clear)
                            .frame(height: 2)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ChannelVideoCardView: View {
    let item: ChannelVideoItem
    @State private var isHovering = false
    @State private var showPreview = false
    @State private var hoverWorkItem: DispatchWorkItem?
    @State private var previewURL: URL?
    @State private var previewTask: Task<Void, Never>?
    @StateObject private var previewStreamlink = StreamlinkManager()

    private var placeholder: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func hoverPreviewURL() -> URL? {
        guard let url = item.thumbnailURL else { return nil }
        let s = url.absoluteString
        let upgraded = s
            .replacingOccurrences(of: "320x180", with: "640x360")
            .replacingOccurrences(of: "480x270", with: "640x360")
            .replacingOccurrences(of: "%7Bwidth%7D", with: "640")
            .replacingOccurrences(of: "%7Bheight%7D", with: "360")
            .replacingOccurrences(of: "%{width}", with: "640")
            .replacingOccurrences(of: "%{height}", with: "360")
        return URL(string: upgraded) ?? url
    }
    private func previewTarget() -> String {
        item.url.absoluteString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumb = item.thumbnailURL {
                        AsyncImage(url: thumb) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            placeholder
                        }
                    } else {
                        placeholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                if let duration = item.duration, !duration.isEmpty {
                    Text(duration)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(8)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovering ? Color.purple.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if item.kind == .clip {
                    Text("CLIP")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(8)
                }
            }

            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(2)

            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.white.opacity(isHovering ? 0.07 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
            hoverWorkItem?.cancel()
            if hovering {
                let work = DispatchWorkItem {
                    showPreview = true
                    startPreview()
                }
                hoverWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            } else {
                showPreview = false
                stopPreview()
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                ZStack {
                    if let previewURL = hoverPreviewURL() {
                        AsyncImage(url: previewURL) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            placeholder
                        }
                    } else {
                        placeholder
                    }

                    if let previewURL {
                        NativeHoverPlayerView(url: previewURL)
                    } else if previewStreamlink.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 360, height: 203)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(width: 380)
            .background(Color.black.opacity(0.9))
        }
    }

    private func startPreview() {
        previewTask?.cancel()
        previewURL = nil
        previewStreamlink.error = nil
        previewStreamlink.isLoading = true
        let target = previewTarget()
        previewTask = Task {
            do {
                let url = try await previewStreamlink.getStreamURL(target: target, quality: "worst")
                await MainActor.run {
                    if showPreview {
                        previewURL = url
                        previewStreamlink.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    previewStreamlink.isLoading = false
                }
            }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewStreamlink.stopStream()
        previewURL = nil
        previewStreamlink.isLoading = false
    }
}

struct ChannelVideosPanelView: View {
    let channelName: String
    @ObservedObject var store: ChannelVideosStore
    let isChannelOffline: Bool
    let onSelectPlayback: (NativePlaybackRequest) -> Void

    private let gridColumns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16, alignment: .top)
    ]

    private var currentItems: [ChannelVideoItem] {
        switch store.section {
        case .videos:
            return store.vods
        case .clips:
            return store.clips
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                TwitchUnderlineTabs(
                    tabs: ChannelVideosStore.Section.allCases,
                    selection: Binding(
                        get: { store.section },
                        set: { newValue in
                            store.load(channelName: channelName, section: newValue, isChannelOffline: isChannelOffline)
                        }
                    )
                ) { $0.rawValue }

                Spacer()

                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                if currentItems.isEmpty && store.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if currentItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text({
                            switch store.section {
                            case .clips: return "No clips found yet."
                            case .videos: return "No videos found yet."
                            }
                        }())
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))

                        if let error = store.lastError, !error.isEmpty {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                        ForEach(currentItems) { item in
                            Button {
                                onSelectPlayback(
                                    NativePlaybackRequest(
                                        kind: item.kind,
                                        streamlinkTarget: item.url.absoluteString,
                                        channelName: channelName
                                    )
                                )
                            } label: {
                                ChannelVideoCardView(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .overlay(
            ChannelVideosScraperView(store: store)
                // Keep a real viewport so Twitch’s virtualized grids actually render.
                .frame(width: 1200, height: 900)
                .allowsHitTesting(false)
                .opacity(0.001)
        )
        .onAppear {
            store.load(channelName: channelName, section: store.section, isChannelOffline: isChannelOffline)
        }
        .onChange(of: channelName) { newValue in
            store.load(channelName: newValue, section: store.section, isChannelOffline: isChannelOffline)
        }
        .onChange(of: isChannelOffline) { offline in
            store.load(channelName: channelName, section: store.section, isChannelOffline: offline)
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
      }, 1000);
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

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
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
              setInterval(pauseAll, 2000);
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
                            });
                        } catch (e) {}
                    });
                    
                    // 3. Supprimer les iframes de player
                    document.querySelectorAll('iframe').forEach(iframe => {
                        if (iframe.src && iframe.src.includes('player')) {
                            iframe.remove();
                        }
                    });
                }
                
                nukePlayerAndChat();
                setInterval(nukePlayerAndChat, 2000);
                const observer = new MutationObserver(nukePlayerAndChat);
                observer.observe(document.documentElement, { 
                    childList: true, 
                    subtree: true,
                    attributes: false 
                });
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
