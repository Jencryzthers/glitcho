import SwiftUI
import AppKit
import AVKit
import AVFoundation

struct RecordingEntry: Identifiable, Hashable {
    let url: URL
    let channelName: String
    let recordedAt: Date?

    var id: URL { url }
}

struct RecordingsLibraryView: View {
    @ObservedObject var recordingManager: RecordingManager
    @State private var recordings: [RecordingEntry] = []
    @State private var selectedRecording: RecordingEntry?
    @State private var isPlaying = true

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recordings")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        refreshRecordings()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh recordings")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if recordings.isEmpty {
                            Text("No recordings yet.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(groupedRecordings, id: \.channel) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(group.channel.uppercased())
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .tracking(1.2)
                                        .padding(.horizontal, 16)

                                    ForEach(group.items) { recording in
                                        RecordingRow(
                                            recording: recording,
                                            formattedDate: formattedDate(for: recording),
                                            isSelected: recording == selectedRecording
                                        ) {
                                            selectedRecording = recording
                                            isPlaying = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
            .background(
                Color(red: 0.07, green: 0.07, blue: 0.09)
            )

            Divider()
                .background(Color.white.opacity(0.08))

            VStack(spacing: 0) {
                if let selectedRecording {
                    NativeVideoPlayer(url: selectedRecording.url, isPlaying: $isPlaying)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Select a recording to play")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.05, green: 0.05, blue: 0.07))
                }
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
        }
        .onAppear {
            refreshRecordings()
        }
    }

    private var groupedRecordings: [(channel: String, items: [RecordingEntry])] {
        let groups = Dictionary(grouping: recordings) { $0.channelName }
        return groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { key in
                let items = groups[key, default: []].sorted { left, right in
                    switch (left.recordedAt, right.recordedAt) {
                    case let (lhs?, rhs?):
                        return lhs > rhs
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        return left.url.lastPathComponent < right.url.lastPathComponent
                    }
                }
                return (channel: key, items: items)
            }
    }

    private func formattedDate(for recording: RecordingEntry) -> String {
        guard let date = recording.recordedAt else { return "Unknown date" }
        return dateFormatter.string(from: date)
    }

    private func refreshRecordings() {
        recordings = recordingManager.listRecordings()
        if selectedRecording == nil {
            selectedRecording = recordings.first
        }
    }
}

struct RecordingRow: View {
    let recording: RecordingEntry
    let formattedDate: String
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                RecordingThumbnailView(url: recording.url)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(recording.channelName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(formattedDate)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.12 : 0.0), lineWidth: 1)
        )
    }
}

struct RecordingThumbnailView: View {
    let url: URL
    @StateObject private var loader: RecordingThumbnailLoader
    @StateObject private var previewController: RecordingPreviewController
    @State private var isHovered = false

    init(url: URL) {
        self.url = url
        _loader = StateObject(wrappedValue: RecordingThumbnailLoader(url: url))
        _previewController = StateObject(wrappedValue: RecordingPreviewController(url: url))
    }

    var body: some View {
        ZStack {
            if isHovered {
                RecordingPreviewPlayer(player: previewController.player, isPlaying: true)
                    .transition(.opacity)
            } else if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    ProgressView()
                        .scaleEffect(0.5)
                        .tint(.white.opacity(0.4))
                }
            }
        }
        .clipped()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            previewController.setPlaying(hovering)
        }
        .onDisappear {
            previewController.setPlaying(false)
        }
    }
}

final class RecordingThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    private let url: URL

    init(url: URL) {
        self.url = url
        loadThumbnail()
    }

    private func loadThumbnail() {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        DispatchQueue.global(qos: .userInitiated).async {
            let time = CMTime(seconds: 1.0, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let nsImage = NSImage(cgImage: cgImage, size: .zero)
                DispatchQueue.main.async {
                    self.image = nsImage
                }
            }
        }
    }
}

final class RecordingPreviewController: ObservableObject {
    let player: AVPlayer

    init(url: URL) {
        player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    func setPlaying(_ playing: Bool) {
        if playing {
            player.seek(to: .zero)
            player.play()
        } else {
            player.pause()
            player.seek(to: .zero)
        }
    }
}

struct RecordingPreviewPlayer: NSViewRepresentable {
    let player: AVPlayer
    let isPlaying: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.player = player
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        playerView.player = player
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: ()) {
        playerView.player?.pause()
        playerView.player = nil
    }
}
