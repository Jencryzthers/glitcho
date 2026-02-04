#if canImport(SwiftUI)
import SwiftUI

struct UpdatePromptView: View {
    let update: UpdateChecker.UpdateInfo
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

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
                        colors: [Color.white.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .opacity(0.9)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
                    .foregroundStyle(.white)

                Text("Glitcho \(update.latestVersion)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A newer version of Glitcho is ready to install.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            Text("You are currently on \(update.currentVersion). We recommend updating to ensure the best performance and stability.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's new")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            ScrollView {
                Text(notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(12)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Not Now", action: onDismiss)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08))
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
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.9), Color.cyan.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
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
