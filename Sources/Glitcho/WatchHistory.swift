#if canImport(SwiftUI)
import Foundation
import SwiftUI

// MARK: - WatchHistoryEntry

/// A single channel watch session recorded in the user's history.
struct WatchHistoryEntry: Codable, Identifiable {
    /// Stable identity derived from the channel login so that `ForEach` and
    /// list diffing work correctly without requiring a separate UUID field.
    var id: String { channelLogin }

    /// Lowercased Twitch login name (e.g. `"shroud"`).
    var channelLogin: String

    /// Display name as shown in the Twitch UI (e.g. `"Shroud"`).
    /// Falls back to `channelLogin` when unavailable at record time.
    var channelDisplayName: String

    /// The most recent moment the channel was opened.
    var lastWatched: Date

    /// Cumulative seconds spent watching this channel across all sessions.
    var totalWatchSeconds: TimeInterval
}

// MARK: - WatchHistoryManager

/// Tracks which channels the user watches and for how long.
///
/// Entries are persisted to `UserDefaults` under the key `"watchHistory"` as
/// JSON so they survive app restarts.  A lightweight 60-second heartbeat timer
/// increments `totalWatchSeconds` while a session is in progress.
@MainActor
final class WatchHistoryManager: ObservableObject {

    // MARK: Constants

    private enum Keys {
        static let userDefaults = "watchHistory"
    }

    private static let timerInterval: TimeInterval = 60
    private static let historyLimit = 50

    // MARK: Published state

    /// The full in-memory list of entries, kept sorted by `lastWatched`
    /// descending.  Observers can read this directly for UI bindings.
    @Published private(set) var entries: [WatchHistoryEntry] = []

    // MARK: Private state

    private var activeLogin: String?
    private var sessionStart: Date?
    private var heartbeatTimer: Timer?

    private let defaults: UserDefaults

    // MARK: Init

    /// Creates a manager backed by the given `UserDefaults` instance.
    /// The default argument uses the standard suite, which is appropriate for
    /// the main application target.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = loadFromDefaults()
    }

    // MARK: Public API

    /// Starts (or resumes) tracking a watch session for `login`.
    ///
    /// Calling this while another channel is already active first flushes the
    /// elapsed time for that channel before switching.
    ///
    /// - Parameters:
    ///   - login: Lowercased Twitch login name.
    ///   - displayName: Human-readable channel name shown in the UI.
    func recordWatch(login: String, displayName: String) {
        let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }

        // Flush the previous session before switching channels.
        if let previous = activeLogin, previous != normalized {
            flushElapsedTime()
        }

        activeLogin = normalized
        sessionStart = Date()

        upsertEntry(
            login: normalized,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            additionalSeconds: 0,
            updateLastWatched: true
        )

        startHeartbeat()
    }

    /// Stops the current watch session and persists any remaining elapsed time.
    ///
    /// Safe to call when no session is active (it becomes a no-op).
    func stopWatch() {
        guard activeLogin != nil else { return }
        flushElapsedTime()
        activeLogin = nil
        sessionStart = nil
        stopHeartbeat()
    }

    /// Returns up to the last 50 entries sorted by `lastWatched` descending.
    func recentHistory() -> [WatchHistoryEntry] {
        entries
    }

    /// Removes all stored watch history from both memory and `UserDefaults`.
    func clearHistory() {
        entries = []
        defaults.removeObject(forKey: Keys.userDefaults)
    }

    // MARK: Private — session bookkeeping

    /// Adds the elapsed time since `sessionStart` to the active entry and
    /// resets the session clock.
    private func flushElapsedTime() {
        guard let login = activeLogin, let start = sessionStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        sessionStart = Date() // reset so the next flush starts from now
        guard elapsed > 0 else { return }
        upsertEntry(
            login: login,
            displayName: nil,
            additionalSeconds: elapsed,
            updateLastWatched: false
        )
    }

    // MARK: Private — entry management

    /// Creates or updates the entry for `login`.
    ///
    /// - Parameters:
    ///   - login: Normalized login key.
    ///   - displayName: When non-nil, updates the stored display name.
    ///   - additionalSeconds: Seconds to add to `totalWatchSeconds`.
    ///   - updateLastWatched: When `true`, sets `lastWatched` to now.
    private func upsertEntry(
        login: String,
        displayName: String?,
        additionalSeconds: TimeInterval,
        updateLastWatched: Bool
    ) {
        var updated = entries

        if let index = updated.firstIndex(where: { $0.channelLogin == login }) {
            if let name = displayName, !name.isEmpty {
                updated[index].channelDisplayName = name
            }
            updated[index].totalWatchSeconds += additionalSeconds
            if updateLastWatched {
                updated[index].lastWatched = Date()
            }
        } else {
            let entry = WatchHistoryEntry(
                channelLogin: login,
                channelDisplayName: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? login,
                lastWatched: Date(),
                totalWatchSeconds: additionalSeconds
            )
            updated.append(entry)
        }

        // Keep the list sorted and capped.
        updated.sort { $0.lastWatched > $1.lastWatched }
        if updated.count > Self.historyLimit {
            updated = Array(updated.prefix(Self.historyLimit))
        }

        entries = updated
        persistToDefaults()
    }

    // MARK: Private — heartbeat timer

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.timerInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushElapsedTime()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: Private — persistence

    private func persistToDefaults() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Keys.userDefaults)
    }

    private func loadFromDefaults() -> [WatchHistoryEntry] {
        guard
            let data = defaults.data(forKey: Keys.userDefaults),
            let decoded = try? JSONDecoder().decode([WatchHistoryEntry].self, from: data)
        else { return [] }
        return decoded.sorted { $0.lastWatched > $1.lastWatched }
    }
}
#endif
