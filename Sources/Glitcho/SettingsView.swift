#if canImport(SwiftUI)
import AppKit
import SwiftUI

private enum BackgroundControlAction {
    case restartAgent
    case stopAllRecordings

    var confirmationTitle: String {
        switch self {
        case .restartAgent:
            return "Restart Background Agent?"
        case .stopAllRecordings:
            return "Stop All Recordings?"
        }
    }
}

private struct RestartAgentStatus {
    let timestamp: Date
    let result: String
    let isSuccess: Bool
}

struct SettingsDetailView: View {
    @AppStorage("liveAlertsEnabled") private var liveAlertsEnabled = true
    @AppStorage("liveAlertsPinnedOnly") private var liveAlertsPinnedOnly = false
    @AppStorage(SidebarTint.storageKey) private var sidebarTintHex = SidebarTint.defaultHex
    @AppStorage("recordingsDirectory") private var recordingsDirectory = ""
    @AppStorage("streamlinkPath") private var streamlinkPath = ""
    @AppStorage("ffmpegPath") private var ffmpegPath = ""
    @AppStorage("autoRecordOnLive") private var autoRecordOnLive = false
    @AppStorage("autoRecordPinnedOnly") private var autoRecordPinnedOnly = false
    @AppStorage("autoRecordMode") private var autoRecordModeRaw = AutoRecordMode.pinnedAndFollowed.rawValue
    @AppStorage("autoRecordDebounceSeconds") private var autoRecordDebounceSeconds = 1
    @AppStorage("autoRecordCooldownSeconds") private var autoRecordCooldownSeconds = 30
    @AppStorage("recordingConcurrencyLimit") private var recordingConcurrencyLimit = 2
    @AppStorage("companionAPIEnabled") private var companionAPIEnabled = true
    @AppStorage("companionAPIPort") private var companionAPIPort = 44555
    @AppStorage("companionAPIToken") private var companionAPIToken = ""
    @AppStorage("recordingsRetentionMaxAgeDays") private var recordingsRetentionMaxAgeDays = 0
    @AppStorage("recordingsRetentionKeepLastGlobal") private var recordingsRetentionKeepLastGlobal = 0
    @AppStorage("recordingsRetentionKeepLastPerChannel") private var recordingsRetentionKeepLastPerChannel = 0
    @AppStorage("motionSmoothening120Enabled") private var motionSmoothening120Enabled = false
    @AppStorage("video.upscaler4kEnabled") private var videoUpscaler4KEnabled = false
    @AppStorage("video.imageOptimizeEnabled") private var videoImageOptimizeEnabled = false
    @AppStorage("video.aspectCropMode") private var videoAspectModeRaw = VideoAspectCropMode.source.rawValue
    @AppStorage("video.imageOptimize.contrast") private var imageOptimizeContrast = ImageOptimizationConfiguration.productionDefault.contrast
    @AppStorage("video.imageOptimize.lighting") private var imageOptimizeLighting = ImageOptimizationConfiguration.productionDefault.lighting
    @AppStorage("video.imageOptimize.denoiser") private var imageOptimizeDenoiser = ImageOptimizationConfiguration.productionDefault.denoiser
    @AppStorage("video.imageOptimize.neuralClarity") private var imageOptimizeNeuralClarity = ImageOptimizationConfiguration.productionDefault.neuralClarity
    @Environment(\.notificationManager) private var notificationManager
    @Environment(\.openURL) private var openURL
    @State private var testStatus: NotificationTestStatus?
    @State private var clearTask: Task<Void, Never>?
    @State private var motionCapability = MotionSmootheningCapability.evaluate(screen: NSScreen.main)

    @ObservedObject var recordingManager: RecordingManager
    @ObservedObject var backgroundAgentManager: BackgroundRecorderAgentManager
    @ObservedObject var store: WebViewStore
    @ObservedObject var companionAPIServer: CompanionAPIServer
    @AppStorage("autoRecordSelectedChannels") private var autoRecordSelectedChannelsJSON = "[]"
    @AppStorage("autoRecordBlockedChannels") private var autoRecordBlockedChannelsJSON = "[]"
    @State private var autoRecordSelectedChannels: Set<String> = []
    @State private var autoRecordBlockedChannels: Set<String> = []
    @State private var selectedChannelInput = ""
    @State private var blockedChannelInput = ""
    @State private var selectedChannelInputError: String?
    @State private var blockedChannelInputError: String?
    @State private var hasLoadedSelectedChannels = false
    @State private var showChannelSelector = false
    @State private var showBlocklistSelector = false
    @State private var pendingBackgroundAction: BackgroundControlAction?
    @State private var lastRestartAgentStatus: RestartAgentStatus?
    @State private var retentionRunStatus: String?
    @State private var isRunningBackgroundAction = false
    @State private var backgroundActionStatus: String?
    var onOpenTwitchSettings: (() -> Void)?
    var onActionFeedback: ((String, String) -> Void)?

    private var resolvedAutoRecordMode: AutoRecordMode {
        get {
            if let mode = AutoRecordMode(rawValue: autoRecordModeRaw) {
                return mode
            }
            return autoRecordPinnedOnly ? .onlyPinned : .pinnedAndFollowed
        }
        nonmutating set {
            autoRecordModeRaw = newValue.rawValue
            autoRecordPinnedOnly = (newValue == .onlyPinned)
        }
    }

    private var shouldShowRecordingSettings: Bool {
        true
    }

    private var videoAspectMode: VideoAspectCropMode {
        VideoAspectCropMode(rawValue: videoAspectModeRaw) ?? .source
    }

    @State private var expandedSections: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(sidebarTintBinding.wrappedValue.opacity(0.15))
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)

                        Text("Customize your Glitcho experience")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 8)

                VStack(spacing: 14) {
                    CollapsibleSettingsCard(
                        id: "appearance",
                        icon: "paintpalette.fill",
                        iconColor: .white,
                        iconBackgroundColor: sidebarTintBinding.wrappedValue,
                        title: "Appearance",
                        subtitle: "Customize the sidebar tint",
                        isExpanded: expandedSections.contains("appearance"),
                        onToggle: { toggleSection("appearance") }
                    ) {
                        HStack(spacing: 12) {
                            ColorPicker("Sidebar tint", selection: sidebarTintBinding, supportsOpacity: false)
                                .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sidebar tint")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                Text(sidebarTintHex.uppercased())
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer()

                            SettingsButton(
                                title: "Reset",
                                systemImage: "arrow.counterclockwise",
                                style: .secondary,
                                action: { sidebarTintHex = SidebarTint.defaultHex }
                            )
                        }
                        .padding(.vertical, 4)
                    }

                    CollapsibleSettingsCard(
                        id: "notifications",
                        icon: "bell.badge.fill",
                        iconColor: .white,
                        iconBackgroundColor: sidebarTintBinding.wrappedValue,
                        title: "Notifications",
                        subtitle: "Control how Glitcho alerts you",
                        isExpanded: expandedSections.contains("notifications"),
                        onToggle: { toggleSection("notifications") }
                    ) {
                        SettingsToggleRow(
                            title: "Live alerts",
                            detail: "Show a notification when followed channels go live.",
                            isOn: $liveAlertsEnabled,
                            accentColor: sidebarTintBinding.wrappedValue
                        )

                        SettingsToggleRow(
                            title: "Favorites only",
                            detail: "Only notify for pinned channels with the bell enabled.",
                            isOn: $liveAlertsPinnedOnly,
                            accentColor: sidebarTintBinding.wrappedValue
                        )
                        .disabled(!liveAlertsEnabled)
                        .opacity(liveAlertsEnabled ? 1 : 0.5)

                        HStack(spacing: 10) {
                            SettingsButton(
                                title: "Test",
                                systemImage: "bell.badge.fill",
                                style: .primary,
                                action: testNotification
                            )
                            .disabled(notificationManager == nil || !liveAlertsEnabled)

                            if let testStatus {
                                Text(testStatus.message)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(testStatus.color)
                                    .lineLimit(2)
                            }

                            Spacer()
                        }
                        .padding(.top, 4)
                    }

                    CollapsibleSettingsCard(
                        id: "permissions",
                        icon: "lock.shield.fill",
                        iconColor: .white,
                        iconBackgroundColor: sidebarTintBinding.wrappedValue,
                        title: "System Permissions",
                        subtitle: "Allow notifications in macOS",
                        isExpanded: expandedSections.contains("permissions"),
                        onToggle: { toggleSection("permissions") }
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            permissionRow(
                                icon: "bell.badge.fill",
                                title: "Allow notifications",
                                detail: "System Settings > Notifications"
                            )
                            permissionRow(
                                icon: "rectangle.badge.plus",
                                title: "Enable banners",
                                detail: "For instant live alerts"
                            )
                        }

                        HStack {
                            Spacer()
                            SettingsButton(
                                title: "Open System Settings",
                                systemImage: "gear",
                                style: .secondary,
                                action: openNotificationSettings
                            )
                        }
                        .padding(.top, 4)
                    }

                    if shouldShowRecordingSettings {
                        CollapsibleSettingsCard(
                            id: "recording-tools",
                            icon: "terminal.fill",
                            iconColor: .white,
                            iconBackgroundColor: sidebarTintBinding.wrappedValue,
                            title: "Recording Tools",
                            subtitle: "Configure Streamlink and FFmpeg binaries",
                            isExpanded: expandedSections.contains("recording-tools"),
                            onToggle: { toggleSection("recording-tools") }
                        ) {
                            settingsValueRow(
                                title: "Streamlink binary",
                                value: streamlinkPath.isEmpty ? "Auto-detect (Homebrew or downloaded)" : streamlinkPath
                            )

                            HStack {
                                SettingsButton(
                                    title: "Choose Streamlink",
                                    systemImage: "terminal",
                                    style: .secondary,
                                    action: selectStreamlinkBinary
                                )
                                Spacer()
                            }

                            if recordingManager.isInstalling {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text(recordingManager.installStatus ?? "Installing Streamlink…")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.7))
                                    Spacer()
                                }
                            }

                            HStack {
                                SettingsButton(
                                    title: recordingManager.isInstalling ? "Installing…" : "Install Streamlink",
                                    systemImage: "arrow.down.circle",
                                    style: .primary,
                                    action: {
                                        Task { await recordingManager.installStreamlink() }
                                    }
                                )
                                .disabled(recordingManager.isInstalling)
                                Spacer()
                            }

                            if !recordingManager.isInstalling, let status = recordingManager.installStatus {
                                let lower = status.lowercased()
                                let isSuccess = lower.contains("installed") || lower.contains("available")
                                Text(status)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(isSuccess ? Color.green.opacity(0.8) : Color.white.opacity(0.6))
                                    .lineLimit(2)
                            }

                            if let installError = recordingManager.installError {
                                Text(installError)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.orange.opacity(0.85))
                                    .lineLimit(2)
                            }

                            Divider()
                                .padding(.vertical, 4)

                            settingsValueRow(
                                title: "FFmpeg binary (optional)",
                                value: ffmpegPath.isEmpty ? "Auto-detect (ffmpeg in PATH)" : ffmpegPath
                            )

                            HStack {
                                SettingsButton(
                                    title: "Choose FFmpeg",
                                    systemImage: "terminal",
                                    style: .secondary,
                                    action: selectFFmpegBinary
                                )
                                Spacer()
                            }

                            if recordingManager.isInstallingFFmpeg {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text(recordingManager.ffmpegInstallStatus ?? "Installing FFmpeg…")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.7))
                                    Spacer()
                                }
                            }

                            HStack {
                                SettingsButton(
                                    title: recordingManager.isInstallingFFmpeg ? "Installing…" : "Install FFmpeg",
                                    systemImage: "arrow.down.circle",
                                    style: .primary,
                                    action: {
                                        Task { await recordingManager.installFFmpeg() }
                                    }
                                )
                                .disabled(recordingManager.isInstallingFFmpeg)
                                Spacer()
                            }

                            if !recordingManager.isInstallingFFmpeg, let status = recordingManager.ffmpegInstallStatus {
                                let lower = status.lowercased()
                                let isSuccess = lower.contains("installed") || lower.contains("available")
                                Text(status)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(isSuccess ? Color.green.opacity(0.8) : Color.white.opacity(0.6))
                                    .lineLimit(2)
                            }

                            if let installError = recordingManager.ffmpegInstallError {
                                Text(installError)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.orange.opacity(0.85))
                                    .lineLimit(2)
                            }
                        }
                    }

                    if shouldShowRecordingSettings {
                        CollapsibleSettingsCard(
                            id: "video-enhancement",
                            icon: "sparkles.tv.fill",
                            iconColor: .green,
                            title: "Video Enhancement (Pro)",
                            subtitle: "Tune playback quality features from settings",
                            isExpanded: expandedSections.contains("video-enhancement"),
                            onToggle: { toggleSection("video-enhancement") }
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                SettingsToggleRow(
                                    title: "Motion smoothening (\(motionCapability.targetRefreshRate)Hz)",
                                    detail: "AI interpolation for smoother movement when supported.",
                                    isOn: $motionSmoothening120Enabled
                                )
                                .disabled(!motionCapability.supported)
                                .opacity(motionCapability.supported ? 1 : 0.5)

                                if !motionCapability.supported {
                                    Text("Unavailable on this device now: \(motionCapability.reason)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.orange.opacity(0.85))
                                }

                                SettingsToggleRow(
                                    title: "4K Upscaler",
                                    detail: "Upscale stream frames toward 4K output using local hardware.",
                                    isOn: $videoUpscaler4KEnabled
                                )

                                SettingsToggleRow(
                                    title: "Image Optimize",
                                    detail: "Reduce compression artifacts and improve sharpness/colors for low-quality streams.",
                                    isOn: $videoImageOptimizeEnabled
                                )

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Image optimize tuning")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.9))

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Contrast")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.75))
                                            Spacer()
                                            Text(String(format: "%.2f", imageOptimizeContrast))
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.65))
                                        }
                                        Slider(value: $imageOptimizeContrast, in: 0.8...1.5, step: 0.01)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Lighting")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.75))
                                            Spacer()
                                            Text(String(format: "%.3f", imageOptimizeLighting))
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.65))
                                        }
                                        Slider(value: $imageOptimizeLighting, in: -0.15...0.15, step: 0.005)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Denoiser")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.75))
                                            Spacer()
                                            Text(String(format: "%.2f", imageOptimizeDenoiser))
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.65))
                                        }
                                        Slider(value: $imageOptimizeDenoiser, in: 0...1, step: 0.01)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Neural clarity")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.75))
                                            Spacer()
                                            Text(String(format: "%.2f", imageOptimizeNeuralClarity))
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.65))
                                        }
                                        Slider(value: $imageOptimizeNeuralClarity, in: 0...1, step: 0.01)
                                    }
                                }

                                Divider()
                                    .padding(.vertical, 4)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Aspect crop mode")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.9))
                                    Picker("Aspect crop mode", selection: $videoAspectModeRaw) {
                                        ForEach(VideoAspectCropMode.allCases, id: \.self) { mode in
                                            Text(mode.label).tag(mode.rawValue)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(.white)

                                    Text("Current mode: \(videoAspectMode.label)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }

                        CollapsibleSettingsCard(
                            id: "companion",
                            icon: "network.badge.shield.half.filled",
                            iconColor: .white,
                            iconBackgroundColor: sidebarTintBinding.wrappedValue,
                            title: "Companion API",
                            subtitle: "Remote control endpoint for companion clients",
                            isExpanded: expandedSections.contains("companion"),
                            onToggle: { toggleSection("companion") }
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                SettingsToggleRow(
                                    title: "Enable companion API",
                                    detail: "Expose local HTTP control API for remote clients.",
                                    isOn: $companionAPIEnabled,
                                    accentColor: sidebarTintBinding.wrappedValue
                                )

                                HStack {
                                    Text("Port")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Stepper(value: $companionAPIPort, in: 1024...65535) {
                                        Text("\(companionAPIPort)")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.75))
                                    }
                                    .frame(width: 180)
                                }
                                .disabled(!companionAPIEnabled)
                                .opacity(companionAPIEnabled ? 1 : 0.5)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Auth token (optional)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                    SecureField("Bearer token", text: $companionAPIToken)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .disabled(!companionAPIEnabled)
                                .opacity(companionAPIEnabled ? 1 : 0.5)

                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(companionAPIServer.isRunning ? Color.green : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text(companionAPIServer.isRunning ? "Companion API running" : "Companion API stopped")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.7))
                                }

                                if !companionAPIServer.endpoint.isEmpty {
                                    Text("Endpoint: \(companionAPIServer.endpoint)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .textSelection(.enabled)
                                }

                                if !companionAPIServer.lastRequestSummary.isEmpty {
                                    Text("Last request: \(companionAPIServer.lastRequestSummary)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.55))
                                }

                                if let error = companionAPIServer.lastError, !error.isEmpty {
                                    Text(error)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.orange.opacity(0.9))
                                        .lineLimit(2)
                                }
                            }
                        }

                        CollapsibleSettingsCard(
                            id: "recording",
                            icon: "record.circle",
                            iconColor: .white,
                            iconBackgroundColor: sidebarTintBinding.wrappedValue,
                            title: "Recording",
                            subtitle: "Capture live streams with Streamlink",
                            isExpanded: expandedSections.contains("recording"),
                            onToggle: { toggleSection("recording") }
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                            SettingsToggleRow(
                                title: "Auto-record when live",
                                detail: "Start recording followed channels as soon as they go live.",
                                isOn: $autoRecordOnLive,
                                accentColor: sidebarTintBinding.wrappedValue
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Recording scope")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                Picker(
                                    "Recording scope",
                                    selection: Binding(
                                        get: { resolvedAutoRecordMode },
                                        set: { resolvedAutoRecordMode = $0 }
                                    )
                                ) {
                                    ForEach(AutoRecordMode.allCases, id: \.self) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.white)
                            }
                            .disabled(!autoRecordOnLive)
                            .opacity(autoRecordOnLive ? 1 : 0.5)
                            
                            if resolvedAutoRecordMode == .customAllowlist && autoRecordOnLive {
                                Divider()
                                    .padding(.vertical, 4)

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Selected channels")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.white)
                                            Text("Choose followed channels or add logins manually.")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white.opacity(0.5))
                                        }
                                        Spacer()
                                        Button(action: { showChannelSelector.toggle() }) {
                                            Image(systemName: showChannelSelector ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.6))
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    HStack(spacing: 8) {
                                        TextField("Add channel login", text: $selectedChannelInput)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(Color.white.opacity(0.08))
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            .onSubmit {
                                                addManualSelectedChannel()
                                            }
                                        Button("Add") {
                                            addManualSelectedChannel()
                                        }
                                        .font(.system(size: 10, weight: .semibold))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.white.opacity(0.8))
                                    }

                                    if let selectedChannelInputError {
                                        Text(selectedChannelInputError)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.orange.opacity(0.85))
                                    }

                                    if showChannelSelector, !store.followedChannelLogins.isEmpty {
                                        VStack(spacing: 6) {
                                            HStack {
                                                Button("Select All Followed") {
                                                    autoRecordSelectedChannels.formUnion(store.followedChannelLogins.map { $0.lowercased() })
                                                    saveSelectedChannels()
                                                }
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.7))
                                                .buttonStyle(.plain)

                                                Button("Clear All") {
                                                    autoRecordSelectedChannels = []
                                                    saveSelectedChannels()
                                                }
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.7))
                                                .buttonStyle(.plain)

                                                Spacer()
                                            }
                                            .padding(.bottom, 4)

                                            ScrollView {
                                                VStack(spacing: 4) {
                                                    ForEach(store.followedChannelLogins.sorted(), id: \.self) { login in
                                                        HStack {
                                                            Toggle(isOn: Binding(
                                                                get: { autoRecordSelectedChannels.contains(login) },
                                                                set: { isSelected in
                                                                    if isSelected {
                                                                        autoRecordSelectedChannels.insert(login)
                                                                    } else {
                                                                        autoRecordSelectedChannels.remove(login)
                                                                    }
                                                                    saveSelectedChannels()
                                                                }
                                                            )) {
                                                                Text(login)
                                                                    .font(.system(size: 11))
                                                                    .foregroundStyle(.white.opacity(0.9))
                                                            }
                                                            .toggleStyle(.checkbox)
                                                        }
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(Color.white.opacity(0.03))
                                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                                    }
                                                }
                                            }
                                            .frame(maxHeight: 160)
                                        }
                                    }

                                    if autoRecordSelectedChannels.isEmpty {
                                        Text("No channels selected. Add channels manually or from followed list.")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.6))
                                    } else {
                                        VStack(spacing: 4) {
                                            ForEach(autoRecordSelectedChannels.sorted(), id: \.self) { login in
                                                HStack {
                                                    Text(login)
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundStyle(.white.opacity(0.85))
                                                    Spacer()
                                                    Button {
                                                        autoRecordSelectedChannels.remove(login)
                                                        saveSelectedChannels()
                                                    } label: {
                                                        Image(systemName: "xmark.circle.fill")
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(.white.opacity(0.45))
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.white.opacity(0.03))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }

                            if autoRecordOnLive {
                                Divider()
                                    .padding(.vertical, 4)

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Blocked channels")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.white)
                                            Text("Blocklist overrides all recording modes")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white.opacity(0.5))
                                        }
                                        Spacer()
                                        Button(action: { showBlocklistSelector.toggle() }) {
                                            Image(systemName: showBlocklistSelector ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.6))
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    HStack(spacing: 8) {
                                        TextField("Block channel login", text: $blockedChannelInput)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(Color.white.opacity(0.08))
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            .onSubmit {
                                                addManualBlockedChannel()
                                            }
                                        Button("Block") {
                                            addManualBlockedChannel()
                                        }
                                        .font(.system(size: 10, weight: .semibold))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.white.opacity(0.8))
                                    }

                                    if let blockedChannelInputError {
                                        Text(blockedChannelInputError)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.orange.opacity(0.85))
                                    }

                                    if showBlocklistSelector, !store.followedChannelLogins.isEmpty {
                                        ScrollView {
                                            VStack(spacing: 4) {
                                                ForEach(store.followedChannelLogins.sorted(), id: \.self) { login in
                                                    HStack {
                                                        Toggle(isOn: Binding(
                                                            get: { autoRecordBlockedChannels.contains(login) },
                                                            set: { isBlocked in
                                                                if isBlocked {
                                                                    autoRecordBlockedChannels.insert(login)
                                                                } else {
                                                                    autoRecordBlockedChannels.remove(login)
                                                                }
                                                                saveBlockedChannels()
                                                            }
                                                        )) {
                                                            Text(login)
                                                                .font(.system(size: 11))
                                                                .foregroundStyle(.white.opacity(0.9))
                                                        }
                                                        .toggleStyle(.checkbox)
                                                    }
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.white.opacity(0.03))
                                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                                }
                                            }
                                        }
                                        .frame(maxHeight: 140)
                                    }

                                    if autoRecordBlockedChannels.isEmpty {
                                        Text("No blocked channels.")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.6))
                                    } else {
                                        VStack(spacing: 4) {
                                            ForEach(autoRecordBlockedChannels.sorted(), id: \.self) { login in
                                                HStack {
                                                    Text(login)
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundStyle(.white.opacity(0.85))
                                                    Spacer()
                                                    Button {
                                                        autoRecordBlockedChannels.remove(login)
                                                        saveBlockedChannels()
                                                    } label: {
                                                        Image(systemName: "xmark.circle.fill")
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(.white.opacity(0.45))
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.white.opacity(0.03))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }

                            Divider()
                                .padding(.vertical, 4)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Orchestration")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)

                                Stepper(value: $recordingConcurrencyLimit, in: 1...12) {
                                    Text("Max concurrent recordings: \(recordingConcurrencyLimit)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.75))
                                }

                                Stepper(value: $autoRecordDebounceSeconds, in: 0...20) {
                                    Text("Live event debounce: \(autoRecordDebounceSeconds)s")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.75))
                                }

                                Stepper(value: $autoRecordCooldownSeconds, in: 0...300, step: 5) {
                                    Text(autoRecordCooldownSeconds == 0 ? "Per-channel cooldown: Disabled" : "Per-channel cooldown: \(autoRecordCooldownSeconds)s")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                            }

                            Divider()
                                .padding(.vertical, 4)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Retention policy")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)

                                Stepper(value: $recordingsRetentionMaxAgeDays, in: 0...365) {
                                    Text(recordingsRetentionMaxAgeDays == 0 ? "Delete older than: Disabled" : "Delete older than: \(recordingsRetentionMaxAgeDays) day(s)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.75))
                                }

                                Stepper(value: $recordingsRetentionKeepLastGlobal, in: 0...200) {
                                    Text(recordingsRetentionKeepLastGlobal == 0 ? "Keep last (global): Disabled" : "Keep last (global): \(recordingsRetentionKeepLastGlobal)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.75))
                                }

                                Stepper(value: $recordingsRetentionKeepLastPerChannel, in: 0...100) {
                                    Text(recordingsRetentionKeepLastPerChannel == 0 ? "Keep last per channel: Disabled" : "Keep last per channel: \(recordingsRetentionKeepLastPerChannel)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.75))
                                }

                                HStack {
                                    SettingsButton(
                                        title: "Run retention now",
                                        systemImage: "trash.slash",
                                        style: .secondary,
                                        action: runRetentionNow
                                    )
                                    Spacer()
                                }

                                if let retentionRunStatus {
                                    Text(retentionRunStatus)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .lineLimit(2)
                                }
                            }

                            settingsValueRow(
                                title: "Recordings folder",
                                value: recordingsDirectory.isEmpty ? "Default (Downloads/Glitcho Recordings)" : recordingsDirectory
                            )

                            HStack {
                                SettingsButton(
                                    title: "Choose Folder",
                                    systemImage: "folder",
                                    style: .secondary,
                                    action: selectRecordingsFolder
                                )
                                Spacer()
                            }

                            Divider()
                                .padding(.vertical, 8)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Background Recorder")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                Text("Manage the background recording agent")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            
                            HStack(spacing: 10) {
                                SettingsButton(
                                    title: "Restart Agent",
                                    systemImage: "arrow.clockwise",
                                    style: .secondary,
                                    action: {
                                        pendingBackgroundAction = .restartAgent
                                    }
                                )
                                .disabled(isRunningBackgroundAction)
                                
                                SettingsButton(
                                    title: "Stop All Recordings",
                                    systemImage: "stop.circle",
                                    style: .secondary,
                                    action: {
                                        pendingBackgroundAction = .stopAllRecordings
                                    }
                                )
                                .disabled(isRunningBackgroundAction)
                                
                                Spacer()
                            }

                            if isRunningBackgroundAction {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text(backgroundActionStatus ?? "Applying background recorder action…")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.7))
                                    Spacer()
                                }
                            } else if let backgroundActionStatus {
                                Text(backgroundActionStatus)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(2)
                            }

                            if let status = lastRestartAgentStatus {
                                Text("Last restart: \(Self.restartTimestampFormatter.string(from: status.timestamp)) • \(status.result)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(status.isSuccess ? Color.green.opacity(0.85) : Color.orange.opacity(0.85))
                                    .lineLimit(2)
                            } else {
                                Text("Last restart: Never")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.07))
        .onAppear {
            loadSelectedChannelsIfNeeded()
            loadBlockedChannelsIfNeeded()
            motionCapability = MotionSmootheningCapability.evaluate(screen: NSScreen.main)
            sanitizeProVideoEnhancementState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            motionCapability = MotionSmootheningCapability.evaluate(screen: NSScreen.main)
        }
        .onChange(of: motionSmoothening120Enabled) { enabled in
            if enabled && !motionCapability.supported {
                motionSmoothening120Enabled = false
                return
            }
            GlitchoTelemetry.track(
                "settings_motion_smoothening_toggle",
                metadata: [
                    "enabled": enabled ? "true" : "false",
                    "supported": motionCapability.supported ? "true" : "false"
                ]
            )
        }
        .onChange(of: videoUpscaler4KEnabled) { enabled in
            GlitchoTelemetry.track(
                "settings_video_upscaler_4k_toggle",
                metadata: [
                    "enabled": enabled ? "true" : "false"
                ]
            )
        }
        .onChange(of: videoImageOptimizeEnabled) { enabled in
            GlitchoTelemetry.track(
                "settings_video_image_optimize_toggle",
                metadata: [
                    "enabled": enabled ? "true" : "false"
                ]
            )
        }
        .onChange(of: imageOptimizeContrast) { _ in
            trackImageOptimizeTuningChange(trigger: "contrast")
        }
        .onChange(of: imageOptimizeLighting) { _ in
            trackImageOptimizeTuningChange(trigger: "lighting")
        }
        .onChange(of: imageOptimizeDenoiser) { _ in
            trackImageOptimizeTuningChange(trigger: "denoiser")
        }
        .onChange(of: imageOptimizeNeuralClarity) { _ in
            trackImageOptimizeTuningChange(trigger: "neural_clarity")
        }
        .onChange(of: videoAspectModeRaw) { raw in
            if VideoAspectCropMode(rawValue: raw) == nil {
                videoAspectModeRaw = VideoAspectCropMode.source.rawValue
                return
            }
            GlitchoTelemetry.track(
                "settings_video_aspect_mode_changed",
                metadata: ["mode": videoAspectMode.rawValue]
            )
        }
        .confirmationDialog(
            pendingBackgroundAction?.confirmationTitle ?? "Confirm Action",
            isPresented: Binding(
                get: { pendingBackgroundAction != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingBackgroundAction = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingBackgroundAction {
                switch action {
                case .restartAgent:
                    Button("Restart Agent") {
                        restartBackgroundAgent()
                        pendingBackgroundAction = nil
                    }
                case .stopAllRecordings:
                    Button("Stop All Recordings", role: .destructive) {
                        stopAllRecordings()
                        pendingBackgroundAction = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingBackgroundAction = nil
            }
        } message: {
            if let action = pendingBackgroundAction {
                switch action {
                case .restartAgent:
                    Text("Restarting reloads the background recorder immediately.")
                case .stopAllRecordings:
                    Text("This will stop the background agent and clear all manual recording sessions.")
                }
            }
        }
    }

    private func toggleSection(_ id: String) {
        if expandedSections.contains(id) {
            expandedSections.remove(id)
        } else {
            expandedSections.insert(id)
        }
    }

    private var sidebarTintBinding: Binding<Color> {
        Binding(
            get: { SidebarTint.color(from: sidebarTintHex) },
            set: { newValue in
                sidebarTintHex = newValue.toHex() ?? SidebarTint.defaultHex
            }
        )
    }

    private static let restartTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func sanitizeProVideoEnhancementState() {
        if VideoAspectCropMode(rawValue: videoAspectModeRaw) == nil {
            videoAspectModeRaw = VideoAspectCropMode.source.rawValue
        }
        if motionSmoothening120Enabled && !motionCapability.supported {
            motionSmoothening120Enabled = false
        }
        sanitizeImageOptimizeTuning()
    }

    private func sanitizeImageOptimizeTuning() {
        let clamped = ImageOptimizationConfiguration(
            contrast: imageOptimizeContrast,
            lighting: imageOptimizeLighting,
            denoiser: imageOptimizeDenoiser,
            neuralClarity: imageOptimizeNeuralClarity
        ).clamped
        imageOptimizeContrast = clamped.contrast
        imageOptimizeLighting = clamped.lighting
        imageOptimizeDenoiser = clamped.denoiser
        imageOptimizeNeuralClarity = clamped.neuralClarity
    }

    private func trackImageOptimizeTuningChange(trigger: String) {
        sanitizeImageOptimizeTuning()
        GlitchoTelemetry.track(
            "settings_video_image_optimize_tuning_changed",
            metadata: [
                "trigger": trigger,
                "contrast": String(format: "%.2f", imageOptimizeContrast),
                "lighting": String(format: "%.3f", imageOptimizeLighting),
                "denoiser": String(format: "%.2f", imageOptimizeDenoiser),
                "neural_clarity": String(format: "%.2f", imageOptimizeNeuralClarity),
            ]
        )
    }

    private func restartBackgroundAgent() {
        guard !isRunningBackgroundAction else { return }
        GlitchoTelemetry.track("background_agent_restart_requested")
        isRunningBackgroundAction = true
        backgroundActionStatus = "Restarting background recorder…"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = backgroundAgentManager.restartAgent()
            DispatchQueue.main.async {
                isRunningBackgroundAction = false
                backgroundActionStatus = result.message
                lastRestartAgentStatus = RestartAgentStatus(
                    timestamp: result.finishedAt,
                    result: result.message,
                    isSuccess: result.success
                )
                GlitchoTelemetry.track(
                    "background_agent_restart_result",
                    metadata: [
                        "success": result.success ? "true" : "false",
                        "stopped": "\(result.stoppedProcessCount)"
                    ]
                )
                onActionFeedback?(
                    result.message,
                    result.success ? "arrow.clockwise.circle.fill" : "exclamationmark.triangle.fill"
                )
            }
        }
    }

    private func stopAllRecordings() {
        guard !isRunningBackgroundAction else { return }
        GlitchoTelemetry.track("background_agent_stop_all_requested")
        isRunningBackgroundAction = true
        backgroundActionStatus = "Stopping all recordings…"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = backgroundAgentManager.killAgent()
            DispatchQueue.main.async {
                isRunningBackgroundAction = false
                backgroundActionStatus = result.message
                GlitchoTelemetry.track(
                    "background_agent_stop_all_result",
                    metadata: [
                        "success": result.success ? "true" : "false",
                        "stopped": "\(result.stoppedProcessCount)"
                    ]
                )
                onActionFeedback?(
                    result.message,
                    result.success ? "stop.circle.fill" : "exclamationmark.triangle.fill"
                )
            }
        }
    }

    private func runRetentionNow() {
        let result = recordingManager.enforceRetentionPoliciesNow()
        retentionRunStatus = "Retention run: deleted \(result.deletedCount), failed \(result.failedCount)."
    }

    private func testNotification() {
        clearTask?.cancel()
        clearTask = nil

        let channel = TwitchChannel(
            id: "glitcho-test",
            name: "Glitcho Test",
            url: URL(string: "https://www.twitch.tv")!,
            thumbnailURL: nil
        )

        guard let notificationManager else {
            setTestStatus(.unavailable)
            return
        }

        Task {
            let allowed = await notificationManager.requestAuthorization()
            if !allowed {
                await MainActor.run {
                    setTestStatus(.denied)
                }
                return
            }

            await notificationManager.notifyChannelLive(channel)
            await MainActor.run {
                setTestStatus(.sent)
            }
        }
    }

    private func setTestStatus(_ status: NotificationTestStatus) {
        testStatus = status
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            testStatus = nil
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func selectRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            recordingsDirectory = url.path
        }
    }

    private func selectStreamlinkBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            streamlinkPath = url.path
        }
    }

    private func loadSelectedChannelsIfNeeded() {
        guard !hasLoadedSelectedChannels else { return }
        hasLoadedSelectedChannels = true
        
        guard let data = autoRecordSelectedChannelsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        autoRecordSelectedChannels = Set(decoded.map { $0.lowercased() })
    }
    
    private func saveSelectedChannels() {
        let array = Array(autoRecordSelectedChannels).sorted()
        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        autoRecordSelectedChannelsJSON = json
    }

    private func loadBlockedChannelsIfNeeded() {
        guard let data = autoRecordBlockedChannelsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            autoRecordBlockedChannels = []
            return
        }
        autoRecordBlockedChannels = Set(decoded.map { $0.lowercased() })
    }

    private func saveBlockedChannels() {
        let array = Array(autoRecordBlockedChannels).sorted()
        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        autoRecordBlockedChannelsJSON = json
    }

    private func addManualSelectedChannel() {
        guard let login = normalizeChannelLogin(selectedChannelInput) else {
            selectedChannelInputError = "Enter a valid channel login or Twitch URL."
            return
        }
        selectedChannelInputError = nil
        selectedChannelInput = ""
        autoRecordSelectedChannels.insert(login)
        saveSelectedChannels()
    }

    private func addManualBlockedChannel() {
        guard let login = normalizeChannelLogin(blockedChannelInput) else {
            blockedChannelInputError = "Enter a valid channel login or Twitch URL."
            return
        }
        blockedChannelInputError = nil
        blockedChannelInput = ""
        autoRecordBlockedChannels.insert(login)
        saveBlockedChannels()
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
    
    private func selectFFmpegBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            ffmpegPath = url.path
        }
    }

    private func permissionRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func settingsValueRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
        }
    }
}

struct SettingsModal: View {
    let onClose: () -> Void
    let recordingManager: RecordingManager
    var onOpenTwitchSettings: (() -> Void)?

    var body: some View {
        ZStack {
            // Backdrop that blocks all interaction
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { }  // Absorb taps, don't close

            // Centered settings panel
            SettingsView(recordingManager: recordingManager, onClose: onClose, onOpenTwitchSettings: onOpenTwitchSettings)
                .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 20)
        }
    }
}

struct SettingsView: View {
    @AppStorage("liveAlertsEnabled") private var liveAlertsEnabled = true
    @AppStorage("liveAlertsPinnedOnly") private var liveAlertsPinnedOnly = false
    @AppStorage(SidebarTint.storageKey) private var sidebarTintHex = SidebarTint.defaultHex
    @AppStorage("recordingsDirectory") private var recordingsDirectory = ""
    @AppStorage("streamlinkPath") private var streamlinkPath = ""
    @AppStorage("ffmpegPath") private var ffmpegPath = ""
    @AppStorage("autoRecordOnLive") private var autoRecordOnLive = false
    @AppStorage("autoRecordPinnedOnly") private var autoRecordPinnedOnly = false
    @Environment(\.notificationManager) private var notificationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var testStatus: NotificationTestStatus?
    @State private var clearTask: Task<Void, Never>?

    @ObservedObject var recordingManager: RecordingManager = RecordingManager()
    var onClose: (() -> Void)?
    var onOpenTwitchSettings: (() -> Void)?

    var body: some View {
        SettingsViewContent(
            liveAlertsEnabled: $liveAlertsEnabled,
            liveAlertsPinnedOnly: $liveAlertsPinnedOnly,
            sidebarTintHex: $sidebarTintHex,
            testStatus: $testStatus,
            testAction: testNotification,
            openSettingsAction: openNotificationSettings,
            openTwitchSettingsAction: {
                if let onOpenTwitchSettings {
                    onOpenTwitchSettings()
                } else {
                    openTwitchSettings()
                }
            },
            recordingsDirectory: $recordingsDirectory,
            streamlinkPath: $streamlinkPath,
            ffmpegPath: $ffmpegPath,
            autoRecordOnLive: $autoRecordOnLive,
            autoRecordPinnedOnly: $autoRecordPinnedOnly,
            selectRecordingsFolder: selectRecordingsFolder,
            selectStreamlinkBinary: selectStreamlinkBinary,
            selectFFmpegBinary: selectFFmpegBinary,
            recordingManager: recordingManager,
            showRecordingSettings: true,
            isNotificationManagerAvailable: notificationManager != nil,
            onClose: { (onClose ?? { dismiss() })() }
        )
    }

    private func testNotification() {
        clearTask?.cancel()
        clearTask = nil

        let channel = TwitchChannel(
            id: "glitcho-test",
            name: "Glitcho Test",
            url: URL(string: "https://www.twitch.tv")!,
            thumbnailURL: nil
        )

        guard let notificationManager else {
            setTestStatus(.unavailable)
            return
        }

        Task {
            let allowed = await notificationManager.requestAuthorization()
            if !allowed {
                await MainActor.run {
                    setTestStatus(.denied)
                }
                return
            }

            await notificationManager.notifyChannelLive(channel)
            await MainActor.run {
                setTestStatus(.sent)
            }
        }
    }

    private func setTestStatus(_ status: NotificationTestStatus) {
        testStatus = status
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            testStatus = nil
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func openTwitchSettings() {
        openURL(URL(string: "https://www.twitch.tv/settings")!)
    }

    private func selectRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            recordingsDirectory = url.path
        }
    }

    private func selectStreamlinkBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            streamlinkPath = url.path
        }
    }

    private func selectFFmpegBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            ffmpegPath = url.path
        }
    }
}

enum NotificationTestStatus {
    case sent
    case denied
    case unavailable

    var message: String {
        switch self {
        case .sent:
            return "Test notification sent."
        case .denied:
            return "Notifications are disabled. Enable them in System Settings > Notifications > Glitcho."
        case .unavailable:
            return "Notifications are temporarily unavailable. Please restart Glitcho."
        }
    }

    var color: Color {
        switch self {
        case .sent:
            return Color.green.opacity(0.8)
        case .denied:
            return Color.orange.opacity(0.85)
        case .unavailable:
            return Color.orange.opacity(0.85)
        }
    }
}

struct SettingsViewContent: View {
    @Binding var liveAlertsEnabled: Bool
    @Binding var liveAlertsPinnedOnly: Bool
    @Binding var sidebarTintHex: String
    @Binding var testStatus: NotificationTestStatus?
    let testAction: () -> Void
    let openSettingsAction: () -> Void
    let openTwitchSettingsAction: () -> Void
    @Binding var recordingsDirectory: String
    @Binding var streamlinkPath: String
    @Binding var ffmpegPath: String
    @Binding var autoRecordOnLive: Bool
    @Binding var autoRecordPinnedOnly: Bool
    let selectRecordingsFolder: () -> Void
    let selectStreamlinkBinary: () -> Void
    let selectFFmpegBinary: () -> Void
    @ObservedObject var recordingManager: RecordingManager
    let showRecordingSettings: Bool
    let isNotificationManagerAvailable: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    SettingsCard(
                        icon: "paintpalette.fill",
                        iconColor: Color(red: 0.53, green: 0.42, blue: 0.95),
                        title: "Appearance",
                        subtitle: "Customize the sidebar tint"
                    ) {
                        HStack(spacing: 12) {
                            ColorPicker("Sidebar tint", selection: sidebarTintBinding, supportsOpacity: false)
                                .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sidebar tint")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                Text(sidebarTintHex.uppercased())
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer()

                            SettingsButton(
                                title: "Reset",
                                systemImage: "arrow.counterclockwise",
                                style: .secondary,
                                action: { sidebarTintHex = SidebarTint.defaultHex }
                            )
                        }
                        .padding(.vertical, 4)
                    }

                    // Notifications Card
                    SettingsCard(
                        icon: "bell.badge.fill",
                        iconColor: .purple,
                        title: "Notifications",
                        subtitle: "Control how Glitcho alerts you"
                    ) {
                        SettingsToggleRow(
                            title: "Live alerts",
                            detail: "Show a notification when followed channels go live.",
                            isOn: $liveAlertsEnabled
                        )

                        SettingsToggleRow(
                            title: "Favorites only",
                            detail: "Only notify for pinned channels with the bell enabled.",
                            isOn: $liveAlertsPinnedOnly
                        )
                        .disabled(!liveAlertsEnabled)
                        .opacity(liveAlertsEnabled ? 1 : 0.5)

                        HStack(spacing: 10) {
                            SettingsButton(
                                title: "Test",
                                systemImage: "bell.badge.fill",
                                style: .primary,
                                action: testAction
                            )
                            .disabled(!isNotificationManagerAvailable || !liveAlertsEnabled)

                            if let testStatus {
                                Text(testStatus.message)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(testStatus.color)
                                    .lineLimit(2)
                            }

                            Spacer()
                        }
                        .padding(.top, 4)
                    }

                    // System Permissions Card
                    SettingsCard(
                        icon: "lock.shield.fill",
                        iconColor: .blue,
                        title: "System Permissions",
                        subtitle: "Allow notifications in macOS"
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            permissionRow(
                                icon: "bell.badge.fill",
                                title: "Allow notifications",
                                detail: "System Settings > Notifications"
                            )
                            permissionRow(
                                icon: "rectangle.badge.plus",
                                title: "Enable banners",
                                detail: "For instant live alerts"
                            )
                        }

                        HStack {
                            Spacer()
                            SettingsButton(
                                title: "Open System Settings",
                                systemImage: "gear",
                                style: .secondary,
                                action: openSettingsAction
                            )
                        }
                        .padding(.top, 4)
                    }

                    // Twitch Account Card
                    SettingsCard(
                        icon: "person.crop.circle.fill",
                        iconColor: Color(red: 0.57, green: 0.27, blue: 1.0),
                        title: "Twitch Account",
                        subtitle: "Manage your Twitch settings"
                    ) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Account Settings")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                Text("Privacy, security, and preferences")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer()

                            SettingsButton(
                                title: "Open",
                                systemImage: "arrow.up.right",
                                style: .secondary,
                                action: openTwitchSettingsAction
                            )
                        }
                    }

                    if showRecordingSettings {
                        SettingsCard(
                            icon: "terminal.fill",
                            iconColor: .white,
                            title: "Recording Tools",
                            subtitle: "Configure Streamlink and FFmpeg binaries"
                        ) {
                            settingsValueRow(
                                title: "Streamlink binary",
                                value: streamlinkPath.isEmpty ? "Auto-detect (Homebrew or downloaded)" : streamlinkPath
                            )

                            HStack {
                                SettingsButton(
                                    title: "Choose Streamlink",
                                    systemImage: "terminal",
                                    style: .secondary,
                                    action: selectStreamlinkBinary
                                )
                                Spacer()
                            }

                            if recordingManager.isInstalling {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text(recordingManager.installStatus ?? "Installing Streamlink…")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.7))
                                    Spacer()
                                }
                            }

                            HStack {
                                SettingsButton(
                                    title: recordingManager.isInstalling ? "Installing…" : "Install Streamlink",
                                    systemImage: "arrow.down.circle",
                                    style: .primary,
                                    action: {
                                        Task { await recordingManager.installStreamlink() }
                                    }
                                )
                                .disabled(recordingManager.isInstalling)
                                Spacer()
                            }

                            if !recordingManager.isInstalling, let status = recordingManager.installStatus {
                                let lower = status.lowercased()
                                let isSuccess = lower.contains("installed") || lower.contains("available")
                                Text(status)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(isSuccess ? Color.green.opacity(0.8) : Color.white.opacity(0.6))
                                    .lineLimit(2)
                            }

                            if let installError = recordingManager.installError {
                                Text(installError)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.orange.opacity(0.85))
                                    .lineLimit(2)
                            }

                            settingsValueRow(
                                title: "FFmpeg binary (optional)",
                                value: ffmpegPath.isEmpty ? "Auto-detect (ffmpeg in PATH)" : ffmpegPath
                            )

                            HStack {
                                SettingsButton(
                                    title: "Choose FFmpeg",
                                    systemImage: "terminal",
                                    style: .secondary,
                                    action: selectFFmpegBinary
                                )
                                Spacer()
                            }

                            if recordingManager.isInstallingFFmpeg {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text(recordingManager.ffmpegInstallStatus ?? "Installing FFmpeg…")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.7))
                                    Spacer()
                                }
                            }

                            HStack {
                                SettingsButton(
                                    title: recordingManager.isInstallingFFmpeg ? "Installing…" : "Install FFmpeg",
                                    systemImage: "arrow.down.circle",
                                    style: .primary,
                                    action: {
                                        Task { await recordingManager.installFFmpeg() }
                                    }
                                )
                                .disabled(recordingManager.isInstallingFFmpeg)
                                Spacer()
                            }

                            if !recordingManager.isInstallingFFmpeg, let status = recordingManager.ffmpegInstallStatus {
                                let lower = status.lowercased()
                                let isSuccess = lower.contains("installed") || lower.contains("available")
                                Text(status)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(isSuccess ? Color.green.opacity(0.8) : Color.white.opacity(0.6))
                                    .lineLimit(2)
                            }

                            if let installError = recordingManager.ffmpegInstallError {
                                Text(installError)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.orange.opacity(0.85))
                                    .lineLimit(2)
                            }
                        }
                    }

                    if showRecordingSettings {
                        SettingsCard(
                            icon: "record.circle",
                            iconColor: .red,
                            title: "Recording",
                            subtitle: "Capture live streams with Streamlink"
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                            SettingsToggleRow(
                                title: "Auto-record when live",
                                detail: "Start recording followed channels as soon as they go live.",
                                isOn: $autoRecordOnLive
                            )

                            SettingsToggleRow(
                                title: "Favorites only",
                                detail: "Only auto-record pinned channels with notifications enabled.",
                                isOn: $autoRecordPinnedOnly
                            )
                            .disabled(!autoRecordOnLive)
                            .opacity(autoRecordOnLive ? 1 : 0.5)

                            settingsValueRow(
                                title: "Recordings folder",
                                value: recordingsDirectory.isEmpty ? "Default (Downloads/Glitcho Recordings)" : recordingsDirectory
                            )

                            HStack {
                                SettingsButton(
                                    title: "Choose Folder",
                                    systemImage: "folder",
                                    style: .secondary,
                                    action: selectRecordingsFolder
                                )
                                Spacer()
                            }

                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 520)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var header: some View {
        ZStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .padding(12)
            }

            VStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)

                Text("Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
    }

    private var sidebarTintBinding: Binding<Color> {
        Binding(
            get: { SidebarTint.color(from: sidebarTintHex) },
            set: { newValue in
                sidebarTintHex = newValue.toHex() ?? SidebarTint.defaultHex
            }
        )
    }

    private func permissionRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func settingsValueRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(icon: String, iconColor: Color, title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconColor.opacity(0.2))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()
            }

            Divider()
                .overlay(Color.white.opacity(0.06))

            content
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct CollapsibleSettingsCard<Content: View>: View {
    let id: String
    let icon: String
    let iconColor: Color
    let iconBackgroundColor: Color
    let title: String
    let subtitle: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: Content

    init(id: String, icon: String, iconColor: Color, iconBackgroundColor: Color? = nil, title: String, subtitle: String, isExpanded: Bool, onToggle: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.id = id
        self.icon = icon
        self.iconColor = iconColor
        self.iconBackgroundColor = iconBackgroundColor ?? iconColor.opacity(0.2)
        self.title = title
        self.subtitle = subtitle
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(iconBackgroundColor)
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .overlay(Color.white.opacity(0.06))
                        .padding(.horizontal, 12)

                    content
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct SettingsButton: View {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    let systemImage: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            Color.white.opacity(0.15)
        case .secondary:
            Color.white.opacity(0.1)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var accentColor: Color = Color(hex: SidebarTint.defaultHex) ?? .purple

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.8)
                .tint(accentColor)
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let detail: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .padding(.vertical, 4)
    }
}
#endif
