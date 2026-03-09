import SwiftUI
import AppKit
import AVKit
import AVFoundation

struct RecordingEntry: Identifiable, Hashable {
    let url: URL
    let channelName: String
    let recordedAt: Date?
    let fileTimestamp: Date?
    let sourceType: RecordingCaptureType
    let sourceTarget: String?

    var id: URL { url }
}

private enum RecordingsLayoutMode: String, CaseIterable {
    case list
    case grid

    var iconName: String {
        switch self {
        case .list:
            return "list.bullet"
        case .grid:
            return "square.grid.2x2"
        }
    }
}

private enum RecordingsSortColumn: String, CaseIterable {
    case date
    case channel
    case filename

    var title: String {
        switch self {
        case .date:
            return "Date"
        case .channel:
            return "Channel"
        case .filename:
            return "Filename"
        }
    }
}

enum RecordingSort: String, CaseIterable {
    case dateDesc = "Newest"
    case dateAsc = "Oldest"
    case channelAsc = "Channel"
    case sizeDesc = "Largest"
}

private struct RecordingTechnicalMetadata: Equatable {
    var durationSeconds: Double?
    var fileSizeBytes: Int64
    var resolution: String?
    var codec: String?
}

private struct RecordingDuplicateGroup: Identifiable {
    let id: String
    let items: [RecordingEntry]
    let wastedBytes: Int64
}

private enum RecordingsQuickFilter: String, CaseIterable, Identifiable {
    case all
    case recent
    case today
    case downloads
    case protectedOnly
    case active

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .recent:
            return "Recent"
        case .today:
            return "Today"
        case .downloads:
            return "Downloads"
        case .protectedOnly:
            return "Protected"
        case .active:
            return "Active"
        }
    }
}

private enum DownloadQueueFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case failed
    case paused
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .active:
            return "In Progress"
        case .failed:
            return "Failed"
        case .paused:
            return "Paused"
        case .completed:
            return "Completed"
        }
    }
}

private enum RecordingsChrome {
    static let sidebarBackground = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let playerBackground = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let surface = Color.white.opacity(0.06)
    static let surfaceStrong = Color.white.opacity(0.1)
    static let surfaceHover = Color.white.opacity(0.14)
    static let border = Color.white.opacity(0.09)
    static let textPrimary = Color.white.opacity(0.86)
    static let textSecondary = Color.white.opacity(0.72)
    static let textMuted = Color.white.opacity(0.58)
    static let textSubtle = Color.white.opacity(0.46)
}

private struct RecordingsSurfaceCardModifier: ViewModifier {
    var fill: Color = RecordingsChrome.surface
    var stroke: Color = RecordingsChrome.border
    var strokeOpacity: Double = 1
    var cornerRadius: CGFloat = 9

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

private extension View {
    func recordingsSurfaceCard(
        fill: Color = RecordingsChrome.surface,
        stroke: Color = RecordingsChrome.border,
        strokeOpacity: Double = 1,
        cornerRadius: CGFloat = 9
    ) -> some View {
        modifier(
            RecordingsSurfaceCardModifier(
                fill: fill,
                stroke: stroke,
                strokeOpacity: strokeOpacity,
                cornerRadius: cornerRadius
            )
        )
    }
}

private struct RecordingsToolbarIconButtonStyle: ButtonStyle {
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 26, height: 26)
            .foregroundStyle(RecordingsChrome.textPrimary.opacity(highlighted ? 1 : 0.95))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        Color.white.opacity(
                            configuration.isPressed
                                ? 0.22
                                : (highlighted ? 0.16 : 0.08)
                        )
                    )
            )
    }
}

struct RecordingsLibraryView: View {
    @ObservedObject var recordingManager: RecordingManager
    var protectedChannelLogins: Set<String> = []
    var showProtectedRecordings = true
    @StateObject private var pipController = PictureInPictureController()
    @State private var recordings: [RecordingEntry] = []
    @State private var selectedRecording: RecordingEntry?
    @State private var selectedRecordingIDs: Set<URL> = []
    @AppStorage("recordingsLibraryLayoutMode") private var layoutModeRaw = RecordingsLayoutMode.list.rawValue
    @AppStorage("recordingsLibrarySortColumn") private var sortColumnRaw = RecordingsSortColumn.date.rawValue
    @AppStorage("recordingsLibrarySortAscending") private var sortAscending = false
    @AppStorage("recordingsLibraryGroupByStreamer") private var groupByStreamer = true
    @State private var isMultiSelectMode = false
    @State private var multiSelection: Set<URL> = []
    @State private var playbackURL: URL?
    @State private var isPreparingPlayback = false
    @State private var playbackError: String?
    @State private var thumbnailRefreshToken = UUID()
    @State private var isPlaying = true
    @AppStorage("player.volume") private var playerVolume = 0.9
    @AppStorage("player.muted") private var playerMuted = false
    @State private var playerFullscreenRequestToken = 0
    @State private var isHoveringVideoSurface = false
    @State private var showPlayerMorePopover = false
    @State private var videoZoom: CGFloat = 1.0
    @State private var videoPan: CGSize = .zero
    @AppStorage("motionSmoothening120Enabled") private var motionSmoothening120Enabled = false
    @AppStorage("motionSmoothening.showFPSOverlay") private var showFPSOverlay = true
    @AppStorage("video.show4KOverlay") private var show4KOverlay = true
    @AppStorage("video.upscaler4kEnabled") private var videoUpscaler4KEnabled = false
    @AppStorage("video.imageOptimizeEnabled") private var videoImageOptimizeEnabled = false
    @AppStorage("video.aspectCropMode") private var videoAspectModeRaw = VideoAspectCropMode.source.rawValue
    @AppStorage("video.imageOptimize.contrast") private var imageOptimizeContrast = ImageOptimizationConfiguration.productionDefault.contrast
    @AppStorage("video.imageOptimize.lighting") private var imageOptimizeLighting = ImageOptimizationConfiguration.productionDefault.lighting
    @AppStorage("video.imageOptimize.denoiser") private var imageOptimizeDenoiser = ImageOptimizationConfiguration.productionDefault.denoiser
    @AppStorage("video.imageOptimize.neuralClarity") private var imageOptimizeNeuralClarity = ImageOptimizationConfiguration.productionDefault.neuralClarity
    @State private var motionCapability = MotionSmootheningCapability.evaluate(screen: NSScreen.main)
    @State private var motionRuntimeStatus: MotionInterpolationRuntimeStatus?
    @State private var searchQuery = ""

    @State private var recordingPendingDeletion: RecordingEntry?
    @State private var showBulkDeletionConfirmation = false
    @State private var deletionError: String?
    @State private var isShowingDeletionError = false
    @State private var exportStatus: String?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var integrityReport: RecordingManager.LibraryIntegrityReport?
    @State private var isIntegrityScanning = false
    @State private var isIntegrityRepairing = false
    @State private var dismissedIntegrityBannerID: String?
    @State private var showDownloadOverlay = false
    @State private var quickFilter: RecordingsQuickFilter = .all
    @State private var queueFilter: DownloadQueueFilter = .all
    @State private var technicalMetadataByURL: [URL: RecordingTechnicalMetadata] = [:]
    @State private var metadataPrefetchInFlight: Set<URL> = []
    @State private var renderedRecordLimit = 300

    // Task 3: Resume playback position
    @State private var seekOnLoadSeconds: Double? = nil

    // Task 4: Clip export
    @State private var showClipExporter = false
    @State private var clipStartSeconds: Double = 0
    @State private var clipEndSeconds: Double = 30
    @State private var currentPlayerSeconds: Double = 0
    @State private var clipTotalDuration: Double = 300.0
    @State private var isPlaybackModalPresented = false

    // Feature 1: Speed controls
    @State private var playbackRate: Float = 1.0

    // Feature 2: Sort and filter
    @State private var filterText: String = ""
    @State private var sortOrder: RecordingSort = .dateDesc
    @State private var fileSizeCache: [URL: Int64] = [:]

    // Feature 3: Disk usage
    @State private var totalDiskUsageBytes: Int64 = 0
    @State private var playbackDurationSeconds: Double?

    @AppStorage("recordingDownloadAutoRetryEnabled") private var downloadAutoRetryEnabled = true
    @AppStorage("recordingDownloadAutoRetryLimit") private var downloadAutoRetryLimit = 2
    @AppStorage("recordingDownloadAutoRetryDelaySeconds") private var downloadAutoRetryDelaySeconds = 15

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let fileTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var videoAspectMode: VideoAspectCropMode {
        VideoAspectCropMode(rawValue: videoAspectModeRaw) ?? .source
    }

    private var isMotionSmootheningActive: Bool {
        motionSmoothening120Enabled && motionCapability.supported
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

    var body: some View {
        ZStack {
            recordingsWorkspaceView

            if isPlaybackModalPresented {
                playbackModalOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(2)
            }
        }
        .task {
            refreshRecordings()
            refreshMotionCapability()
            refreshDiskUsage()
            prefetchVisibleAssets()
            runIntegrityScan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingLibraryDidChange)) { _ in
            refreshRecordings()
            thumbnailRefreshToken = UUID()
            prefetchVisibleAssets()
            runIntegrityScan()
        }
        .onChange(of: protectedChannelLogins) { _ in
            refreshRecordings()
        }
        .onChange(of: showProtectedRecordings) { _ in
            refreshRecordings()
        }
        .onChange(of: searchQuery) { _ in
            resetRenderedRecordLimit()
            prefetchVisibleAssets()
        }
        .onChange(of: quickFilter) { _ in
            resetRenderedRecordLimit()
            prefetchVisibleAssets()
        }
        .onChange(of: sortOrder) { _ in
            resetRenderedRecordLimit()
            prefetchVisibleAssets()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshMotionCapability()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            refreshMotionCapability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .motionInterpolationRuntimeUpdated)) { notification in
            guard let status = notification.object as? MotionInterpolationRuntimeStatus else { return }
            motionRuntimeStatus = status
        }
        .onChange(of: motionSmoothening120Enabled) { enabled in
            if enabled {
                refreshMotionCapability()
                if !motionCapability.supported {
                    motionSmoothening120Enabled = false
                }
            }
        }
        .confirmationDialog(
            "Delete download?",
            isPresented: Binding(
                get: { recordingPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { recordingPendingDeletion = nil }
                }
            ),
            presenting: recordingPendingDeletion
        ) { recording in
            Button("Move to Trash", role: .destructive) {
                performDelete(recording)
            }
            Button("Cancel", role: .cancel) {
                recordingPendingDeletion = nil
            }
        } message: { recording in
            Text("This will move \(recording.url.lastPathComponent) to the Trash.")
        }
        .confirmationDialog(
            "Delete selected downloads?",
            isPresented: $showBulkDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                performBulkDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move \(selectedRecordingIDs.count) download(s) to the Trash.")
        }
        .alert(
            "Couldn't delete download",
            isPresented: $isShowingDeletionError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "Unknown error")
        }
        .sheet(isPresented: $showClipExporter) {
            clipExporterSheet
        }
        .onExitCommand {
            if isPlaybackModalPresented {
                closePlaybackModal()
            }
        }
        .animation(.easeOut(duration: 0.16), value: isPlaybackModalPresented)
    }

    // MARK: - Task 4: Clip exporter sheet

    private func mmss(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private var clipExporterSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Clip")
                .font(.system(size: 16, weight: .semibold))

            // Start slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Start")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(mmss(clipStartSeconds))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Slider(
                    value: $clipStartSeconds,
                    in: 0...max(clipEndSeconds, 0.1),
                    step: 0.5
                )
                .tint(.accentColor)
            }

            // Duration label
            let clipDuration = max(0, clipEndSeconds - clipStartSeconds)
            Text("Duration: \(mmss(clipDuration))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .center)

            // End slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("End")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(mmss(clipEndSeconds))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Slider(
                    value: $clipEndSeconds,
                    in: max(clipStartSeconds, 0)...max(clipTotalDuration, clipStartSeconds + 1),
                    step: 0.5
                )
                .tint(.accentColor)
            }

            // Read-only time display (secondary)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(mmss(clipStartSeconds))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("End")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(mmss(clipEndSeconds))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button("Export") {
                    showClipExporter = false
                    exportClip()
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    showClipExporter = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(width: 360)
        .task {
            // Feature 4: Load the actual asset duration when sheet opens.
            if let url = playbackURL {
                let asset = AVURLAsset(url: url)
                if let dur = try? await asset.load(.duration) {
                    let secs = dur.seconds
                    if secs.isFinite && secs > 0 {
                        clipTotalDuration = secs
                        // Clamp end to actual duration
                        if clipEndSeconds > secs {
                            clipEndSeconds = secs
                        }
                    }
                }
            }
        }
    }

    private func exportClip() {
        guard let sourceURL = playbackURL,
              let selected = selectedRecording else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Clip Here"

        guard panel.runModal() == .OK, let destinationDir = panel.url else { return }

        // Determine original filename from selected recording metadata when available.
        let displayFilename = recordingManager.displayFilename(for: selected.url)
        let stem = (displayFilename as NSString).deletingPathExtension
        let ext = (displayFilename as NSString).pathExtension.isEmpty ? sourceURL.pathExtension : (displayFilename as NSString).pathExtension
        let baseFilename = "\(stem)_clip.\(ext.isEmpty ? "mp4" : ext)"

        let outputURL = destinationDir.appendingPathComponent(baseFilename)
        let startSecs = clipStartSeconds
        let endSecs = clipEndSeconds
        let ffmpegPath = resolvedFFmpegPath()

        Task.detached(priority: .userInitiated) {
            do {
                guard let ffmpeg = ffmpegPath else {
                    throw NSError(domain: "ClipExport", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found. Install via Homebrew or set its path in Settings."])
                }

                let ffmpegInputURL = sourceURL

                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = [
                    "-y",
                    "-ss", "\(startSecs)",
                    "-to", "\(endSecs)",
                    "-i", ffmpegInputURL.path,
                    "-c", "copy",
                    outputURL.path
                ]
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    throw NSError(domain: "ClipExport", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with status \(process.terminationStatus)."])
                }
                await MainActor.run {
                    exportStatus = "Clip exported to \(outputURL.path)."
                }
            } catch {
                await MainActor.run {
                    exportStatus = "Clip export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private var recordingsWorkspaceView: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbarControls
            summaryStrip
            searchField
            quickFilterBar
            exportStatusView
            integrityStatusView
            recordingsListContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RecordingsChrome.sidebarBackground)
    }

    private var playbackModalOverlay: some View {
        GeometryReader { proxy in
            let width = min(max(proxy.size.width * 0.86, 760), 1340)
            let height = min(max(proxy.size.height * 0.84, 460), 920)

            ZStack {
                Color.black.opacity(0.48)
                    .onTapGesture {
                        closePlaybackModal()
                    }

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedRecording?.channelName ?? "Playback")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(RecordingsChrome.textPrimary)
                            if let selectedRecording {
                                Text(recordingManager.displayFilename(for: selectedRecording.url))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(RecordingsChrome.textMuted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            closePlaybackModal()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(RecordingsChrome.textPrimary)
                                .frame(width: 28, height: 28)
                                .recordingsSurfaceCard(fill: Color.white.opacity(0.1), strokeOpacity: 0, cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                        .help("Close player (Esc)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RecordingsChrome.surfaceStrong)

                    Divider()
                        .background(RecordingsChrome.border)

                    playerDetailView
                }
                .frame(width: width, height: height)
                .recordingsSurfaceCard(
                    fill: RecordingsChrome.playerBackground,
                    stroke: Color.white.opacity(0.14),
                    cornerRadius: 14
                )
                .shadow(color: Color.black.opacity(0.38), radius: 32, x: 0, y: 16)
            }
        }
    }

    private func toolbarIconLabel(_ systemName: String, highlighted: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(RecordingsChrome.textPrimary.opacity(highlighted ? 1 : 0.94))
            .frame(width: 26, height: 26)
            .recordingsSurfaceCard(
                fill: Color.white.opacity(highlighted ? 0.16 : 0.08),
                strokeOpacity: 0,
                cornerRadius: 6
            )
    }

    private func toolbarTextLabel(
        _ title: String,
        systemImage: String,
        highlighted: Bool = false
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(RecordingsChrome.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .recordingsSurfaceCard(
                fill: Color.white.opacity(highlighted ? 0.14 : 0.07),
                strokeOpacity: 0,
                cornerRadius: 7
            )
    }

    private var layoutToggleControl: some View {
        let current = layoutModeBinding.wrappedValue
        return HStack(spacing: 4) {
            Button {
                layoutModeBinding.wrappedValue = .list
            } label: {
                toolbarIconLabel("list.bullet", highlighted: current == .list)
            }
            .buttonStyle(.plain)
            .help("List layout")

            Button {
                layoutModeBinding.wrappedValue = .grid
            } label: {
                toolbarIconLabel("square.grid.2x2", highlighted: current == .grid)
            }
            .buttonStyle(.plain)
            .help("Grid layout")
        }
        .padding(2)
        .recordingsSurfaceCard(fill: Color.white.opacity(0.05), strokeOpacity: 0, cornerRadius: 8)
    }

    private var toolbarControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                toolbarTopRowWide
                toolbarTopRowCompact
            }

            ViewThatFits(in: .horizontal) {
                toolbarBottomRowWide
                toolbarBottomRowCompact
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var toolbarTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Downloads")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(RecordingsChrome.textPrimary)
            Text("\(sortedFilteredRecordings.count) visible")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(RecordingsChrome.textMuted)
        }
    }

    @ViewBuilder
    private var storageBadge: some View {
        if totalDiskUsageBytes > 0 {
            toolbarTextLabel(formattedDiskUsage, systemImage: "externaldrive")
        }
    }

    private var queueToolbarButton: some View {
        Button {
            showDownloadOverlay.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                toolbarIconLabel("arrow.down.circle", highlighted: showDownloadOverlay)
                if activeDownloadCount > 0 {
                    Text("\(activeDownloadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.95))
                        .clipShape(Capsule())
                        .offset(x: 8, y: -7)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Download queue")
        .popover(isPresented: $showDownloadOverlay, arrowEdge: .top) {
            downloadQueueOverlay
        }
    }

    private var refreshToolbarButton: some View {
        Button {
            refreshRecordings()
            refreshDiskUsage()
        } label: {
            toolbarIconLabel("arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help("Refresh downloads")
    }

    private var multiSelectToolbarButton: some View {
        Button {
            isMultiSelectMode.toggle()
            if !isMultiSelectMode {
                selectedRecordingIDs.removeAll()
                multiSelection.removeAll()
            }
        } label: {
            toolbarIconLabel(
                isMultiSelectMode ? "checklist.checked" : "checklist",
                highlighted: isMultiSelectMode
            )
        }
        .buttonStyle(.plain)
        .help(isMultiSelectMode ? "Disable multi-select" : "Enable multi-select")
    }

    private var manageToolbarMenu: some View {
        Menu {
            if isMultiSelectMode {
                Button("Select All Visible") {
                    selectedRecordingIDs = Set(sortedFilteredRecordings.map(\.id))
                    multiSelection = selectedRecordingIDs
                }
                Button("Clear Selection") {
                    selectedRecordingIDs.removeAll()
                    multiSelection.removeAll()
                }
                Divider()
                Button("Export Selected") {
                    exportSelectedRecordings()
                }
                .disabled(selectedRecordingIDs.isEmpty || isExporting)
                Button("Delete Selected", role: .destructive) {
                    showBulkDeletionConfirmation = true
                }
                .disabled(selectedRecordingIDs.isEmpty)
                Divider()
            }

            Toggle("Auto retry failures", isOn: $downloadAutoRetryEnabled)
            Stepper("Retry limit: \(downloadAutoRetryLimit)", value: $downloadAutoRetryLimit, in: 0...8)
            Stepper("Retry delay: \(downloadAutoRetryDelaySeconds)s", value: $downloadAutoRetryDelaySeconds, in: 3...300, step: 3)

            Divider()

            Button(isIntegrityScanning ? "Scanning Library..." : "Scan Library") {
                runIntegrityScan()
            }
            .disabled(isIntegrityScanning || isIntegrityRepairing)
            Button(isIntegrityRepairing ? "Repairing Issues..." : "Repair Issues") {
                repairLibraryIntegrity()
            }
            .disabled(isIntegrityRepairing || isIntegrityScanning || (integrityReport?.issueCount ?? 0) == 0)
        } label: {
            toolbarTextLabel("Manage", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
    }

    private var sortToolbarMenu: some View {
        Menu {
            ForEach(RecordingSort.allCases, id: \.self) { sort in
                Button {
                    sortOrder = sort
                } label: {
                    if sortOrder == sort {
                        Label(sort.rawValue, systemImage: "checkmark")
                    } else {
                        Text(sort.rawValue)
                    }
                }
            }
        } label: {
            toolbarTextLabel("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .help("Sort: \(sortOrder.rawValue)")
    }

    private var groupedToolbarButton: some View {
        Button {
            groupByStreamer.toggle()
        } label: {
            toolbarTextLabel(
                groupByStreamer ? "Grouped" : "Ungrouped",
                systemImage: groupByStreamer
                    ? "square.3.layers.3d.down.right.fill"
                    : "square.3.layers.3d.down.right",
                highlighted: groupByStreamer
            )
        }
        .buttonStyle(.plain)
        .help(groupByStreamer ? "Disable streamer grouping" : "Enable streamer grouping")
    }

    @ViewBuilder
    private var resetFiltersToolbarButton: some View {
        if hasActiveLibraryFilters {
            Button {
                resetLibraryFilters()
            } label: {
                toolbarTextLabel("Reset Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.plain)
            .help("Clear active search and filter criteria")
        }
    }

    @ViewBuilder
    private var selectedCountLabel: some View {
        if isMultiSelectMode {
            Text("\(selectedRecordingIDs.count) selected")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(RecordingsChrome.textMuted)
        }
    }

    private var toolbarTopRowWide: some View {
        HStack(spacing: 10) {
            toolbarTitle
            Spacer(minLength: 0)
            storageBadge
            queueToolbarButton
            refreshToolbarButton
            multiSelectToolbarButton
            manageToolbarMenu
        }
    }

    private var toolbarTopRowCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                toolbarTitle
                Spacer(minLength: 0)
                storageBadge
                manageToolbarMenu
            }
            HStack(spacing: 10) {
                queueToolbarButton
                refreshToolbarButton
                multiSelectToolbarButton
                Spacer(minLength: 0)
                selectedCountLabel
            }
        }
    }

    private var toolbarBottomRowWide: some View {
        HStack(spacing: 8) {
            layoutToggleControl
            sortToolbarMenu
            groupedToolbarButton
            resetFiltersToolbarButton
            Spacer(minLength: 0)
            selectedCountLabel
        }
    }

    private var toolbarBottomRowCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                layoutToggleControl
                sortToolbarMenu
                groupedToolbarButton
            }
            HStack(spacing: 8) {
                resetFiltersToolbarButton
                Spacer(minLength: 0)
                selectedCountLabel
            }
        }
    }

    private var activeDownloadCount: Int {
        recordingManager.downloadTasks.filter { task in
            task.state == .running || task.state == .queued
        }.count
    }

    private var downloadQueueOverlay: some View {
        let summary = downloadQueueSummary

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Download Queue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RecordingsChrome.textPrimary)
                Text("\(summary.total)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(RecordingsChrome.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                Spacer()
                Button("Close") {
                    showDownloadOverlay = false
                }
                .buttonStyle(.borderless)
                .foregroundStyle(RecordingsChrome.textSecondary)
            }

            Divider()

            if !recordingManager.downloadTasks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(DownloadQueueFilter.allCases) { filter in
                            Button {
                                queueFilter = filter
                            } label: {
                                filterChip(
                                    title: filter.title,
                                    count: queueFilterCount(for: filter),
                                    isSelected: queueFilter == filter
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text(queueFilterText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RecordingsChrome.textMuted)

                HStack(spacing: 8) {
                    queueActionButton("Pause Active", enabled: canPauseActiveDownloads) {
                        recordingManager.pauseAllDownloadTasks()
                    }

                    queueActionButton("Resume Paused", enabled: canResumePausedDownloads, emphasized: true) {
                        resumePausedDownloads()
                    }

                    queueActionButton("Retry Failed", enabled: canRetryFailedDownloads) {
                        retryAllFailedDownloads()
                    }

                    queueActionButton("Clear Completed", enabled: canClearFinishedDownloads) {
                        clearFinishedDownloads()
                    }

                    queueActionButton("Cancel Active", enabled: canCancelActiveDownloads) {
                        cancelAllActiveDownloads()
                    }
                }
            }

            if filteredDownloadTasks.isEmpty {
                Text(queueEmptyStateMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RecordingsChrome.textMuted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredDownloadTasks) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(task.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(RecordingsChrome.textPrimary)
                                            .lineLimit(2)

                                        Text(task.captureType.listLabel)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(RecordingsChrome.textMuted)
                                    }

                                    Spacer(minLength: 0)

                                    downloadStateBadge(task.state)
                                }

                                if let fraction = task.progressFraction {
                                    ProgressView(value: fraction, total: 1.0)
                                        .controlSize(.small)
                                } else if task.state == .running {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                HStack(spacing: 8) {
                                    Text(formattedTransferBytes(task.bytesWritten))
                                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                                        .foregroundStyle(RecordingsChrome.textMuted)
                                    if let startedAt = task.startedAt {
                                        Text("• \(fileTimeFormatter.string(from: startedAt))")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(RecordingsChrome.textMuted)
                                    }
                                    Text("• \(relativeTimestamp(for: task.updatedAt))")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(RecordingsChrome.textMuted)
                                    if task.retryCount > 0 {
                                        Text("• retry \(task.retryCount)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(RecordingsChrome.textMuted)
                                    }
                                    Spacer()
                                }

                                if let status = task.statusMessage, !status.isEmpty {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: task.state == .failed ? "exclamationmark.triangle.fill" : "info.circle")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(task.state == .failed ? .orange.opacity(0.95) : RecordingsChrome.textSubtle)
                                            .padding(.top, 1)
                                        Text(status)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(RecordingsChrome.textMuted)
                                            .lineLimit(4)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 7)
                                    .recordingsSurfaceCard(
                                        fill: task.state == .failed ? Color.orange.opacity(0.12) : Color.white.opacity(0.05),
                                        strokeOpacity: 0,
                                        cornerRadius: 7
                                    )
                                }

                                queueTaskActions(for: task)

                                if let diagnostic = downloadDiagnostic(for: task) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(diagnostic.summary)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.orange.opacity(0.9))
                                        Text(diagnostic.suggestion)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(RecordingsChrome.textMuted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.top, 3)
                                }
                            }
                            .padding(12)
                            .recordingsSurfaceCard(
                                fill: Color.white.opacity(0.05),
                                strokeOpacity: 0.7,
                                cornerRadius: 8
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(12)
        .frame(minWidth: 340, idealWidth: 420)
        .recordingsSurfaceCard(fill: RecordingsChrome.sidebarBackground, strokeOpacity: 0.8, cornerRadius: 12)
    }

    private func downloadStateBadge(_ state: RecordingManager.DownloadTaskState) -> some View {
        Text(downloadStateLabel(state))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(downloadStateColor(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(downloadStateColor(state).opacity(0.14))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func queueTaskPrimaryActions(for task: RecordingManager.DownloadTask) -> some View {
        if task.state == .running || task.state == .queued {
            queueActionButton("Pause", enabled: true) {
                _ = recordingManager.pauseDownloadTask(id: task.id)
            }
            queueActionButton("Cancel", enabled: true) {
                _ = recordingManager.cancelDownloadTask(id: task.id)
            }
        } else if task.state == .paused || task.canResume {
            queueActionButton("Resume", enabled: true, emphasized: true) {
                _ = recordingManager.resumeDownloadTask(id: task.id)
            }
        }
    }

    @ViewBuilder
    private func queueTaskActions(for task: RecordingManager.DownloadTask) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                queueTaskPrimaryActions(for: task)
                Spacer(minLength: 0)
                queueActionButton("Remove", enabled: true) {
                    _ = recordingManager.removeDownloadTask(id: task.id)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    queueTaskPrimaryActions(for: task)
                }
                queueActionButton("Remove", enabled: true) {
                    _ = recordingManager.removeDownloadTask(id: task.id)
                }
            }
        }
    }

    private func formattedTransferBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func downloadStateLabel(_ state: RecordingManager.DownloadTaskState) -> String {
        switch state {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .paused:
            return "Paused"
        case .canceled:
            return "Canceled"
        }
    }

    private func downloadStateColor(_ state: RecordingManager.DownloadTaskState) -> Color {
        switch state {
        case .queued:
            return .orange.opacity(0.9)
        case .running:
            return .blue.opacity(0.9)
        case .completed:
            return .green.opacity(0.9)
        case .failed:
            return .red.opacity(0.9)
        case .paused:
            return .yellow.opacity(0.9)
        case .canceled:
            return .secondary
        }
    }

    private var summaryStrip: some View {
        let visibleCount = sortedFilteredRecordings.count
        let totalCount = recordings.count
        let todayCount = recordings.filter(isRecordingCapturedToday).count
        let queueSummary = downloadQueueSummary

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 148), spacing: 8, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            summaryTile(
                title: "Visible",
                value: totalCount == 0 ? "0" : "\(visibleCount)/\(totalCount)",
                tint: .white.opacity(0.85)
            )
            summaryTile(
                title: "Storage",
                value: totalDiskUsageBytes > 0 ? formattedDiskUsage : "0 KB",
                tint: .white.opacity(0.85)
            )
            summaryTile(
                title: "Queue",
                value: "\(queueSummary.active) active",
                subtitle: "\(queueSummary.failed) failed • \(queueSummary.paused) paused",
                tint: queueSummary.failed > 0 ? .red.opacity(0.9) : .white.opacity(0.85)
            )
            summaryTile(
                title: "Today",
                value: "\(todayCount)",
                tint: .white.opacity(0.85)
            )
        }
        .padding(.horizontal, 16)
    }

    private func summaryTile(
        title: String,
        value: String,
        subtitle: String? = nil,
        tint: Color = .white.opacity(0.85)
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(RecordingsChrome.textSubtle)
                .tracking(0.9)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(RecordingsChrome.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .recordingsSurfaceCard(cornerRadius: 8)
    }

    private func filterChip(
        title: String,
        count: Int,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(isSelected ? 0.26 : 0.12))
                .clipShape(Capsule())
        }
        .foregroundStyle(isSelected ? .white : RecordingsChrome.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .recordingsSurfaceCard(
            fill: Color.white.opacity(isSelected ? 0.16 : 0.06),
            strokeOpacity: 0,
            cornerRadius: 7
        )
    }

    @ViewBuilder
    private func queueActionButton(
        _ title: String,
        enabled: Bool,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(enabled ? RecordingsChrome.textPrimary : .white.opacity(0.35))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .recordingsSurfaceCard(
                fill: Color.white.opacity(enabled ? (emphasized ? 0.18 : 0.09) : 0.04),
                strokeOpacity: 0,
                cornerRadius: 7
            )
            .disabled(!enabled)
    }

    private var quickFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(RecordingsQuickFilter.allCases) { filter in
                    Button {
                        quickFilter = filter
                    } label: {
                        filterChip(
                            title: filter.title,
                            count: quickFilterCount(for: filter),
                            isSelected: quickFilter == filter
                        )
                    }
                    .buttonStyle(.plain)
                }

                if hasActiveLibraryFilters {
                    Button("Reset") {
                        resetLibraryFilters()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(RecordingsChrome.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .recordingsSurfaceCard(fill: Color.white.opacity(0.07), strokeOpacity: 0, cornerRadius: 7)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RecordingsChrome.textMuted)
            TextField("Search downloads", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(RecordingsChrome.textPrimary)

            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    searchQuery = ""
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RecordingsChrome.textSubtle)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            if !recordings.isEmpty {
                Text("\(sortedFilteredRecordings.count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(RecordingsChrome.textSubtle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .recordingsSurfaceCard(cornerRadius: 8)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var exportStatusView: some View {
        if isExporting {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: exportProgress, total: 1.0)
                    .tint(.white.opacity(0.8))
                Text("Exporting downloads…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RecordingsChrome.textMuted)
            }
            .padding(.horizontal, 16)
        } else if let exportStatus {
            Text(exportStatus)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(RecordingsChrome.textMuted)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var integrityStatusView: some View {
        if let report = integrityReport, report.issueCount > 0 {
            let bannerID = [
                report.orphanedManifestEntries.count,
                report.missingThumbnailEntries.count,
                report.orphanedThumbnailEntries.count,
                report.unreadableFiles.count
            ].map(String.init).joined(separator: ":")

            if dismissedIntegrityBannerID != bannerID {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.92))
                        Text("Library Integrity: \(report.issueCount) issue(s)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(RecordingsChrome.textPrimary)
                        Spacer(minLength: 0)
                        if isIntegrityScanning || isIntegrityRepairing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            dismissedIntegrityBannerID = bannerID
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(RecordingsChrome.textSecondary)
                                .frame(width: 22, height: 22)
                                .recordingsSurfaceCard(fill: Color.white.opacity(0.08), strokeOpacity: 0, cornerRadius: 6)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }

                    HStack(spacing: 10) {
                        Text("Manifest \(report.orphanedManifestEntries.count)")
                        Text("Thumbs \(report.missingThumbnailEntries.count + report.orphanedThumbnailEntries.count) (non-blocking)")
                        Text("Unreadable \(report.unreadableFiles.count)")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RecordingsChrome.textMuted)

                    HStack(spacing: 8) {
                        queueActionButton("Scan", enabled: !(isIntegrityScanning || isIntegrityRepairing)) {
                            runIntegrityScan()
                        }
                        queueActionButton("Repair", enabled: !(isIntegrityRepairing || isIntegrityScanning), emphasized: true) {
                            repairLibraryIntegrity()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .recordingsSurfaceCard(fill: Color.orange.opacity(0.12), stroke: Color.orange.opacity(0.35), cornerRadius: 10)
                .padding(.horizontal, 16)
            }
        }
    }

    private var recordingsListContainer: some View {
        ScrollView {
            if recordings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(RecordingsChrome.textMuted)
                    Text("No downloads yet.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RecordingsChrome.textPrimary)
                    Text("Start a stream or clip download and it will appear here.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RecordingsChrome.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    queueActionButton("Refresh", enabled: true) {
                        refreshRecordings()
                        refreshDiskUsage()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .recordingsSurfaceCard(fill: Color.white.opacity(0.04), strokeOpacity: 0.7, cornerRadius: 10)
                .padding(.horizontal, 16)
            } else if sortedFilteredRecordings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(RecordingsChrome.textMuted)
                    Text("No downloads match your current filters.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RecordingsChrome.textPrimary)
                    Text("Try another search or reset filters.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RecordingsChrome.textMuted)
                    if hasActiveLibraryFilters {
                        queueActionButton("Reset Filters", enabled: true) {
                            resetLibraryFilters()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .recordingsSurfaceCard(fill: Color.white.opacity(0.04), strokeOpacity: 0.7, cornerRadius: 10)
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 10) {
                    recordingsCollectionView
                    if hasMoreRecordingsToRender {
                        queueActionButton(
                            "Load \(min(300, sortedFilteredRecordings.count - displayedSortedRecordings.count)) more",
                            enabled: true
                        ) {
                            renderedRecordLimit += 300
                            prefetchVisibleAssets()
                        }
                        .padding(.bottom, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
            }
        }
    }

    private var playerDetailView: some View {
        VStack(spacing: 0) {
            if selectedRecording != nil {
                if let playbackURL {
                    ZStack(alignment: .bottom) {
                        NativeVideoPlayer(
                            url: playbackURL,
                            isPlaying: $isPlaying,
                            volume: $playerVolume,
                            muted: $playerMuted,
                            fullscreenRequestToken: $playerFullscreenRequestToken,
                            pipController: pipController,
                            zoom: $videoZoom,
                            pan: $videoPan,
                            motionSmootheningEnabled: isMotionSmootheningActive,
                            motionCapability: motionCapability,
                            motionConfiguration: .productionDefault,
                            videoAspectMode: effectiveVideoAspectMode,
                            upscaler4KEnabled: isUpscaler4KActive,
                            imageOptimizeEnabled: isImageOptimizeActive,
                            imageOptimizationConfiguration: imageOptimizationConfiguration,
                            seekOnLoadSeconds: seekOnLoadSeconds,
                            playbackRate: playbackRate,
                            onPlaybackTimeUpdate: { seconds in
                                currentPlayerSeconds = seconds
                                if let recordingURL = selectedRecording?.url {
                                    let duration = playbackDurationSeconds ?? 0
                                    if duration.isFinite && duration > 0 && (duration - seconds) < 10 {
                                        clearPlaybackPosition(for: recordingURL)
                                    } else {
                                        savePlaybackPosition(seconds, for: recordingURL)
                                    }
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if (isMotionSmootheningActive && showFPSOverlay) || (isUpscaler4KActive && show4KOverlay) {
                            VStack {
                                HStack(spacing: 8) {
                                    if isMotionSmootheningActive && showFPSOverlay, let status = motionRuntimeStatus {
                                        recordingMotionFPSBadge(status)
                                    }
                                    if isUpscaler4KActive && show4KOverlay {
                                        recordingUpscaler4KBadge
                                    }
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(10)
                            .allowsHitTesting(false)
                        }

                        recordingPlayerControlsToolbar
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.trailing, 12)
                            .padding(.top, 10)
                            .opacity(isHoveringVideoSurface ? 1 : 0)
                            .allowsHitTesting(isHoveringVideoSurface)
                            .animation(.easeOut(duration: 0.18), value: isHoveringVideoSurface)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHoveringVideoSurface = hovering
                    }
                } else if isPreparingPlayback {
                    VStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.9)
                            .tint(.white.opacity(0.7))
                        Text("Preparing download…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RecordingsChrome.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RecordingsChrome.playerBackground)
                } else if let playbackError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color.orange.opacity(0.9))
                        Text("Unable to play this download")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RecordingsChrome.textPrimary)
                        Text(playbackError)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(RecordingsChrome.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RecordingsChrome.playerBackground)
                } else {
                    emptyPlayerStateView
                }
            } else {
                emptyPlayerStateView
            }
        }
        .background(RecordingsChrome.playerBackground)
    }

    @ViewBuilder
    private func speedButton(rate: Float, label: String) -> some View {
        Button {
            playbackRate = rate
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(playbackRate == rate ? Color.accentColor : RecordingsChrome.textSecondary)
                .padding(.horizontal, 5)
                .frame(height: 22)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(playbackRate == rate ? Color.white.opacity(0.15) : Color.clear)
        )
        .help("\(label) speed")
    }

    private var recordingPlayerControlsToolbar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                // Speed controls (Feature 1)
                HStack(spacing: 2) {
                    speedButton(rate: 0.5, label: "0.5x")
                    speedButton(rate: 1.0, label: "1x")
                    speedButton(rate: 1.5, label: "1.5x")
                    speedButton(rate: 2.0, label: "2x")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(RecordingsChrome.surface)
                )
                if pipController.isAvailable {
                    Button(action: { pipController.toggle() }) {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(RecordingsToolbarIconButtonStyle())
                    .help("Picture in Picture")
                }

                Button(action: requestPlayerFullscreenToggle) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(RecordingsToolbarIconButtonStyle())
                .help("Player fullscreen")

                Button {
                    let t = currentPlayerSeconds
                    clipStartSeconds = max(0, t - 30)
                    clipEndSeconds = t + 30
                    showClipExporter = true
                } label: {
                    Label("Clip", systemImage: "scissors")
                        .font(.system(size: 11, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(playbackURL == nil ? .white.opacity(0.35) : RecordingsChrome.textPrimary)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .disabled(playbackURL == nil)
                .recordingsSurfaceCard(
                    fill: Color.white.opacity(playbackURL == nil ? 0.04 : 0.08),
                    strokeOpacity: 0,
                    cornerRadius: 6
                )
                .help("Export Clip")

                Button(action: { showPlayerMorePopover.toggle() }) {
                    Label("More", systemImage: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(RecordingsChrome.textPrimary)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .recordingsSurfaceCard(
                    fill: Color.white.opacity(showPlayerMorePopover ? 0.16 : 0.08),
                    strokeOpacity: 0,
                    cornerRadius: 6
                )
                .help("More controls")
                .popover(isPresented: $showPlayerMorePopover, arrowEdge: .bottom) {
                    recordingPlayerMorePopover
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(RecordingsChrome.surfaceStrong)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
    }

    private var recordingPlayerMorePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More Controls")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Zoom")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    RecordingOverlayValueSlider(
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
                    Button("Reset") {
                        videoZoom = 1.0
                        videoPan = .zero
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text("AirPlay")
                    .font(.system(size: 11, weight: .medium))
                RecordingAirPlayRoutePicker()
                    .frame(width: 24, height: 24)
            }

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

                if !motionCapability.supported {
                    Text(motionCapability.reason)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func requestPlayerFullscreenToggle() {
        playerFullscreenRequestToken &+= 1
    }

    private func refreshMotionCapability() {
        let next = MotionSmootheningCapability.evaluate(screen: NSScreen.main)
        motionCapability = next
        if !next.supported {
            motionSmoothening120Enabled = false
        }
    }


    @ViewBuilder
    private func recordingMotionFPSBadge(_ status: MotionInterpolationRuntimeStatus) -> some View {
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

    private var recordingUpscaler4KBadge: some View {
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

    private var recordingImageOptimizeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.green.opacity(0.95))
            Text("Image Optimize")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.green.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private var emptyPlayerStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Select a download to play")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RecordingsChrome.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RecordingsChrome.playerBackground)
    }

    private var layoutModeBinding: Binding<RecordingsLayoutMode> {
        Binding(
            get: {
                RecordingsLayoutMode(rawValue: layoutModeRaw) ?? .list
            },
            set: { newMode in
                layoutModeRaw = newMode.rawValue
            }
        )
    }

    private var sortColumn: RecordingsSortColumn {
        get {
            RecordingsSortColumn(rawValue: sortColumnRaw) ?? .date
        }
        nonmutating set {
            sortColumnRaw = newValue.rawValue
        }
    }

    @ViewBuilder
    private var recordingsCollectionView: some View {
        switch layoutModeBinding.wrappedValue {
        case .list:
            listCollectionView
        case .grid:
            gridCollectionView
        }
    }

    private var listCollectionView: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(groupedRecordings, id: \.channel) { group in
                VStack(alignment: .leading, spacing: 10) {
                    if groupByStreamer {
                        Text(group.channel.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .tracking(1.2)
                            .padding(.horizontal, 16)
                    }

                    ForEach(group.items) { recording in
                        let isDeleteDisabled = recordingManager.isRecording(outputURL: recording.url)

                        RecordingRow(
                            recording: recording,
                            formattedDate: formattedDate(for: recording),
                            formattedFileTime: formattedFileTime(for: recording),
                            sourceLabel: recording.sourceType.listLabel,
                            sourceBadge: recordingSourceBadge(for: recording),
                            displayFilename: recordingManager.displayFilename(for: recording.url),
                            technicalSummary: technicalSummaryText(for: recording),
                            isSelected: recording == selectedRecording,
                            isMultiSelectMode: isMultiSelectMode,
                            isChecked: selectedRecordingIDs.contains(recording.id),
                            thumbnailRefreshToken: thumbnailRefreshToken,
                            isDeleteDisabled: isDeleteDisabled,
                            recordingManager: recordingManager,
                            onSelect: {
                                if isMultiSelectMode {
                                    toggleSelection(for: recording)
                                } else {
                                    selectedRecording = recording
                                }
                            },
                            onOpen: {
                                guard !isMultiSelectMode else { return }
                                openPlaybackModal(for: recording)
                            },
                            onReveal: {
                                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                            },
                            onToggleSelection: {
                                toggleSelection(for: recording)
                            },
                            onDelete: {
                                recordingPendingDeletion = recording
                            }
                        )
                        .contextMenu {
                            recordingContextMenu(for: recording)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gridCollectionView: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(groupedRecordings, id: \.channel) { group in
                VStack(alignment: .leading, spacing: 10) {
                    if groupByStreamer {
                        Text(group.channel.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .tracking(1.2)
                            .padding(.horizontal, 16)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                        ForEach(group.items) { recording in
                            let isDeleteDisabled = recordingManager.isRecording(outputURL: recording.url)

                            RecordingGridCard(
                                recording: recording,
                                formattedDate: formattedDate(for: recording),
                                formattedFileTime: formattedFileTime(for: recording),
                                sourceLabel: recording.sourceType.listLabel,
                                sourceBadge: recordingSourceBadge(for: recording),
                                displayFilename: recordingManager.displayFilename(for: recording.url),
                                technicalSummary: technicalSummaryText(for: recording),
                                isSelected: recording == selectedRecording,
                                isMultiSelectMode: isMultiSelectMode,
                                isChecked: selectedRecordingIDs.contains(recording.id),
                                thumbnailRefreshToken: thumbnailRefreshToken,
                                isDeleteDisabled: isDeleteDisabled,
                                recordingManager: recordingManager,
                                onSelect: {
                                    if isMultiSelectMode {
                                        toggleSelection(for: recording)
                                    } else {
                                        selectedRecording = recording
                                    }
                                },
                                onOpen: {
                                    guard !isMultiSelectMode else { return }
                                    openPlaybackModal(for: recording)
                                },
                                onReveal: {
                                    NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                                },
                                onToggleSelection: {
                                    toggleSelection(for: recording)
                                },
                                onDelete: {
                                    recordingPendingDeletion = recording
                                }
                            )
                            .contextMenu {
                                recordingContextMenu(for: recording)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filteredRecordings: [RecordingEntry] {
        // Combine searchQuery (existing) and filterText (Feature 2) — both drive the same filter.
        let combinedQuery: String = {
            let sq = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ft = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return sq.isEmpty ? ft : sq
        }()
        let searchFiltered: [RecordingEntry]
        if combinedQuery.isEmpty {
            searchFiltered = recordings
        } else {
            searchFiltered = recordings.filter { recording in
                recording.channelName.lowercased().contains(combinedQuery)
                    || recording.url.lastPathComponent.lowercased().contains(combinedQuery)
                    || recording.sourceType.listLabel.lowercased().contains(combinedQuery)
            }
        }

        guard quickFilter != .all else { return searchFiltered }
        return searchFiltered.filter { recording in
            matchesQuickFilter(recording, filter: quickFilter)
        }
    }

    private var hasActiveLibraryFilters: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || quickFilter != .all
    }

    private func resetLibraryFilters() {
        searchQuery = ""
        filterText = ""
        quickFilter = .all
    }

    private func matchesQuickFilter(_ recording: RecordingEntry, filter: RecordingsQuickFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .recent:
            guard let date = captureDate(for: recording) else { return false }
            return date >= Date().addingTimeInterval(-7 * 86_400)
        case .today:
            return isRecordingCapturedToday(recording)
        case .downloads:
            return recording.sourceType.isDownload
        case .protectedOnly:
            return isProtectedRecording(recording)
        case .active:
            return recordingManager.isRecording(outputURL: recording.url)
        }
    }

    private func quickFilterCount(for filter: RecordingsQuickFilter) -> Int {
        recordings.filter { matchesQuickFilter($0, filter: filter) }.count
    }

    private func isProtectedRecording(_ recording: RecordingEntry) -> Bool {
        recording.url.pathExtension.lowercased() == "glitcho"
    }

    private func isRecordingCapturedToday(_ recording: RecordingEntry) -> Bool {
        guard let date = captureDate(for: recording) else { return false }
        return Calendar.current.isDateInToday(date)
    }

    private var downloadQueueSummary: (active: Int, failed: Int, paused: Int, completed: Int, total: Int) {
        var active = 0
        var failed = 0
        var paused = 0
        var completed = 0

        for task in recordingManager.downloadTasks {
            switch task.state {
            case .queued, .running:
                active += 1
            case .failed:
                failed += 1
            case .paused:
                paused += 1
            case .completed:
                completed += 1
            case .canceled:
                break
            }
        }

        return (
            active: active,
            failed: failed,
            paused: paused,
            completed: completed,
            total: recordingManager.downloadTasks.count
        )
    }

    private var filteredDownloadTasks: [RecordingManager.DownloadTask] {
        recordingManager.downloadTasks.filter { task in
            switch queueFilter {
            case .all:
                return true
            case .active:
                return task.state == .running || task.state == .queued
            case .failed:
                return task.state == .failed
            case .paused:
                return task.state == .paused
            case .completed:
                return task.state == .completed || task.state == .canceled
            }
        }
    }

    private func queueFilterCount(for filter: DownloadQueueFilter) -> Int {
        recordingManager.downloadTasks.filter { task in
            switch filter {
            case .all:
                return true
            case .active:
                return task.state == .running || task.state == .queued
            case .failed:
                return task.state == .failed
            case .paused:
                return task.state == .paused
            case .completed:
                return task.state == .completed || task.state == .canceled
            }
        }.count
    }

    private func relativeTimestamp(for date: Date) -> String {
        relativeTimeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func cancelAllActiveDownloads() {
        _ = recordingManager.cancelActiveDownloadTasks()
    }

    private func retryAllFailedDownloads() {
        _ = recordingManager.retryFailedDownloadTasks()
    }

    private func resumePausedDownloads() {
        let pausedIDs = recordingManager.downloadTasks
            .filter { $0.state == .paused }
            .map(\.id)
        for id in pausedIDs {
            _ = recordingManager.resumeDownloadTask(id: id)
        }
    }

    private func clearFinishedDownloads() {
        _ = recordingManager.clearCompletedDownloadTasks()
    }

    private var canClearFinishedDownloads: Bool {
        recordingManager.downloadTasks.contains {
            $0.state == .completed || $0.state == .canceled
        }
    }

    private var canRetryFailedDownloads: Bool {
        recordingManager.downloadTasks.contains { $0.state == .failed }
    }

    private var canPauseActiveDownloads: Bool {
        recordingManager.downloadTasks.contains {
            $0.state == .running || $0.state == .queued
        }
    }

    private var canResumePausedDownloads: Bool {
        recordingManager.downloadTasks.contains { $0.state == .paused }
    }

    private var canCancelActiveDownloads: Bool {
        recordingManager.downloadTasks.contains {
            $0.state == .running || $0.state == .queued
        }
    }

    private func downloadDiagnostic(for task: RecordingManager.DownloadTask) -> (summary: String, suggestion: String)? {
        guard task.state == .failed else { return nil }
        let raw = (task.lastErrorMessage ?? task.statusMessage ?? "Unknown failure")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        if lower.contains("forbidden")
            || lower.contains("401")
            || lower.contains("403")
            || lower.contains("login required")
            || lower.contains("authentication") {
            return ("Authentication issue", "Sign in on Twitch in Glitcho, then retry the download.")
        }
        if lower.contains("offline")
            || lower.contains("not found")
            || lower.contains("no playable streams")
            || lower.contains("unavailable") {
            return ("Source unavailable", "The stream/VOD/clip is unavailable now. Retry later or verify the URL.")
        }
        if lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("network")
            || lower.contains("connection")
            || lower.contains("dns")
            || lower.contains("resolve") {
            return ("Network issue", "Check connectivity/VPN/firewall and retry.")
        }
        if lower.contains("permission")
            || lower.contains("operation not permitted")
            || lower.contains("read-only") {
            return ("Write permission issue", "Pick a writable recordings folder in Settings and retry.")
        }
        if lower.contains("streamlink") {
            return ("Streamlink issue", "Update/reinstall Streamlink from Settings, then retry.")
        }
        if lower.contains("ffmpeg") {
            return ("FFmpeg issue", "Install/repair FFmpeg path in Settings, then retry.")
        }

        return ("Download failed", raw)
    }

    private var queueEmptyStateMessage: String {
        switch queueFilter {
        case .all:
            return "No download activity yet."
        case .active:
            return "No active downloads."
        case .failed:
            return "No failed downloads."
        case .paused:
            return "No paused downloads."
        case .completed:
            return "No completed downloads."
        }
    }

    private var queueFilterText: String {
        switch queueFilter {
        case .all:
            return "Showing all tasks"
        case .active:
            return "Showing in-progress tasks"
        case .failed:
            return "Showing failed tasks"
        case .paused:
            return "Showing paused tasks"
        case .completed:
            return "Showing completed and canceled tasks"
        }
    }

    private func resetRenderedRecordLimit() {
        renderedRecordLimit = 300
    }

    private func prefetchVisibleAssets() {
        let sample = Array(sortedFilteredRecordings.prefix(max(renderedRecordLimit + 120, 240)))
        guard !sample.isEmpty else { return }
        prefetchTechnicalMetadata(for: sample)
        RecordingThumbnailLoader.prefetchThumbnails(for: sample.map(\.url), recordingManager: recordingManager)
    }

    private func prefetchTechnicalMetadata(for entries: [RecordingEntry]) {
        let urls = entries.map(\.url).filter { url in
            technicalMetadataByURL[url] == nil && !metadataPrefetchInFlight.contains(url)
        }
        guard !urls.isEmpty else { return }
        urls.forEach { metadataPrefetchInFlight.insert($0) }

        Task.detached(priority: .utility) {
            var loaded: [(URL, RecordingTechnicalMetadata)] = []
            loaded.reserveCapacity(urls.count)
            for url in urls {
                let metadata = await Self.probeTechnicalMetadata(for: url)
                loaded.append((url, metadata))
            }
            let loadedResults = loaded

            await MainActor.run {
                for (url, metadata) in loadedResults {
                    technicalMetadataByURL[url] = metadata
                    fileSizeCache[url] = metadata.fileSizeBytes
                    metadataPrefetchInFlight.remove(url)
                }
            }
        }
    }

    private static func probeTechnicalMetadata(for url: URL) async -> RecordingTechnicalMetadata {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSizeBytes = (attrs?[.size] as? Int64) ?? 0

        guard url.pathExtension.lowercased() != "glitcho" else {
            return RecordingTechnicalMetadata(
                durationSeconds: nil,
                fileSizeBytes: fileSizeBytes,
                resolution: nil,
                codec: "Protected"
            )
        }

        let asset = AVURLAsset(url: url)
        let durationSeconds: Double?
        if let duration = try? await asset.load(.duration).seconds,
           duration.isFinite,
           duration > 0 {
            durationSeconds = duration
        } else {
            durationSeconds = nil
        }

        var resolution: String?
        var codec: String?

        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let videoTrack = tracks.first {
            if let naturalSize = try? await videoTrack.load(.naturalSize) {
                let width = Int(abs(naturalSize.width).rounded())
                let height = Int(abs(naturalSize.height).rounded())
                if width > 0, height > 0 {
                    resolution = "\(width)x\(height)"
                }
            }
            if let formatDescription = (try? await videoTrack.load(.formatDescriptions))?.first {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
                codec = fourCCString(mediaSubType)
            }
        }

        return RecordingTechnicalMetadata(
            durationSeconds: durationSeconds,
            fileSizeBytes: fileSizeBytes,
            resolution: resolution,
            codec: codec
        )
    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
        }
        return "\(value)"
    }

    private func technicalSummaryText(for recording: RecordingEntry) -> String? {
        let metadata = technicalMetadataByURL[recording.url]
        let fileBytes = metadata?.fileSizeBytes ?? fileSize(for: recording)
        var parts: [String] = [formattedTransferBytes(fileBytes)]

        if let duration = metadata?.durationSeconds {
            parts.insert(formattedDuration(duration), at: 0)
        }
        if let resolution = metadata?.resolution, !resolution.isEmpty {
            parts.append(resolution)
        }
        if let codec = metadata?.codec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func recordingSourceBadge(for recording: RecordingEntry) -> String {
        switch recording.sourceType {
        case .liveRecording:
            return "REC"
        case .streamDownload:
            return "VOD"
        case .clipDownload:
            return "CLIP"
        }
    }

    @ViewBuilder
    private func recordingContextMenu(for recording: RecordingEntry) -> some View {
        let isActive = recordingManager.isRecording(outputURL: recording.url)

        Button("Play") {
            openPlaybackModal(for: recording)
        }
        .disabled(isActive)

        Divider()

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([recording.url])
        }
        Button("Copy Path") {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(recording.url.path, forType: .string)
        }
        Button("Rename…") {
            promptRename(recording: recording)
        }
        .disabled(isActive)

        Button("Re-download") {
            let started = recordingManager.redownloadRecording(recording)
            if started {
                exportStatus = "Started re-download for \(recording.channelName)."
            } else {
                deletionError = recordingManager.errorMessage ?? "Could not re-download this item."
                isShowingDeletionError = true
            }
        }
        .disabled(!canRedownload(recording))

        Divider()

        Button("Delete", role: .destructive) {
            recordingPendingDeletion = recording
        }
        .disabled(isActive)
    }

    private func promptRename(recording: RecordingEntry) {
        let alert = NSAlert()
        alert.messageText = "Rename Recording"
        alert.informativeText = "Choose a new display name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let displayName = recordingManager.displayFilename(for: recording.url)
        let stem = (displayName as NSString).deletingPathExtension
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = stem
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try recordingManager.renameRecording(at: recording.url, to: input.stringValue)
            refreshRecordings()
            thumbnailRefreshToken = UUID()
            exportStatus = "Renamed \(displayName)."
        } catch {
            deletionError = error.localizedDescription
            isShowingDeletionError = true
        }
    }

    private func canRedownload(_ recording: RecordingEntry) -> Bool {
        if let target = recording.sourceTarget?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            return true
        }
        if let target = recordingManager.recordingSourceTarget(for: recording.url)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            return true
        }
        return recording.sourceType == .liveRecording
    }

    private var duplicateRecordingGroups: [RecordingDuplicateGroup] {
        recordingManager.duplicateRecordingGroups(in: recordings).map { group in
            RecordingDuplicateGroup(
                id: group.key,
                items: group.items,
                wastedBytes: group.wastedBytes
            )
        }
    }

    private func removeDuplicateRecordings() {
        let result = recordingManager.cleanupDuplicateRecordings(in: recordings)

        refreshRecordings()
        refreshDiskUsage()
        thumbnailRefreshToken = UUID()

        if result.failedMessages.isEmpty {
            exportStatus = "Removed \(result.removedCount) duplicate recording(s)."
        } else {
            deletionError = "Removed \(result.removedCount) duplicate(s). Failed \(result.failedMessages.count):\n" + result.failedMessages.joined(separator: "\n")
            isShowingDeletionError = true
        }
    }

    private func runIntegrityScan() {
        guard !isIntegrityScanning else { return }
        isIntegrityScanning = true

        Task.detached(priority: .utility) {
            let report = await MainActor.run {
                recordingManager.scanLibraryIntegrity()
            }
            await MainActor.run {
                integrityReport = report
                isIntegrityScanning = false
                if report.issueCount == 0 {
                    dismissedIntegrityBannerID = nil
                }
            }
        }
    }

    private func repairLibraryIntegrity() {
        guard !isIntegrityRepairing else { return }
        isIntegrityRepairing = true

        Task.detached(priority: .utility) {
            let result = await MainActor.run {
                recordingManager.repairLibraryIntegrity(integrityReport)
            }
            await MainActor.run {
                isIntegrityRepairing = false
                refreshRecordings()
                refreshDiskUsage()
                thumbnailRefreshToken = UUID()
                integrityReport = recordingManager.scanLibraryIntegrity()
                dismissedIntegrityBannerID = nil

                let unresolved = result.unresolvedUnreadableFiles.count
                exportStatus = "Integrity repair: manifest \(result.removedManifestEntries), thumbnails \(result.regeneratedThumbnails), cleaned thumbs \(result.removedOrphanedThumbnails), unreadable \(unresolved)."
            }
        }
    }

    private func fileSize(for entry: RecordingEntry) -> Int64 {
        if let metadata = technicalMetadataByURL[entry.url] {
            return metadata.fileSizeBytes
        }
        if let cached = fileSizeCache[entry.url] { return cached }
        let attrs = try? FileManager.default.attributesOfItem(atPath: entry.url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        // Note: cannot mutate cache here since this is called from a computed property.
        return size
    }

    private var sortedFilteredRecordings: [RecordingEntry] {
        let base = filteredRecordings
        switch sortOrder {
        case .dateDesc:
            return base.sorted { l, r in
                let ld = captureDate(for: l) ?? Date.distantPast
                let rd = captureDate(for: r) ?? Date.distantPast
                return ld > rd
            }
        case .dateAsc:
            return base.sorted { l, r in
                let ld = captureDate(for: l) ?? Date.distantPast
                let rd = captureDate(for: r) ?? Date.distantPast
                return ld < rd
            }
        case .channelAsc:
            return base.sorted { l, r in
                l.channelName.localizedCaseInsensitiveCompare(r.channelName) == .orderedAscending
            }
        case .sizeDesc:
            return base.sorted { l, r in
                fileSize(for: l) > fileSize(for: r)
            }
        }
    }

    private var displayedSortedRecordings: [RecordingEntry] {
        Array(sortedFilteredRecordings.prefix(max(renderedRecordLimit, 1)))
    }

    private var hasMoreRecordingsToRender: Bool {
        sortedFilteredRecordings.count > displayedSortedRecordings.count
    }

    private var groupedRecordings: [(channel: String, items: [RecordingEntry])] {
        guard groupByStreamer else {
            return [(channel: "All", items: displayedSortedRecordings)]
        }

        let groups = Dictionary(grouping: displayedSortedRecordings) { $0.channelName }
        return groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { key in
                let items = groups[key, default: []]
                return (channel: key, items: items)
            }
    }

    private func isBeforeInSortOrder(_ left: RecordingEntry, _ right: RecordingEntry) -> Bool {
        let result: ComparisonResult
        switch sortColumn {
        case .date:
            result = compareOptionalDate(captureDate(for: left), captureDate(for: right))
        case .channel:
            result = left.channelName.localizedCaseInsensitiveCompare(right.channelName)
        case .filename:
            result = left.url.lastPathComponent.localizedCaseInsensitiveCompare(right.url.lastPathComponent)
        }

        if result == .orderedSame {
            return left.url.lastPathComponent.localizedCaseInsensitiveCompare(right.url.lastPathComponent) == .orderedAscending
        }

        if sortAscending {
            return result == .orderedAscending
        }
        return result == .orderedDescending
    }

    private func captureDate(for recording: RecordingEntry) -> Date? {
        recording.recordedAt ?? recording.fileTimestamp
    }

    private func compareOptionalDate(_ left: Date?, _ right: Date?) -> ComparisonResult {
        switch (left, right) {
        case let (lhs?, rhs?):
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            return .orderedSame
        }
    }

    private func formattedDate(for recording: RecordingEntry) -> String {
        guard let date = captureDate(for: recording) else { return "Unknown capture time" }
        return dateFormatter.string(from: date)
    }

    private func formattedFileTime(for recording: RecordingEntry) -> String {
        guard let fileDate = recording.fileTimestamp else { return "Unknown file time" }
        return dateFormatter.string(from: fileDate)
    }

    // MARK: - Feature 3: Disk usage

    private var formattedDiskUsage: String {
        let bytes = totalDiskUsageBytes
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        } else if bytes >= 1_048_576 {
            return String(format: "%d MB", bytes / 1_048_576)
        } else {
            return String(format: "%d KB", bytes / 1_024)
        }
    }

    private func refreshDiskUsage() {
        let dir = recordingManager.recordingsDirectory()
        let recordingSnapshot = recordings
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                while let next = enumerator.nextObject() as? URL {
                    let ext = next.pathExtension.lowercased()
                    guard ext == "mp4" || ext == "glitcho" else { continue }
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: next.path),
                       let size = attrs[.size] as? Int64 {
                        total += size
                    }
                }
            }

            var warmedSizes: [URL: Int64] = [:]
            for entry in recordingSnapshot {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: entry.url.path),
                   let size = attrs[.size] as? Int64 {
                    warmedSizes[entry.url] = size
                }
            }

            DispatchQueue.main.async {
                totalDiskUsageBytes = total
                for (url, size) in warmedSizes {
                    fileSizeCache[url] = size
                }
            }
        }
    }

    // MARK: - Recordings management

    private func refreshRecordings() {
        let previousURL = selectedRecording?.url
        let allRecordings = recordingManager.listRecordings()
        recordings = allRecordings.filter(isRecordingVisible)
        let liveURLs = Set(recordings.map(\.id))
        selectedRecordingIDs = selectedRecordingIDs.intersection(liveURLs)
        multiSelection = multiSelection.intersection(liveURLs)

        if let selected = selectedRecording, !recordings.contains(selected) {
            selectedRecording = nil
        }

        let newURL = selectedRecording?.url
        let selectionChanged = previousURL != newURL

        if selectionChanged {
            playbackURL = nil
            playbackError = nil
            isPreparingPlayback = false
            playbackDurationSeconds = nil
        }

        if selectedRecording == nil, isPlaybackModalPresented {
            closePlaybackModal()
        }

        if isPlaybackModalPresented, playbackURL == nil, selectedRecording != nil, !isPreparingPlayback {
            prepareSelectedRecording()
        }

        prefetchVisibleAssets()
    }

    private func openPlaybackModal(for recording: RecordingEntry) {
        let changedSelection = selectedRecording?.url != recording.url
        selectedRecording = recording
        isPlaybackModalPresented = true

        if changedSelection {
            playbackURL = nil
            playbackError = nil
            isPreparingPlayback = false
            playbackDurationSeconds = nil
        }

        if playbackURL == nil, !isPreparingPlayback {
            prepareSelectedRecording()
        } else {
            isPlaying = true
        }
    }

    private func closePlaybackModal() {
        isPlaybackModalPresented = false
        isPlaying = false
        showPlayerMorePopover = false
    }

    private func isRecordingVisible(_ recording: RecordingEntry) -> Bool {
        guard !showProtectedRecordings else { return true }
        if isFallbackEncryptedRecording(recording) {
            // If metadata is unavailable we cannot map the file to a streamer.
            // Treat these as protected while privacy lock is active.
            return false
        }
        let normalized = recording.channelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return !protectedChannelLogins.contains(normalized)
    }

    private func isFallbackEncryptedRecording(_ recording: RecordingEntry) -> Bool {
        recording.url.pathExtension.lowercased() == "glitcho"
            && recording.channelName == "Encrypted Recording"
    }

    private func toggleSelection(for recording: RecordingEntry) {
        if selectedRecordingIDs.contains(recording.id) {
            selectedRecordingIDs.remove(recording.id)
            multiSelection.remove(recording.id)
        } else {
            selectedRecordingIDs.insert(recording.id)
            multiSelection.insert(recording.id)
        }
    }

    private func performDelete(_ recording: RecordingEntry) {
        recordingPendingDeletion = nil

        do {
            try recordingManager.deleteRecording(at: recording.url)

            if selectedRecording == recording {
                selectedRecording = nil
                playbackURL = nil
                playbackError = nil
                isPreparingPlayback = false
                isPlaying = false
                isPlaybackModalPresented = false
            }

            thumbnailRefreshToken = UUID()
            refreshRecordings()
        } catch {
            deletionError = error.localizedDescription
            isShowingDeletionError = true
        }
    }

    private func performBulkDelete() {
        let selectedURLs = selectedRecordingIDs
        guard !selectedURLs.isEmpty else { return }

        var deletedCount = 0
        var failures: [String] = []

        for url in selectedURLs {
            do {
                try recordingManager.deleteRecording(at: url)
                deletedCount += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let selectedRecording, selectedURLs.contains(selectedRecording.url) {
            self.selectedRecording = nil
            playbackURL = nil
            playbackError = nil
            isPreparingPlayback = false
            isPlaying = false
            isPlaybackModalPresented = false
        }

        selectedRecordingIDs.removeAll()
        multiSelection.removeAll()
        thumbnailRefreshToken = UUID()
        refreshRecordings()

        if !failures.isEmpty {
            deletionError = "Deleted \(deletedCount) download(s). Failed \(failures.count):\n" + failures.joined(separator: "\n")
            isShowingDeletionError = true
        } else {
            exportStatus = "Deleted \(deletedCount) download(s)."
        }
    }

    private func exportSelectedRecordings() {
        let selectedEntries = recordings.filter { selectedRecordingIDs.contains($0.id) }
        guard !selectedEntries.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destinationDir = panel.url else { return }

        isExporting = true
        exportProgress = 0
        exportStatus = nil

        Task {
            var exported = 0
            var failures: [String] = []

            for (index, entry) in selectedEntries.enumerated() {
                do {
                    _ = try recordingManager.exportRecording(at: entry.url, to: destinationDir)
                    exported += 1
                } catch {
                    let displayName = recordingManager.displayFilename(for: entry.url)
                    failures.append("\(displayName): \(error.localizedDescription)")
                }

                await MainActor.run {
                    exportProgress = Double(index + 1) / Double(max(selectedEntries.count, 1))
                }
            }

            await MainActor.run {
                isExporting = false
                refreshDiskUsage()
                if failures.isEmpty {
                    exportStatus = "Exported \(exported) download(s) to \(destinationDir.path)."
                } else {
                    exportStatus = "Exported \(exported) download(s), failed \(failures.count)."
                    deletionError = failures.joined(separator: "\n")
                    isShowingDeletionError = true
                }
            }
        }
    }

    // MARK: - Task 3: Playback position persistence

    private func playbackPositionKey(for url: URL) -> String {
        "playback.pos.\(url.path)"
    }

    /// Returns the saved position to seek to, or nil if we should start from the beginning.
    /// Clears the saved position if it is within 10 seconds of the end (duration unknown at call time,
    /// so we use a simple guard: if position is 0 or negative, return nil).
    private func savedPlaybackPosition(for url: URL) -> Double? {
        let key = playbackPositionKey(for: url)
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 5 else { return nil }
        return saved
    }

    private func savePlaybackPosition(_ seconds: Double, for url: URL) {
        let key = playbackPositionKey(for: url)
        UserDefaults.standard.set(seconds, forKey: key)
    }

    private func clearPlaybackPosition(for url: URL) {
        let key = playbackPositionKey(for: url)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Task 4: Clip export helpers

    private func resolvedFFmpegPath() -> String? {
        if let path = UserDefaults.standard.string(forKey: "ffmpegPath"),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func loadPlaybackDuration(for url: URL) {
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let loaded = try? await asset.load(.duration).seconds
            await MainActor.run {
                guard self.playbackURL == url else { return }
                if let loaded, loaded.isFinite, loaded > 0 {
                    self.playbackDurationSeconds = loaded
                } else {
                    self.playbackDurationSeconds = nil
                }
            }
        }
    }

    private func prepareSelectedRecording() {
        guard let selected = selectedRecording else {
            playbackURL = nil
            playbackError = nil
            isPreparingPlayback = false
            return
        }

        let url = selected.url
        playbackURL = nil
        playbackError = nil
        playbackDurationSeconds = nil

        if recordingManager.isRecording(outputURL: url) {
            isPreparingPlayback = false
            playbackError = "This download is still in progress. Cancel it before playing."
            return
        }

        isPreparingPlayback = true
        isPlaying = false
        playbackRate = 1.0
        videoZoom = 1.0
        videoPan = .zero
        motionRuntimeStatus = nil

        // .mp4 path — may require a one-time remux for Transport Stream files.
        Task {
            do {
                let result = try await recordingManager.prepareRecordingForPlayback(at: url)
                if self.selectedRecording?.url != url {
                    isPreparingPlayback = false
                    return
                }
                if result.didRemux {
                    thumbnailRefreshToken = UUID()
                    // Trigger an async library refresh instead of calling refreshRecordings()
                    // synchronously — the synchronous call would block the main actor with
                    // manifest I/O and could also start a second prepareSelectedRecording().
                    NotificationCenter.default.post(name: .recordingLibraryDidChange, object: nil)
                }
                seekOnLoadSeconds = savedPlaybackPosition(for: url)
                playbackURL = result.url
                loadPlaybackDuration(for: result.url)
                isPreparingPlayback = false
                isPlaying = true
            } catch {
                if self.selectedRecording?.url != selected.url {
                    isPreparingPlayback = false
                    return
                }
                playbackURL = nil
                playbackError = error.localizedDescription
                isPreparingPlayback = false
            }
        }
    }
}

private struct RecordingOverlayValueSlider: View {
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

private struct RecordingAirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView(frame: .zero)
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct RecordingGridCard: View {
    let recording: RecordingEntry
    let formattedDate: String
    let formattedFileTime: String
    let sourceLabel: String
    let sourceBadge: String
    let displayFilename: String
    let technicalSummary: String?
    let isSelected: Bool
    let isMultiSelectMode: Bool
    let isChecked: Bool
    let thumbnailRefreshToken: UUID
    let isDeleteDisabled: Bool
    let recordingManager: RecordingManager?
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onToggleSelection: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RecordingThumbnailView(url: recording.url, recordingManager: recordingManager)
                    .id("\(recording.url.path):\(thumbnailRefreshToken.uuidString)")
                    .frame(height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if isDeleteDisabled {
                    // LIVE badge — always visible when a recording is in progress.
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(6)
                } else if isMultiSelectMode {
                    Button(action: onToggleSelection) {
                        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isChecked ? Color.white : Color.white.opacity(0.55))
                            .padding(6)
                            .background(Color.black.opacity(0.35))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }

            Text(recording.channelName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RecordingsChrome.textPrimary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(sourceLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RecordingsChrome.textSecondary)
                    .lineLimit(1)
                Text(sourceBadge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            Text(displayFilename)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(RecordingsChrome.textMuted)
                .lineLimit(1)

            if let technicalSummary, !technicalSummary.isEmpty {
                Text(technicalSummary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(RecordingsChrome.textSubtle)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Label(formattedFileTime, systemImage: "clock")
                Spacer(minLength: 0)
                if !isMultiSelectMode {
                    Button {
                        onOpen()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RecordingsChrome.textSecondary)
                    .help("Play")

                    Button {
                        onReveal()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RecordingsChrome.textSecondary)
                    .help("Reveal in Finder")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isDeleteDisabled ? Color.white.opacity(0.2) : Color.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleteDisabled)
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(RecordingsChrome.textSubtle)
            .lineLimit(1)
        }
        .padding(8)
        .recordingsSurfaceCard(
            fill: (isSelected || isChecked) ? Color.white.opacity(0.1) : Color.white.opacity(0.03),
            strokeOpacity: isHovered ? 1 : 0,
            cornerRadius: 10
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpen()
        }
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

struct RecordingRow: View {
    let recording: RecordingEntry
    let formattedDate: String
    let formattedFileTime: String
    let sourceLabel: String
    let sourceBadge: String
    let displayFilename: String
    let technicalSummary: String?
    let isSelected: Bool
    let isMultiSelectMode: Bool
    let isChecked: Bool
    let thumbnailRefreshToken: UUID
    let isDeleteDisabled: Bool
    let recordingManager: RecordingManager?
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onToggleSelection: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            if isMultiSelectMode {
                Button(action: onToggleSelection) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isChecked ? Color.white : Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            ZStack(alignment: .topLeading) {
                RecordingThumbnailView(url: recording.url, recordingManager: recordingManager)
                    .id("\(recording.url.path):\(thumbnailRefreshToken.uuidString)")
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if isDeleteDisabled {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(5)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(recording.channelName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RecordingsChrome.textPrimary)
                        .lineLimit(1)
                    Text(sourceLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RecordingsChrome.textSecondary)
                    Text(sourceBadge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                    Spacer(minLength: 0)
                }
                Text(displayFilename)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RecordingsChrome.textMuted)
                    .lineLimit(1)
                if let technicalSummary, !technicalSummary.isEmpty {
                    Text(technicalSummary)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(RecordingsChrome.textMuted)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Label(formattedFileTime, systemImage: "clock")
                    Spacer(minLength: 0)
                    if !isMultiSelectMode {
                        Button {
                            onOpen()
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(RecordingsChrome.textSecondary)
                        .opacity((isHovered || isSelected) ? 1 : 0.6)

                        Button {
                            onReveal()
                        } label: {
                            Label("Reveal", systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(RecordingsChrome.textSecondary)
                        .opacity((isHovered || isSelected) ? 1 : 0.6)

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isDeleteDisabled ? Color.white.opacity(0.2) : Color.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleteDisabled)
                        .opacity((isHovered || isSelected) ? 1 : 0.6)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(RecordingsChrome.textSubtle)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .recordingsSurfaceCard(
            fill: (isSelected || isChecked) ? Color.white.opacity(0.1) : Color.clear,
            strokeOpacity: isHovered ? 1 : 0,
            cornerRadius: 10
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpen()
        }
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

struct RecordingThumbnailView: View {
    let url: URL
    @StateObject private var loader: RecordingThumbnailLoader
    @StateObject private var previewController: RecordingPreviewController
    @State private var isHovered = false

    init(url: URL, recordingManager: RecordingManager? = nil) {
        self.url = url
        _loader = StateObject(wrappedValue: RecordingThumbnailLoader(url: url, recordingManager: recordingManager))
        _previewController = StateObject(wrappedValue: RecordingPreviewController(url: url))
    }

    var body: some View {
        ZStack {
            if isHovered && previewController.canPreview {
                RecordingPreviewPlayer(player: previewController.player, isPlaying: true)
                    .transition(.opacity)
            } else if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loader.isLoading {
                ZStack {
                    Color.white.opacity(0.08)
                    ProgressView()
                        .scaleEffect(0.5)
                        .tint(.white.opacity(0.4))
                }
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "film")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.25))
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
    @Published var isLoading = true
    private let url: URL
    private static let imageCache = NSCache<NSString, NSImage>()
    private static var prefetchInFlight = Set<String>()
    private static let prefetchLock = NSLock()

    init(url: URL, recordingManager: RecordingManager? = nil) {
        self.url = url
        if let cached = Self.imageCache.object(forKey: url.path as NSString) {
            self.image = cached
            self.isLoading = false
            return
        }
        loadThumbnail()
    }

    static func prefetchThumbnails(for urls: [URL], recordingManager: RecordingManager?) {
        let candidates = Array(urls.prefix(240))
        guard !candidates.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            for url in candidates {
                let key = url.path as NSString
                if imageCache.object(forKey: key) != nil {
                    continue
                }

                prefetchLock.lock()
                if prefetchInFlight.contains(url.path) {
                    prefetchLock.unlock()
                    continue
                }
                prefetchInFlight.insert(url.path)
                prefetchLock.unlock()

                defer {
                    prefetchLock.lock()
                    prefetchInFlight.remove(url.path)
                    prefetchLock.unlock()
                }

                let image: NSImage? = {
                    if url.pathExtension.lowercased() == "glitcho" {
                        return loadEncryptedThumbnailImage(for: url)
                    }
                    let asset = AVAsset(url: url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 320, height: 180)
                    let time = CMTime(seconds: 1.0, preferredTimescale: 600)
                    guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                        return nil
                    }
                    return NSImage(cgImage: cgImage, size: .zero)
                }()

                if let image {
                    imageCache.setObject(image, forKey: key)
                }
            }
        }
    }

    private func loadThumbnail() {
        if url.pathExtension.lowercased() == "glitcho" {
            DispatchQueue.global(qos: .userInitiated).async {
                let nsImage = Self.loadEncryptedThumbnailImage(for: self.url)
                DispatchQueue.main.async {
                    self.image = nsImage
                    if let nsImage {
                        Self.imageCache.setObject(nsImage, forKey: self.url.path as NSString)
                    }
                    self.isLoading = false
                }
            }
            return
        }

        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        DispatchQueue.global(qos: .userInitiated).async {
            let time = CMTime(seconds: 1.0, preferredTimescale: 600)
            let nsImage = (try? generator.copyCGImage(at: time, actualTime: nil))
                .map { NSImage(cgImage: $0, size: .zero) }
            DispatchQueue.main.async {
                self.image = nsImage
                if let nsImage {
                    Self.imageCache.setObject(nsImage, forKey: self.url.path as NSString)
                }
                self.isLoading = false
            }
        }
    }

    private static func loadEncryptedThumbnailImage(for recordingURL: URL) -> NSImage? {
        let hashFilename = recordingURL.lastPathComponent
        let thumbURL = RecordingEncryptionManager.thumbnailURL(for: hashFilename)

        func loadFromSidecar() -> NSImage? {
            guard let data = try? Data(contentsOf: thumbURL),
                  !data.isEmpty,
                  let image = NSImage(data: data) else {
                return nil
            }
            return image
        }

        if let image = loadFromSidecar() {
            return image
        }

        let encryptionManager = RecordingEncryptionManager()
        let recordingsDirectory = recordingURL.deletingLastPathComponent()
        try? encryptionManager.regenerateThumbnailSidecar(for: hashFilename, in: recordingsDirectory)
        return loadFromSidecar()
    }
}

final class RecordingPreviewController: ObservableObject {
    let player: AVPlayer
    let canPreview: Bool

    init(url: URL) {
        canPreview = url.pathExtension.lowercased() != "glitcho"
        if canPreview {
            player = AVPlayer(url: url)
        } else {
            player = AVPlayer()
        }
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    func setPlaying(_ playing: Bool) {
        guard canPreview else { return }
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
