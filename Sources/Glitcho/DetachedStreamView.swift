#if canImport(SwiftUI)
import AVKit
import AppKit
import SwiftUI

// MARK: - Window context

struct StreamWindowContext: Codable, Hashable {
    let channelLogin: String
}

// MARK: - Detached stream window view

struct DetachedStreamView: View {
    let channelLogin: String

    @StateObject private var streamlink = StreamlinkManager()
    @State private var player: AVPlayer?
    @State private var isPlaying = true
    @State private var volume: Double = 1.0
    @State private var isMuted = false
    @State private var isHoveringControls = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if streamlink.isLoading {
                loadingView
            } else if let error = streamlink.error {
                errorView(message: error)
            }

            overlayControls
        }
        .background(StreamWindowConfigurator(channelLogin: channelLogin))
        .task { await loadStream() }
        .onDisappear { teardown() }
    }

    // MARK: - Sub-views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)
            Text("Loading \(channelLogin)...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.yellow)
            Text("Stream unavailable")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                Task { await loadStream() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.14))
            .clipShape(Capsule())
        }
    }

    private var overlayControls: some View {
        VStack(spacing: 0) {
            // Channel name badge — top-left
            HStack {
                Text(channelLogin)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                Spacer()
            }

            Spacer()

            // Playback controls — bottom bar
            HStack(spacing: 16) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")

                Button(action: toggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute" : "Mute")

                Slider(value: $volume, in: 0...1)
                    .frame(width: 80)
                    .onChange(of: volume) { _ in applyVolume() }

                Spacer()

                // Live badge
                if player != nil && streamlink.error == nil {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.red, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .opacity(isHoveringControls || player == nil ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: isHoveringControls)
        .onHover { isHoveringControls = $0 }
    }

    // MARK: - Actions

    private func loadStream() async {
        player?.pause()
        player = nil
        do {
            let url = try await streamlink.getStreamURL(for: channelLogin)
            let newPlayer = AVPlayer(url: url)
            newPlayer.volume = Float(volume)
            newPlayer.isMuted = isMuted
            newPlayer.play()
            player = newPlayer
            isPlaying = true
        } catch {
            // StreamlinkManager publishes its own error string; no separate handling needed.
        }
    }

    private func teardown() {
        player?.pause()
        player = nil
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func toggleMute() {
        isMuted.toggle()
        applyVolume()
    }

    private func applyVolume() {
        guard let player else { return }
        player.isMuted = isMuted || volume <= 0
        player.volume = Float(volume)
    }
}

// MARK: - Window configurator

/// Applies floating-window chrome consistent with other detached windows in the app.
private struct StreamWindowConfigurator: NSViewRepresentable {
    let channelLogin: String

    func makeNSView(context: Context) -> NSView { ConfigView(channelLogin: channelLogin) }
    func updateNSView(_ nsView: NSView, context: Context) { _ = nsView }

    private final class ConfigView: NSView {
        private let channelLogin: String

        init(channelLogin: String) {
            self.channelLogin = channelLogin
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.title = channelLogin
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = .black
        }
    }
}

#endif
