#if canImport(SwiftUI)
import Foundation
import WebKit

// MARK: - WebKit Cookie Helper

/// Retrieves all cookies from the default WKWebsiteDataStore on the main thread.
func webKitCookies() async -> [HTTPCookie] {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

// MARK: - Executable Resolution

/// Searches PATH and common Homebrew/system paths for a binary by name.
func resolveExecutable(named name: String) -> String? {
    let fallbackPaths = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)"
    ]
    let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let pathEntries = pathEnvironment.split(separator: ":").map(String.init)
    let searchPaths = pathEntries + fallbackPaths
    for directory in searchPaths {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

// MARK: - TwitchChannel Helpers

extension Array where Element == TwitchChannel {
    /// Deduplicates channels by login, preferring entries that have a thumbnail.
    func deduplicatedByLogin() -> [TwitchChannel] {
        var seen: [String: TwitchChannel] = [:]
        for channel in self {
            if let existing = seen[channel.id] {
                if existing.thumbnailURL == nil, channel.thumbnailURL != nil {
                    seen[channel.id] = channel
                }
            } else {
                seen[channel.id] = channel
            }
        }
        return seen.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

#endif
