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

private enum SettingsChrome {
    static let canvasBackground = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let panelBackground = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let cardFill = Color.white.opacity(0.05)
    static let cardBorder = Color.white.opacity(0.08)
    static let cardFillStrong = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.06)
    static let controlFill = Color.white.opacity(0.08)
    static let controlBorder = Color.white.opacity(0.09)
    static let textPrimary = Color.white.opacity(0.9)
    static let textSecondary = Color.white.opacity(0.74)
    static let textMuted = Color.white.opacity(0.58)
    static let textSubtle = Color.white.opacity(0.45)
}

private struct SettingsSurfaceModifier: ViewModifier {
    var fill: Color = SettingsChrome.cardFill
    var stroke: Color = SettingsChrome.cardBorder
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }
}

private extension View {
    func settingsSurface(
        fill: Color = SettingsChrome.cardFill,
        stroke: Color = SettingsChrome.cardBorder,
        cornerRadius: CGFloat = 10
    ) -> some View {
        modifier(SettingsSurfaceModifier(fill: fill, stroke: stroke, cornerRadius: cornerRadius))
    }
}

struct SettingsDetailView: View {
    @AppStorage("liveAlertsEnabled") private var liveAlertsEnabled = true
    @AppStorage("liveAlertsPinnedOnly") private var liveAlertsPinnedOnly = false
    @AppStorage(SidebarTint.storageKey) private var sidebarTintHex = SidebarTint.defaultHex
    @AppStorage("recordingsDirectory") private var recordingsDirectory = ""
    @AppStorage("streamlinkPath") private var streamlinkPath = ""
    @AppStorage("ffmpegPath") private var ffmpegPath = ""
    @AppStorage("iCloudSyncPaths") private var iCloudSyncPaths = false
    @AppStorage("autoRecordOnLive") private var autoRecordOnLive = false
    @AppStorage("autoRecordPinnedOnly") private var autoRecordPinnedOnly = false
    @AppStorage("autoRecordMode") private var autoRecordModeRaw = AutoRecordMode.pinnedAndFollowed.rawValue
    @AppStorage("autoRecordDebounceSeconds") private var autoRecordDebounceSeconds = 1
    @AppStorage("autoRecordCooldownSeconds") private var autoRecordCooldownSeconds = 30
    @AppStorage("recordingConcurrencyLimit") private var recordingConcurrencyLimit = 2
    @AppStorage("recordingsRetentionMaxAgeDays") private var recordingsRetentionMaxAgeDays = 0
    @AppStorage("recordingsRetentionKeepLastGlobal") private var recordingsRetentionKeepLastGlobal = 0
    @AppStorage("recordingsRetentionKeepLastPerChannel") private var recordingsRetentionKeepLastPerChannel = 0
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
    @AppStorage(BiometricLockSettings.enabledStorageKey) private var biometricLockEnabled = false
    @AppStorage(BiometricLockSettings.hideRecordingsStorageKey) private var biometricLockHideRecordings = true
    @AppStorage(BiometricLockSettings.recordingsRequireAuthOnOpenStorageKey) private var biometricLockRecordingsRequireAuthOnOpen = BiometricLockSettings.defaultRecordingsRequireAuthOnOpen
    @AppStorage(BiometricLockSettings.hidePinnedStorageKey) private var biometricLockHidePinned = true
    @AppStorage(BiometricLockSettings.hidePrivacySettingsUntilAuthenticatedStorageKey) private var biometricLockHidePrivacySettingsUntilAuthenticated = BiometricLockSettings.defaultHidePrivacySettingsUntilAuthenticated
    @AppStorage(BiometricLockSettings.protectedStreamersStorageKey) private var protectedStreamersJSON = "[]"
    @AppStorage(BiometricLockSettings.authenticateOnSettingsOpenStorageKey) private var biometricLockAuthenticateOnSettingsOpen = false
    @AppStorage(BiometricLockSettings.hotkeyKeyStorageKey) private var biometricLockHotkeyKey = BiometricLockSettings.defaultHotkeyKey
    @AppStorage(BiometricLockSettings.hotkeyCommandStorageKey) private var biometricLockHotkeyCommand = BiometricLockSettings.defaultHotkeyCommand
    @AppStorage(BiometricLockSettings.hotkeyShiftStorageKey) private var biometricLockHotkeyShift = BiometricLockSettings.defaultHotkeyShift
    @AppStorage(BiometricLockSettings.hotkeyOptionStorageKey) private var biometricLockHotkeyOption = BiometricLockSettings.defaultHotkeyOption
    @AppStorage(BiometricLockSettings.hotkeyControlStorageKey) private var biometricLockHotkeyControl = BiometricLockSettings.defaultHotkeyControl
    @Environment(\.notificationManager) private var notificationManager
    @Environment(\.openURL) private var openURL
    @State private var testStatus: NotificationTestStatus?
    @State private var clearTask: Task<Void, Never>?
    @State private var motionCapability = MotionSmootheningCapability.evaluate(screen: NSScreen.main)

    @ObservedObject var recordingManager: RecordingManager
    @ObservedObject var backgroundAgentManager: BackgroundRecorderAgentManager
    @ObservedObject var store: WebViewStore
    @AppStorage("autoRecordSelectedChannels") private var autoRecordSelectedChannelsJSON = "[]"
    @AppStorage("autoRecordBlockedChannels") private var autoRecordBlockedChannelsJSON = "[]"
    @AppStorage("settingsExpandedSections") private var expandedSectionsJSON = "[]"
    @State private var autoRecordSelectedChannels: Set<String> = []
    @State private var autoRecordBlockedChannels: Set<String> = []
    @State private var selectedChannelInput = ""
    @State private var blockedChannelInput = ""
    @State private var selectedChannelInputError: String?
    @State private var blockedChannelInputError: String?
    @State private var hasLoadedSelectedChannels = false
    @State private var hasLoadedExpandedSections = false
    @State private var showChannelSelector = false
    @State private var showBlocklistSelector = false
    @State private var pendingBackgroundAction: BackgroundControlAction?
    @State private var lastRestartAgentStatus: RestartAgentStatus?
    @State private var retentionRunStatus: String?
    @State private var isRunningBackgroundAction = false
    @State private var backgroundActionStatus: String?
    var isBiometricUnlocked = true
    var onUnlockRequest: (() -> Void)?
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

    private var videoAspectMode: VideoAspectCropMode {
        VideoAspectCropMode(rawValue: videoAspectModeRaw) ?? .source
    }

    private var shouldShowPrivacySettingsSection: Bool {
        if !biometricLockEnabled || !biometricLockHidePrivacySettingsUntilAuthenticated {
            return true
        }
        return isBiometricUnlocked
    }

    private var themeAccent: Color {
        sidebarTintBinding.wrappedValue
    }

    private var protectedStreamerLogins: Set<String> {
        guard let data = protectedStreamersJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded.map { $0.lowercased() })
    }

    private var shouldHideProtectedLoginsInSettings: Bool {
        biometricLockEnabled && !isBiometricUnlocked
    }

    private func shouldDisplayChannelLogin(_ login: String) -> Bool {
        if !shouldHideProtectedLoginsInSettings {
            return true
        }
        return !protectedStreamerLogins.contains(login.lowercased())
    }

    @State private var expandedSections: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                HStack {
                    Text("Settings")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(SettingsChrome.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 8)

                VStack(spacing: 14) {
                    // MARK: - General
                    CollapsibleSettingsCard(
                        id: "general",
                        icon: "gearshape.fill",
                        iconColor: .white,
                        iconBackgroundColor: sidebarTintBinding.wrappedValue,
                        title: "General",
                        subtitle: "Appearance, alerts, and permissions",
                        isExpanded: expandedSections.contains("general"),
                        onToggle: { toggleSection("general") }
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

                        Divider()
                            .padding(.vertical, 4)

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

                        Divider()
                            .padding(.vertical, 4)

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

                    // MARK: - Privacy Lock
                    if shouldShowPrivacySettingsSection {
                        CollapsibleSettingsCard(
                            id: "privacy_lock",
                            icon: "lock.fill",
                            iconColor: .white,
                            iconBackgroundColor: sidebarTintBinding.wrappedValue,
                            title: "Privacy Lock",
                            subtitle: "Hide selected sections until authenticated",
                            isExpanded: expandedSections.contains("privacy_lock"),
                            onToggle: { toggleSection("privacy_lock") }
                        ) {
                        SettingsToggleRow(
                            title: "Enable privacy lock",
                            detail: "Keep selected sections hidden until biometric authentication succeeds.",
                            isOn: $biometricLockEnabled,
                            accentColor: sidebarTintBinding.wrappedValue
                        )

                        Divider()
                            .padding(.vertical, 4)

                        Text("HIDE IN SIDEBAR")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .textCase(.uppercase)
                            .tracking(0.5)

                        SettingsToggleRow(
                            title: "Recordings",
                            detail: "Hide the Recordings navigation item and detail view.",
                            isOn: $biometricLockHideRecordings,
                            accentColor: sidebarTintBinding.wrappedValue
                        )
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        SettingsToggleRow(
                            title: "Require authentication to open Recordings",
                            detail: "Keep the Recordings tab visible, but require authentication before opening it.",
                            isOn: $biometricLockRecordingsRequireAuthOnOpen,
                            accentColor: sidebarTintBinding.wrappedValue
                        )
                        .disabled(!biometricLockEnabled || biometricLockHideRecordings)
                        .opacity((biometricLockEnabled && !biometricLockHideRecordings) ? 1 : 0.5)

                        SettingsToggleRow(
                            title: "Pinned",
                            detail: "Hide the pinned channels section in the sidebar.",
                            isOn: $biometricLockHidePinned,
                            accentColor: sidebarTintBinding.wrappedValue
                        )
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        Divider()
                            .padding(.vertical, 4)

                        ProtectedStreamersEditor(
                            accentColor: sidebarTintBinding.wrappedValue,
                            isEnabled: biometricLockEnabled,
                            recordingManager: recordingManager
                        )

                        SettingsToggleRow(
                            title: "Authenticate on Settings open",
                            detail: "Run authentication whenever Settings is opened from the sidebar.",
                            isOn: $biometricLockAuthenticateOnSettingsOpen,
                            accentColor: sidebarTintBinding.wrappedValue
                        )
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        SettingsToggleRow(
                            title: "Hide Privacy Lock in Settings when locked",
                            detail: "Hide this Privacy Lock section until authentication succeeds.",
                            isOn: $biometricLockHidePrivacySettingsUntilAuthenticated,
                            accentColor: sidebarTintBinding.wrappedValue
                        )
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        HStack(spacing: 8) {
                            TextField("Hotkey key", text: $biometricLockHotkeyKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            Text(biometricLockHotkeyDisplay)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        HStack(spacing: 8) {
                            Toggle("Cmd", isOn: $biometricLockHotkeyCommand)
                                .toggleStyle(.checkbox)
                            Toggle("Shift", isOn: $biometricLockHotkeyShift)
                                .toggleStyle(.checkbox)
                            Toggle("Option", isOn: $biometricLockHotkeyOption)
                                .toggleStyle(.checkbox)
                            Toggle("Control", isOn: $biometricLockHotkeyControl)
                                .toggleStyle(.checkbox)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)
                        }
                    } else {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(sidebarTintBinding.wrappedValue.opacity(0.25))
                                    .frame(width: 32, height: 32)
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(sidebarTintBinding.wrappedValue)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Privacy Lock")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SettingsChrome.textPrimary)
                                Text("Authenticate to access privacy settings")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SettingsChrome.textMuted)
                            }
                            Spacer()
                            Button(action: { onUnlockRequest?() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "faceid")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Unlock")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(sidebarTintBinding.wrappedValue)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .settingsSurface()
                    }

                    // MARK: - Recording
                    CollapsibleSettingsCard(
                        id: "recording",
                        icon: "record.circle",
                        iconColor: .white,
                        iconBackgroundColor: sidebarTintBinding.wrappedValue,
                        title: "Recording",
                        subtitle: "Capture, auto-record, and manage recordings",
                        isExpanded: expandedSections.contains("recording"),
                        onToggle: { toggleSection("recording") }
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TOOLS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .textCase(.uppercase)
                                .tracking(0.5)

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

                            Divider()
                                .padding(.vertical, 4)

                            SettingsToggleRow(
                                title: "Sync tool paths via iCloud",
                                detail: "Include Streamlink, FFmpeg, and recordings folder paths in iCloud sync. Turn off if paths differ between machines.",
                                isOn: $iCloudSyncPaths,
                                accentColor: sidebarTintBinding.wrappedValue
                            )

                            Divider()
                                .padding(.vertical, 4)

                            Text("AUTO-RECORD")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .textCase(.uppercase)
                                .tracking(0.5)

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

                                    let visibleFollowedLogins = store.followedChannelLogins
                                        .sorted()
                                        .filter(shouldDisplayChannelLogin)
                                    if showChannelSelector, !visibleFollowedLogins.isEmpty {
                                        VStack(spacing: 6) {
                                            HStack {
                                                Button("Select All Followed") {
                                                    autoRecordSelectedChannels.formUnion(visibleFollowedLogins.map { $0.lowercased() })
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
                                                    ForEach(visibleFollowedLogins, id: \.self) { login in
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

                                    let visibleSelectedChannels = autoRecordSelectedChannels
                                        .sorted()
                                        .filter(shouldDisplayChannelLogin)
                                    if visibleSelectedChannels.isEmpty {
                                        Text("No channels selected. Add channels manually or from followed list.")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.6))
                                    } else {
                                        VStack(spacing: 4) {
                                            ForEach(visibleSelectedChannels, id: \.self) { login in
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

                                    let visibleFollowedLoginsForBlocklist = store.followedChannelLogins
                                        .sorted()
                                        .filter(shouldDisplayChannelLogin)
                                    if showBlocklistSelector, !visibleFollowedLoginsForBlocklist.isEmpty {
                                        ScrollView {
                                            VStack(spacing: 4) {
                                                ForEach(visibleFollowedLoginsForBlocklist, id: \.self) { login in
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

                                    let visibleBlockedChannels = autoRecordBlockedChannels
                                        .sorted()
                                        .filter(shouldDisplayChannelLogin)
                                    if visibleBlockedChannels.isEmpty {
                                        Text("No blocked channels.")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.6))
                                    } else {
                                        VStack(spacing: 4) {
                                            ForEach(visibleBlockedChannels, id: \.self) { login in
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

                            Text("ORCHESTRATION")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .textCase(.uppercase)
                                .tracking(0.5)

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

                            Divider()
                                .padding(.vertical, 4)

                            Text("RETENTION")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .textCase(.uppercase)
                                .tracking(0.5)

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

                            Divider()
                                .padding(.vertical, 4)

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
                                .padding(.vertical, 4)

                            Text("BACKGROUND RECORDER")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .textCase(.uppercase)
                                .tracking(0.5)

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

                    // MARK: - Playback
                    CollapsibleSettingsCard(
                        id: "playback",
                        icon: "play.circle.fill",
                        iconColor: .white,
                        iconBackgroundColor: sidebarTintBinding.wrappedValue,
                        title: "Playback",
                        subtitle: "Video quality and enhancement",
                        isExpanded: expandedSections.contains("playback"),
                        onToggle: { toggleSection("playback") }
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
                                title: "Show FPS overlay",
                                detail: "Display a frame rate badge on the player when motion smoothening is active.",
                                isOn: $showFPSOverlay
                            )

                            SettingsToggleRow(
                                title: "Show 4K overlay",
                                detail: "Display a 4K badge on the player when upscaling is active.",
                                isOn: $show4KOverlay
                            )

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

                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(
            LinearGradient(
                colors: [SettingsChrome.canvasBackground, SettingsChrome.panelBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            loadSelectedChannelsIfNeeded()
            loadBlockedChannelsIfNeeded()
            loadExpandedSectionsIfNeeded()
            motionCapability = MotionSmootheningCapability.evaluate(screen: NSScreen.main)
            sanitizeProVideoEnhancementState()
            sanitizeBiometricLockHotkey()
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
        .onChange(of: biometricLockHotkeyKey) { _ in
            sanitizeBiometricLockHotkey()
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
        saveExpandedSections()
    }

    private func loadExpandedSectionsIfNeeded() {
        guard !hasLoadedExpandedSections else { return }
        hasLoadedExpandedSections = true

        guard let data = expandedSectionsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        expandedSections = Set(decoded)
    }

    private func saveExpandedSections() {
        let array = Array(expandedSections).sorted()
        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        expandedSectionsJSON = json
    }

    private var sidebarTintBinding: Binding<Color> {
        Binding(
            get: { SidebarTint.color(from: sidebarTintHex) },
            set: { newValue in
                sidebarTintHex = newValue.toHex() ?? SidebarTint.defaultHex
            }
        )
    }

    private var biometricLockHotkeyDisplay: String {
        BiometricLockSettings.hotkeyDisplay(
            keyRaw: biometricLockHotkeyKey,
            useCommand: biometricLockHotkeyCommand,
            useShift: biometricLockHotkeyShift,
            useOption: biometricLockHotkeyOption,
            useControl: biometricLockHotkeyControl
        )
    }

    private func sanitizeBiometricLockHotkey() {
        let sanitized = BiometricLockSettings.normalizedHotkeyInput(biometricLockHotkeyKey)
        if biometricLockHotkeyKey != sanitized {
            biometricLockHotkeyKey = sanitized
        }
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
                .foregroundStyle(SettingsChrome.textMuted)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsChrome.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsChrome.textSubtle)
            }
        }
    }

    private func settingsValueRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsChrome.textPrimary)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(SettingsChrome.textMuted)
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
    @AppStorage(BiometricLockSettings.enabledStorageKey) private var biometricLockEnabled = false
    @AppStorage(BiometricLockSettings.hideRecordingsStorageKey) private var biometricLockHideRecordings = true
    @AppStorage(BiometricLockSettings.recordingsRequireAuthOnOpenStorageKey) private var biometricLockRecordingsRequireAuthOnOpen = BiometricLockSettings.defaultRecordingsRequireAuthOnOpen
    @AppStorage(BiometricLockSettings.hidePinnedStorageKey) private var biometricLockHidePinned = true
    @AppStorage(BiometricLockSettings.hidePrivacySettingsUntilAuthenticatedStorageKey) private var biometricLockHidePrivacySettingsUntilAuthenticated = BiometricLockSettings.defaultHidePrivacySettingsUntilAuthenticated
    @AppStorage(BiometricLockSettings.authenticateOnSettingsOpenStorageKey) private var biometricLockAuthenticateOnSettingsOpen = false
    @AppStorage(BiometricLockSettings.hotkeyKeyStorageKey) private var biometricLockHotkeyKey = BiometricLockSettings.defaultHotkeyKey
    @AppStorage(BiometricLockSettings.hotkeyCommandStorageKey) private var biometricLockHotkeyCommand = BiometricLockSettings.defaultHotkeyCommand
    @AppStorage(BiometricLockSettings.hotkeyShiftStorageKey) private var biometricLockHotkeyShift = BiometricLockSettings.defaultHotkeyShift
    @AppStorage(BiometricLockSettings.hotkeyOptionStorageKey) private var biometricLockHotkeyOption = BiometricLockSettings.defaultHotkeyOption
    @AppStorage(BiometricLockSettings.hotkeyControlStorageKey) private var biometricLockHotkeyControl = BiometricLockSettings.defaultHotkeyControl
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
            biometricLockEnabled: $biometricLockEnabled,
            biometricLockHideRecordings: $biometricLockHideRecordings,
            biometricLockRecordingsRequireAuthOnOpen: $biometricLockRecordingsRequireAuthOnOpen,
            biometricLockHidePinned: $biometricLockHidePinned,
            biometricLockHidePrivacySettingsUntilAuthenticated: $biometricLockHidePrivacySettingsUntilAuthenticated,
            biometricLockAuthenticateOnSettingsOpen: $biometricLockAuthenticateOnSettingsOpen,
            biometricLockHotkeyKey: $biometricLockHotkeyKey,
            biometricLockHotkeyCommand: $biometricLockHotkeyCommand,
            biometricLockHotkeyShift: $biometricLockHotkeyShift,
            biometricLockHotkeyOption: $biometricLockHotkeyOption,
            biometricLockHotkeyControl: $biometricLockHotkeyControl,
            isBiometricUnlocked: true,
            selectRecordingsFolder: selectRecordingsFolder,
            selectStreamlinkBinary: selectStreamlinkBinary,
            selectFFmpegBinary: selectFFmpegBinary,
            recordingManager: recordingManager,
            showRecordingSettings: true,
            isNotificationManagerAvailable: notificationManager != nil,
            onClose: { (onClose ?? { dismiss() })() }
        )
        .onAppear {
            sanitizeBiometricLockHotkey()
        }
        .onChange(of: biometricLockHotkeyKey) { _ in
            sanitizeBiometricLockHotkey()
        }
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

    private func sanitizeBiometricLockHotkey() {
        let sanitized = BiometricLockSettings.normalizedHotkeyInput(biometricLockHotkeyKey)
        if biometricLockHotkeyKey != sanitized {
            biometricLockHotkeyKey = sanitized
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
    @Binding var biometricLockEnabled: Bool
    @Binding var biometricLockHideRecordings: Bool
    @Binding var biometricLockRecordingsRequireAuthOnOpen: Bool
    @Binding var biometricLockHidePinned: Bool
    @Binding var biometricLockHidePrivacySettingsUntilAuthenticated: Bool
    @Binding var biometricLockAuthenticateOnSettingsOpen: Bool
    @Binding var biometricLockHotkeyKey: String
    @Binding var biometricLockHotkeyCommand: Bool
    @Binding var biometricLockHotkeyShift: Bool
    @Binding var biometricLockHotkeyOption: Bool
    @Binding var biometricLockHotkeyControl: Bool
    let isBiometricUnlocked: Bool
    var onUnlockRequest: (() -> Void)?
    let selectRecordingsFolder: () -> Void
    let selectStreamlinkBinary: () -> Void
    let selectFFmpegBinary: () -> Void
    @ObservedObject var recordingManager: RecordingManager
    let showRecordingSettings: Bool
    let isNotificationManagerAvailable: Bool
    let onClose: () -> Void

    private var shouldShowPrivacySettingsSection: Bool {
        if !biometricLockEnabled || !biometricLockHidePrivacySettingsUntilAuthenticated {
            return true
        }
        return isBiometricUnlocked
    }

    private var themeAccent: Color {
        sidebarTintBinding.wrappedValue
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    SettingsCard(
                        icon: "paintpalette.fill",
                        iconColor: themeAccent,
                        title: "Appearance",
                        subtitle: "Customize the sidebar tint"
                    ) {
                        HStack(spacing: 12) {
                            ColorPicker("Sidebar tint", selection: sidebarTintBinding, supportsOpacity: false)
                                .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sidebar tint")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(SettingsChrome.textPrimary)
                                Text(sidebarTintHex.uppercased())
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(SettingsChrome.textMuted)
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
                        iconColor: themeAccent,
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
                        iconColor: themeAccent,
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
                        iconColor: themeAccent,
                        title: "Twitch Account",
                        subtitle: "Manage your Twitch settings"
                    ) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Account Settings")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(SettingsChrome.textPrimary)
                                Text("Privacy, security, and preferences")
                                    .font(.system(size: 10))
                                    .foregroundStyle(SettingsChrome.textMuted)
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

                    if shouldShowPrivacySettingsSection {
                        SettingsCard(
                            icon: "lock.fill",
                            iconColor: themeAccent,
                            title: "Privacy Lock",
                            subtitle: "Hide selected sections until authenticated"
                        ) {
                        SettingsToggleRow(
                            title: "Enable privacy lock",
                            detail: "Keep selected sections hidden until biometric authentication succeeds.",
                            isOn: $biometricLockEnabled
                        )

                        SettingsToggleRow(
                            title: "Recordings",
                            detail: "Hide the Recordings navigation item and detail view.",
                            isOn: $biometricLockHideRecordings
                        )
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        SettingsToggleRow(
                            title: "Require authentication to open Recordings",
                            detail: "Keep the Recordings tab visible, but require authentication before opening it.",
                            isOn: $biometricLockRecordingsRequireAuthOnOpen
                        )
                        .disabled(!biometricLockEnabled || biometricLockHideRecordings)
                        .opacity((biometricLockEnabled && !biometricLockHideRecordings) ? 1 : 0.5)

                        SettingsToggleRow(
                            title: "Pinned",
                            detail: "Hide the pinned channels section in the sidebar.",
                            isOn: $biometricLockHidePinned
                        )
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        ProtectedStreamersEditor(
                            isEnabled: biometricLockEnabled,
                            recordingManager: recordingManager
                        )

                        SettingsToggleRow(
                            title: "Authenticate on Settings open",
                            detail: "Run authentication whenever Settings is opened from the sidebar.",
                            isOn: $biometricLockAuthenticateOnSettingsOpen
                        )
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        SettingsToggleRow(
                            title: "Hide Privacy Lock in Settings when locked",
                            detail: "Hide this Privacy Lock section until authentication succeeds.",
                            isOn: $biometricLockHidePrivacySettingsUntilAuthenticated
                        )
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        HStack(spacing: 8) {
                            TextField("Hotkey key", text: $biometricLockHotkeyKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(SettingsChrome.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .settingsSurface(fill: SettingsChrome.controlFill, stroke: SettingsChrome.controlBorder, cornerRadius: 6)

                            Text(biometricLockHotkeyDisplay)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SettingsChrome.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .settingsSurface(fill: SettingsChrome.controlFill, stroke: SettingsChrome.controlBorder, cornerRadius: 6)
                        }
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)

                        HStack(spacing: 8) {
                            Toggle("Cmd", isOn: $biometricLockHotkeyCommand)
                                .toggleStyle(.checkbox)
                            Toggle("Shift", isOn: $biometricLockHotkeyShift)
                                .toggleStyle(.checkbox)
                            Toggle("Option", isOn: $biometricLockHotkeyOption)
                                .toggleStyle(.checkbox)
                            Toggle("Control", isOn: $biometricLockHotkeyControl)
                                .toggleStyle(.checkbox)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsChrome.textSecondary)
                        .disabled(!biometricLockEnabled)
                        .opacity(biometricLockEnabled ? 1 : 0.5)
                        }
                    } else {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(themeAccent.opacity(0.25))
                                    .frame(width: 32, height: 32)
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(themeAccent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Privacy Lock")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SettingsChrome.textPrimary)
                                Text("Authenticate to access privacy settings")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SettingsChrome.textMuted)
                            }
                            Spacer()
                            Button(action: { onUnlockRequest?() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "faceid")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Unlock")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(themeAccent)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .settingsSurface()
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
                                        .foregroundStyle(SettingsChrome.textSecondary)
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
                                    .foregroundStyle(isSuccess ? Color.green.opacity(0.82) : SettingsChrome.textMuted)
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
                                        .foregroundStyle(SettingsChrome.textSecondary)
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
                                    .foregroundStyle(isSuccess ? Color.green.opacity(0.82) : SettingsChrome.textMuted)
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
        .background(
            ZStack {
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(0.9)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SettingsChrome.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 22, x: 0, y: 10)
    }

    private var header: some View {
        ZStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(SettingsChrome.textSubtle)
                }
                .buttonStyle(.plain)
                .padding(12)
            }

            VStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(SettingsChrome.textPrimary)

                Text("Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsChrome.textPrimary)
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

    private var biometricLockHotkeyDisplay: String {
        BiometricLockSettings.hotkeyDisplay(
            keyRaw: biometricLockHotkeyKey,
            useCommand: biometricLockHotkeyCommand,
            useShift: biometricLockHotkeyShift,
            useOption: biometricLockHotkeyOption,
            useControl: biometricLockHotkeyControl
        )
    }

    private func permissionRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsChrome.textMuted)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsChrome.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsChrome.textSubtle)
            }
        }
    }

    private func settingsValueRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsChrome.textPrimary)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(SettingsChrome.textMuted)
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
                        .foregroundStyle(SettingsChrome.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsChrome.textMuted)
                }

                Spacer()
            }

            Divider()
                .overlay(SettingsChrome.divider)

            content
        }
        .padding(12)
        .settingsSurface()
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
                            .foregroundStyle(SettingsChrome.textPrimary)
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsChrome.textMuted)
                    }

                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsChrome.textSubtle)
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .overlay(SettingsChrome.divider)
                        .padding(.horizontal, 12)

                    content
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
        }
        .settingsSurface()
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
            .foregroundStyle(SettingsChrome.textPrimary)
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
            SettingsChrome.cardFillStrong
        case .secondary:
            SettingsChrome.controlFill
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
                    .foregroundStyle(SettingsChrome.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsChrome.textMuted)
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
                .foregroundStyle(SettingsChrome.textPrimary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(SettingsChrome.textMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(SettingsChrome.textPrimary)
                .padding(8)
                .background(SettingsChrome.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(SettingsChrome.controlBorder, lineWidth: 1)
                )
        }
        .padding(.vertical, 4)
    }
}

private struct ProtectedStreamersEditor: View {
    @AppStorage(BiometricLockSettings.protectedStreamersStorageKey) private var protectedStreamersJSON = "[]"
    @AppStorage(BiometricLockSettings.autoProtectAllowlistedStorageKey) private var autoProtectAllowlisted = BiometricLockSettings.defaultAutoProtectAllowlisted
    @State private var protectedStreamers: Set<String> = []
    @State private var input = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var hasLoaded = false

    var accentColor: Color = Color(hex: SidebarTint.defaultHex) ?? .purple
    var isEnabled = true
    var recordingManager: RecordingManager? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROTECTED STREAMERS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsChrome.textSubtle)
                .textCase(.uppercase)
                .tracking(0.5)

            Text("These channels are hidden in Recent history and Recordings until authentication succeeds.")
                .font(.system(size: 10))
                .foregroundStyle(SettingsChrome.textMuted)

            HStack(spacing: 8) {
                TextField("Streamer login or Twitch URL", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsChrome.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(SettingsChrome.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(SettingsChrome.controlBorder, lineWidth: 1)
                    )
                    .onSubmit { addStreamer() }

                SettingsButton(
                    title: "Add",
                    systemImage: "plus",
                    style: .secondary,
                    action: addStreamer
                )

                SettingsButton(
                    title: "Import",
                    systemImage: "square.and.arrow.down",
                    style: .secondary,
                    action: importFromRecordings
                )
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusIsError ? .orange.opacity(0.85) : .green.opacity(0.85))
            }

            SettingsToggleRow(
                title: "Auto-add recording allowlist",
                detail: "When channels are added to recording allowlist, add them to protected streamers too.",
                isOn: $autoProtectAllowlisted,
                accentColor: accentColor
            )

            if protectedStreamers.isEmpty {
                Text("No protected streamers.")
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsChrome.textMuted)
            } else {
                VStack(spacing: 4) {
                    ForEach(protectedStreamers.sorted(), id: \.self) { login in
                        HStack {
                            Text(login)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(SettingsChrome.textPrimary)
                            Spacer()
                            Button {
                                protectedStreamers.remove(login)
                                save()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SettingsChrome.textSubtle)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .settingsSurface(fill: Color.white.opacity(0.04), cornerRadius: 6)
                    }
                }
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onAppear {
            loadIfNeeded()
        }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = protectedStreamersJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            protectedStreamers = []
            return
        }
        protectedStreamers = Set(decoded.map { $0.lowercased() })
    }

    private func save() {
        let array = Array(protectedStreamers).sorted()
        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        protectedStreamersJSON = json
    }

    private func addStreamer() {
        guard let login = normalizeLogin(input) else {
            setStatus("Enter a valid streamer login or Twitch URL.", isError: true)
            return
        }
        input = ""
        if protectedStreamers.contains(login) {
            setStatus("@\(login) is already protected.", isError: false)
            return
        }
        protectedStreamers.insert(login)
        save()
        setStatus("Added @\(login) to protected streamers.", isError: false)
    }

    private func importFromRecordings() {
        guard let recordingManager else {
            setStatus("Recordings list is unavailable.", isError: true)
            return
        }
        let imported = Set<String>(recordingManager.listRecordings().compactMap { normalizeLogin($0.channelName) })
        guard !imported.isEmpty else {
            setStatus("No streamer names found in current recordings.", isError: true)
            return
        }
        let before = protectedStreamers.count
        protectedStreamers.formUnion(imported)
        let added = protectedStreamers.count - before
        save()
        if added > 0 {
            setStatus("Imported \(added) streamer(s) from recordings.", isError: false)
        } else {
            setStatus("All streamers from recordings are already protected.", isError: false)
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func normalizeLogin(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host.contains("twitch.tv") {
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
#endif
