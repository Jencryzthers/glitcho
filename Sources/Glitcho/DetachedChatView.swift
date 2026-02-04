#if canImport(SwiftUI)
import AppKit
import SwiftUI

struct ChatWindowContext: Codable, Hashable {
    let channelName: String
}

struct DetachedChatView: View {
    let channelName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                TwitchChatView(channelName: channelName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(
                ZStack {
                    Color(red: 0.06, green: 0.06, blue: 0.08)
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .opacity(0.5)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(12)
        }
        .background(ChatWindowConfigurator())
        .onReceive(NotificationCenter.default.publisher(for: .detachedChatShouldClose)) { notification in
            guard shouldClose(for: notification) else { return }
            dismiss()
        }
        .onDisappear {
            NotificationCenter.default.post(name: .detachedChatDidClose, object: nil, userInfo: ["channel": channelName])
        }
        .frame(minWidth: 320, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))

            VStack(alignment: .leading, spacing: 2) {
                Text("Chat")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("twitch.tv/\(channelName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Button(action: attachChat) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text("Attach")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.6), Color.black.opacity(0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func attachChat() {
        NotificationCenter.default.post(name: .detachedChatAttachRequested, object: nil, userInfo: ["channel": channelName])
        dismiss()
    }

    private func shouldClose(for notification: Notification) -> Bool {
        guard let channel = notification.userInfo?["channel"] as? String else { return true }
        return channel == channelName
    }
}

struct ChatWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfigView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        _ = nsView
    }

    private final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }
}

extension Notification.Name {
    static let detachedChatShouldClose = Notification.Name("glitcho.detachedChatShouldClose")
    static let detachedChatDidClose = Notification.Name("glitcho.detachedChatDidClose")
    static let detachedChatAttachRequested = Notification.Name("glitcho.detachedChatAttachRequested")
}

#endif
