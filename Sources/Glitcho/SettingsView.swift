#if canImport(SwiftUI)
import AppKit
import SwiftUI

struct SettingsModal: View {
    let onClose: () -> Void
    var onOpenTwitchSettings: (() -> Void)?

    var body: some View {
        ZStack {
            // Backdrop that blocks all interaction
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { }  // Absorb taps, don't close

            // Centered settings panel
            SettingsView(onClose: onClose, onOpenTwitchSettings: onOpenTwitchSettings)
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
    @AppStorage("autoRecordOnLive") private var autoRecordOnLive = false
    @AppStorage("autoRecordPinnedOnly") private var autoRecordPinnedOnly = false
    @Environment(\.notificationManager) private var notificationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var testStatus: NotificationTestStatus?
    @State private var clearTask: Task<Void, Never>?

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
            autoRecordOnLive: $autoRecordOnLive,
            autoRecordPinnedOnly: $autoRecordPinnedOnly,
            selectRecordingsFolder: selectRecordingsFolder,
            selectStreamlinkBinary: selectStreamlinkBinary,
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
    @Binding var autoRecordOnLive: Bool
    @Binding var autoRecordPinnedOnly: Bool
    let selectRecordingsFolder: () -> Void
    let selectStreamlinkBinary: () -> Void
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

                            settingsValueRow(
                                title: "Streamlink binary",
                                value: streamlinkPath.isEmpty ? "Auto-detect (/opt/homebrew/bin/streamlink)" : streamlinkPath
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
                    .foregroundStyle(.white.opacity(0.8))

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

private struct SettingsButton: View {
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
            LinearGradient(
                colors: [Color.purple.opacity(0.8), Color.purple.opacity(0.6)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .secondary:
            Color.white.opacity(0.1)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

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
                .tint(Color.purple)
        }
        .padding(.vertical, 4)
    }
}

#endif
