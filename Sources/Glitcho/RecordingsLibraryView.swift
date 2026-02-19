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

struct RecordingsLibraryView: View {
    @ObservedObject var recordingManager: RecordingManager
    @StateObject private var pipController = PictureInPictureController()
    @State private var recordings: [RecordingEntry] = []
    @State private var selectedRecording: RecordingEntry?
    @State private var selectedRecordingIDs: Set<URL> = []
    @AppStorage("recordingsLibraryLayoutMode") private var layoutModeRaw = RecordingsLayoutMode.list.rawValue
    @AppStorage("recordingsLibrarySortColumn") private var sortColumnRaw = RecordingsSortColumn.date.rawValue
    @AppStorage("recordingsLibrarySortAscending") private var sortAscending = false
    @AppStorage("recordingsLibraryGroupByStreamer") private var groupByStreamer = true
    @State private var isMultiSelectMode = false
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

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
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
        HStack(spacing: 0) {
            librarySidebarView

            Divider()
                .background(Color.white.opacity(0.08))

            playerDetailView
        }
        .onAppear {
            refreshRecordings()
            refreshMotionCapability()
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
            "Delete recording?",
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
            "Delete selected recordings?",
            isPresented: $showBulkDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                performBulkDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move \(selectedRecordingIDs.count) recording(s) to the Trash.")
        }
        .alert(
            "Couldn't delete recording",
            isPresented: $isShowingDeletionError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "Unknown error")
        }
    }

    private var librarySidebarView: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbarControls
            searchField
            exportStatusView
            recordingsListContainer
        }
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }

    private var toolbarControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Recordings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()

                if isMultiSelectMode {
                    Text("\(selectedRecordingIDs.count) selected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))

                    Menu {
                        Button("Select All Visible") {
                            selectedRecordingIDs = Set(sortedFilteredRecordings.map(\.id))
                        }
                        Button("Clear Selection") {
                            selectedRecordingIDs.removeAll()
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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .menuStyle(.borderlessButton)
                }

                Button {
                    isMultiSelectMode.toggle()
                    if !isMultiSelectMode {
                        selectedRecordingIDs.removeAll()
                    }
                } label: {
                    Image(systemName: isMultiSelectMode ? "checklist.checked" : "checklist")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(isMultiSelectMode ? "Disable multi-select" : "Enable multi-select")

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

            HStack(spacing: 10) {
                Picker("Layout", selection: layoutModeBinding) {
                    ForEach(RecordingsLayoutMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.iconName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 84)

                Menu {
                    ForEach(RecordingsSortColumn.allCases, id: \.self) { column in
                        Button {
                            sortColumn = column
                        } label: {
                            if sortColumn == column {
                                Text("✓ \(column.title)")
                            } else {
                                Text(column.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .menuStyle(.borderlessButton)
                .help("Sort column")

                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help(sortAscending ? "Ascending" : "Descending")

                Button {
                    groupByStreamer.toggle()
                } label: {
                    Image(systemName: groupByStreamer ? "square.3.layers.3d.down.right.fill" : "square.3.layers.3d.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help(groupByStreamer ? "Disable streamer grouping" : "Enable streamer grouping")

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            TextField("Search recordings", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var exportStatusView: some View {
        if isExporting {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: exportProgress, total: 1.0)
                    .tint(.white.opacity(0.8))
                Text("Exporting recordings…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 16)
        } else if let exportStatus {
            Text(exportStatus)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 16)
        }
    }

    private var recordingsListContainer: some View {
        ScrollView {
            if recordings.isEmpty {
                Text("No recordings yet.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else if sortedFilteredRecordings.isEmpty {
                Text("No recordings match your current search.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                recordingsCollectionView
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
                            imageOptimizationConfiguration: imageOptimizationConfiguration
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if isMotionSmootheningActive || isUpscaler4KActive {
                            VStack {
                                HStack(spacing: 8) {
                                    if isMotionSmootheningActive, let status = motionRuntimeStatus {
                                        recordingMotionFPSBadge(status)
                                    }
                                    if isUpscaler4KActive {
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
                        Text("Preparing recording…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.05, green: 0.05, blue: 0.07))
                } else if let playbackError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color.orange.opacity(0.9))
                        Text("Unable to play this recording")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(playbackError)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.05, green: 0.05, blue: 0.07))
                } else {
                    emptyPlayerStateView
                }
            } else {
                emptyPlayerStateView
            }
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.07))
    }

    private var recordingPlayerControlsToolbar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            HStack(spacing: 8) {
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

                Button(action: { showPlayerMorePopover.toggle() }) {
                    Label("More", systemImage: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .help("More controls")
                .popover(isPresented: $showPlayerMorePopover, arrowEdge: .bottom) {
                    recordingPlayerMorePopover
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.1))
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
            Text("Select a recording to play")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.05, blue: 0.07))
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
                            isSelected: recording == selectedRecording,
                            isMultiSelectMode: isMultiSelectMode,
                            isChecked: selectedRecordingIDs.contains(recording.id),
                            thumbnailRefreshToken: thumbnailRefreshToken,
                            isDeleteDisabled: isDeleteDisabled,
                            onSelect: {
                                if isMultiSelectMode {
                                    toggleSelection(for: recording)
                                } else {
                                    selectedRecording = recording
                                    prepareSelectedRecording()
                                }
                            },
                            onToggleSelection: {
                                toggleSelection(for: recording)
                            },
                            onDelete: {
                                recordingPendingDeletion = recording
                            }
                        )
                    }
                }
            }
        }
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
                                isSelected: recording == selectedRecording,
                                isMultiSelectMode: isMultiSelectMode,
                                isChecked: selectedRecordingIDs.contains(recording.id),
                                thumbnailRefreshToken: thumbnailRefreshToken,
                                isDeleteDisabled: isDeleteDisabled,
                                onSelect: {
                                    if isMultiSelectMode {
                                        toggleSelection(for: recording)
                                    } else {
                                        selectedRecording = recording
                                        prepareSelectedRecording()
                                    }
                                },
                                onToggleSelection: {
                                    toggleSelection(for: recording)
                                },
                                onDelete: {
                                    recordingPendingDeletion = recording
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var filteredRecordings: [RecordingEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return recordings }
        return recordings.filter { recording in
            recording.channelName.lowercased().contains(query)
                || recording.url.lastPathComponent.lowercased().contains(query)
        }
    }

    private var sortedFilteredRecordings: [RecordingEntry] {
        filteredRecordings.sorted(by: isBeforeInSortOrder)
    }

    private var groupedRecordings: [(channel: String, items: [RecordingEntry])] {
        guard groupByStreamer else {
            return [(channel: "All", items: sortedFilteredRecordings)]
        }

        let groups = Dictionary(grouping: sortedFilteredRecordings) { $0.channelName }
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
            result = compareOptionalDate(left.recordedAt, right.recordedAt)
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
        guard let date = recording.recordedAt else { return "Unknown date" }
        return dateFormatter.string(from: date)
    }

    private func refreshRecordings() {
        let previousURL = selectedRecording?.url
        recordings = recordingManager.listRecordings()
        selectedRecordingIDs = selectedRecordingIDs.intersection(Set(recordings.map(\.id)))

        if let selected = selectedRecording, !recordings.contains(selected) {
            selectedRecording = recordings.first
        } else if selectedRecording == nil {
            selectedRecording = recordings.first
        }

        let newURL = selectedRecording?.url
        let selectionChanged = previousURL != newURL

        if selectionChanged {
            playbackURL = nil
            playbackError = nil
        }

        if playbackURL == nil, selectedRecording != nil {
            prepareSelectedRecording()
        }
    }

    private func toggleSelection(for recording: RecordingEntry) {
        if selectedRecordingIDs.contains(recording.id) {
            selectedRecordingIDs.remove(recording.id)
        } else {
            selectedRecordingIDs.insert(recording.id)
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
        }

        selectedRecordingIDs.removeAll()
        thumbnailRefreshToken = UUID()
        refreshRecordings()

        if !failures.isEmpty {
            deletionError = "Deleted \(deletedCount) recording(s). Failed \(failures.count):\n" + failures.joined(separator: "\n")
            isShowingDeletionError = true
        } else {
            exportStatus = "Deleted \(deletedCount) recording(s)."
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
                let originalFilename: String
                if entry.url.pathExtension == "glitcho" {
                    let dir = recordingManager.recordingsDirectory()
                    let manifest = (try? recordingManager.effectiveEncryptionManager.loadManifest(from: dir)) ?? [:]
                    originalFilename = manifest[entry.url.lastPathComponent]?.originalFilename ?? "\(entry.channelName).mp4"
                } else {
                    originalFilename = entry.url.lastPathComponent
                }

                let destination = destinationDir.appendingPathComponent(originalFilename)
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }

                    if entry.url.pathExtension == "glitcho" {
                        try recordingManager.effectiveEncryptionManager.decryptFile(
                            named: entry.url.lastPathComponent,
                            in: recordingManager.recordingsDirectory(),
                            to: destination
                        )
                    } else {
                        try FileManager.default.copyItem(at: entry.url, to: destination)
                    }
                    exported += 1
                } catch {
                    failures.append("\(originalFilename): \(error.localizedDescription)")
                }

                await MainActor.run {
                    exportProgress = Double(index + 1) / Double(max(selectedEntries.count, 1))
                }
            }

            await MainActor.run {
                isExporting = false
                if failures.isEmpty {
                    exportStatus = "Exported \(exported) recording(s) to \(destinationDir.path)."
                } else {
                    exportStatus = "Exported \(exported) recording(s), failed \(failures.count)."
                    deletionError = failures.joined(separator: "\n")
                    isShowingDeletionError = true
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

        if recordingManager.isRecording(outputURL: url) {
            isPreparingPlayback = false
            playbackError = "This recording is still in progress. Stop recording before playing it."
            return
        }

        isPreparingPlayback = true
        isPlaying = false
        videoZoom = 1.0
        videoPan = .zero
        motionRuntimeStatus = nil

        Task {
            do {
                if url.pathExtension == "glitcho" {
                    let tempURL = recordingManager.effectiveEncryptionManager.tempPlaybackURL()
                    try recordingManager.effectiveEncryptionManager.decryptFile(
                        named: url.lastPathComponent,
                        in: recordingManager.recordingsDirectory(),
                        to: tempURL
                    )
                    let result = try await recordingManager.prepareRecordingForPlayback(at: tempURL)
                    if self.selectedRecording?.url != selected.url { return }
                    playbackURL = result.url
                    isPreparingPlayback = false
                    isPlaying = true
                } else {
                    let result = try await recordingManager.prepareRecordingForPlayback(at: url)
                    if self.selectedRecording?.url != url { return }
                    if result.didRemux {
                        thumbnailRefreshToken = UUID()
                        refreshRecordings()
                    }
                    playbackURL = result.url
                    isPreparingPlayback = false
                    isPlaying = true
                }
            } catch {
                if self.selectedRecording?.url != selected.url { return }
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
    let isSelected: Bool
    let isMultiSelectMode: Bool
    let isChecked: Bool
    let thumbnailRefreshToken: UUID
    let isDeleteDisabled: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RecordingThumbnailView(url: recording.url)
                    .id("\(recording.url.path):\(thumbnailRefreshToken.uuidString)")
                    .frame(height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if isMultiSelectMode {
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
                } else {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isDeleteDisabled ? Color.white.opacity(0.2) : Color.red.opacity(0.85))
                            .padding(6)
                            .background(Color.black.opacity(0.35))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleteDisabled)
                    .opacity(isHovered || isSelected ? 1 : 0)
                }
            }

            Text(recording.channelName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(formattedDate)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((isSelected || isChecked) ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.12 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
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
    let isSelected: Bool
    let isMultiSelectMode: Bool
    let isChecked: Bool
    let thumbnailRefreshToken: UUID
    let isDeleteDisabled: Bool
    let onSelect: () -> Void
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

            RecordingThumbnailView(url: recording.url)
                .id("\(recording.url.path):\(thumbnailRefreshToken.uuidString)")
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

            if !isMultiSelectMode {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isDeleteDisabled ? Color.white.opacity(0.15) : Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(isDeleteDisabled)
                .help(isDeleteDisabled ? "Stop recording to delete" : "Delete recording")
                .opacity((isHovered || isSelected) ? 1.0 : 0.0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((isSelected || isChecked) ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
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
        if url.pathExtension == "glitcho" {
            // Encrypted file — skip thumbnail (would require decryption).
            return
        }

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
        if url.pathExtension == "glitcho" {
            player = AVPlayer()
        } else {
            player = AVPlayer(url: url)
        }
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
