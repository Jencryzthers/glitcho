#if canImport(SwiftUI)
import SwiftUI

private enum UpdatePromptChrome {
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.72)
    static let textMuted = Color.white.opacity(0.58)
    static let panelBorder = Color.white.opacity(0.12)
    static let softFill = Color.white.opacity(0.08)
    static let softFillStrong = Color.white.opacity(0.14)
}

struct UpdatePromptView: View {
    let update: UpdateChecker.UpdateInfo
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @AppStorage(SidebarTint.storageKey) private var sidebarTintHex = SidebarTint.defaultHex

    private var accentColor: Color {
        SidebarTint.color(from: sidebarTintHex)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 18) {
                header
                summary
                if let notes = releaseNotesPreview {
                    notesSection(notes)
                }
                actions
            }
            .padding(24)
            .frame(width: 520)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [accentColor.opacity(0.22), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    LinearGradient(
                        colors: [Color.white.opacity(0.07), Color.clear],
                        startPoint: .bottomTrailing,
                        endPoint: .topLeading
                    )
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .opacity(0.9)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(UpdatePromptChrome.panelBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 30, x: 0, y: 12)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Update Available")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(UpdatePromptChrome.textPrimary)

                Text("Glitcho \(update.latestVersion)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UpdatePromptChrome.textSecondary)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(UpdatePromptChrome.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(UpdatePromptChrome.softFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A newer version of Glitcho is ready to install.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UpdatePromptChrome.textPrimary)

            Text("You are currently on \(update.currentVersion). We recommend updating to ensure the best performance and stability.")
                .font(.system(size: 12))
                .foregroundStyle(UpdatePromptChrome.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's new")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UpdatePromptChrome.textSecondary)

            ScrollView {
                Text(notes)
                    .font(.system(size: 12))
                    .foregroundStyle(UpdatePromptChrome.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(12)
            .background(UpdatePromptChrome.softFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Not Now", action: onDismiss)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UpdatePromptChrome.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(UpdatePromptChrome.softFill)
                .clipShape(Capsule())
                .buttonStyle(.plain)

            Spacer()

            Button {
                openURL(update.releaseURL)
                onDismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download Update")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UpdatePromptChrome.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [accentColor.opacity(0.96), accentColor.opacity(0.72)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var releaseNotesPreview: String? {
        guard let notes = update.releaseNotes else { return nil }
        let sanitized = notes.replacingOccurrences(of: "\r", with: "")
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 600 {
            return String(trimmed.prefix(600)) + "..."
        }
        return trimmed
    }
}

#endif
