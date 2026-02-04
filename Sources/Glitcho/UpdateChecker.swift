import Foundation

#if canImport(SwiftUI)

@MainActor
final class UpdateChecker: ObservableObject {
    struct UpdateInfo: Equatable {
        let currentVersion: String
        let latestVersion: String
        let releaseURL: URL
        let releaseNotes: String?
    }

    struct StatusInfo: Equatable {
        enum Kind: Equatable {
            case success
            case failure
        }

        let title: String
        let message: String
        let kind: Kind
    }

    @Published private(set) var update: UpdateInfo?
    @Published private(set) var isPromptVisible = false
    @Published private(set) var status: StatusInfo?
    @Published private(set) var isStatusVisible = false

    private let session: URLSession
    private let repository = "Jencryzthers/glitcho"
    private var hasChecked = false
    private var statusDismissTask: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkForUpdates(force: Bool = false) async {
        guard !hasChecked || force else { return }
        hasChecked = true

        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard let currentVersion = currentAppVersion() else { return }

        if force {
            status = nil
            isStatusVisible = false
        }

        if !force {
            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Glitcho/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await session.data(for: request)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease else { return }

            let latestVersion = normalizedVersionString(release.tagName ?? release.name ?? "")
            guard !latestVersion.isEmpty else { return }

            if isVersion(latestVersion, newerThan: currentVersion) {
                let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
                update = UpdateInfo(
                    currentVersion: currentVersion,
                    latestVersion: latestVersion,
                    releaseURL: release.htmlURL,
                    releaseNotes: notes
                )
                isPromptVisible = true
            } else if force {
                showStatus(
                    title: "You're up to date",
                    message: "Glitcho \(currentVersion) is the latest version available.",
                    kind: .success
                )
            }
        } catch {
            if force {
                showStatus(
                    title: "Unable to Check for Updates",
                    message: "We couldn't reach GitHub right now. Please try again later.",
                    kind: .failure
                )
            }
            return
        }
    }

    func dismissPrompt() {
        isPromptVisible = false
    }

    func dismissStatus() {
        statusDismissTask?.cancel()
        statusDismissTask = nil
        isStatusVisible = false
    }

    private func currentAppVersion() -> String? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func showStatus(title: String, message: String, kind: StatusInfo.Kind) {
        statusDismissTask?.cancel()
        status = StatusInfo(title: title, message: message, kind: kind)
        isStatusVisible = true
        statusDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            isStatusVisible = false
        }
    }

    private func normalizedVersionString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var cleaned = trimmed
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }

        if let dashIndex = cleaned.firstIndex(of: "-") {
            cleaned = String(cleaned[..<dashIndex])
        }

        return cleaned
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = versionParts(from: candidate)
        let currentParts = versionParts(from: current)
        let maxCount = max(candidateParts.count, currentParts.count)

        for index in 0..<maxCount {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs {
                return lhs > rhs
            }
        }
        return false
    }

    private func versionParts(from raw: String) -> [Int] {
        raw.split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String?
    let name: String?
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case draft
        case prerelease
    }
}

#endif
