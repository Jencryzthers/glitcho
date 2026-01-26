import SwiftUI

@main
struct TwitchGlassApp: App {
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var notificationManager = NotificationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowConfigurator())
                .environmentObject(updateChecker)
                .environment(\.notificationManager, notificationManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task {
                        await updateChecker.checkForUpdates(force: true)
                    }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        Window("About Glitcho", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(\.notificationManager, notificationManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        WindowGroup("Chat", id: "chat", for: ChatWindowContext.self) { context in
            if let value = context.wrappedValue {
                DetachedChatView(channelName: value.channelName)
            } else {
                DetachedChatView(channelName: "twitch")
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 560)
        .defaultPosition(.trailing)
    }
}

struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Glitcho") {
            openWindow(id: "about")
        }
    }
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "Unknown"
    }

    var body: some View {
        VStack(spacing: 16) {
            // Close button
            HStack {
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
            }

            // App icon
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
            }

            // App name and version
            Text("Glitcho")
                .font(.system(size: 20, weight: .semibold))

            Text("Version \(appVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 20)

            // Description
            VStack(alignment: .leading, spacing: 12) {
                Text("A native Twitch client for macOS with ad-blocking, native video playback via Streamlink, and a beautiful glass UI.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Text("Built with SwiftUI and AVKit.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                Divider()

                // Developer info
                HStack {
                    Text("Developer:")
                        .foregroundStyle(.secondary)
                    Text("jencryzthers")
                }
                .font(.system(size: 12))

                HStack {
                    Text("Contact:")
                        .foregroundStyle(.secondary)
                    Link("j.christophe@devjc.net", destination: URL(string: "mailto:j.christophe@devjc.net")!)
                }
                .font(.system(size: 12))

                HStack {
                    Text("GitHub:")
                        .foregroundStyle(.secondary)
                    Link("github.com/Jencryzthers/Glitcho", destination: URL(string: "https://github.com/Jencryzthers/Glitcho")!)
                }
                .font(.system(size: 12))

                Divider()

                // Buy me a beer
                HStack {
                    Spacer()
                    Button(action: {
                        openURL(URL(string: "https://www.paypal.com/paypalme/jcproulx")!)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "mug.fill")
                            Text("Buy me a beer")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.orange.gradient)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            // Copyright
            Text("© \(currentYear) Glitcho")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(width: 380, height: 420)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
}
