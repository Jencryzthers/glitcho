#if canImport(SwiftUI)
import Foundation

@MainActor
final class SettingsSyncManager {

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var isSyncingFromCloud = false
    private let timestampsKey = "_iCloudSyncTimestamps"

    private static let syncedKeys: Set<String> = [
        "liveAlertsEnabled", "liveAlertsPinnedOnly", "sidebarTintHex",
        "autoRecordOnLive", "autoRecordPinnedOnly", "autoRecordMode",
        "autoRecordDebounceSeconds", "autoRecordCooldownSeconds",
        "autoRecordSelectedChannels", "autoRecordBlockedChannels",
        "recordingConcurrencyLimit", "recordingsRetentionMaxAgeDays",
        "recordingsRetentionKeepLastGlobal", "recordingsRetentionKeepLastPerChannel",
        "motionSmoothening120Enabled", "motionSmoothening.showFPSOverlay",
        "video.show4KOverlay", "video.upscaler4kEnabled", "video.imageOptimizeEnabled",
        "video.aspectCropMode", "video.imageOptimize.contrast", "video.imageOptimize.lighting",
        "video.imageOptimize.denoiser", "video.imageOptimize.neuralClarity",
        "biometricLock.enabled", "biometricLock.hideRecordings",
        "biometricLock.recordingsRequireAuthOnOpen", "biometricLock.hidePinned",
        "biometricLock.protectedStreamers", "biometricLock.autoProtectAllowlisted",
        "biometricLock.hidePrivacySettingsUntilAuthenticated",
        "biometricLock.authenticateOnSettingsOpen",
        "biometricLock.hotkey.key", "biometricLock.hotkey.command",
        "biometricLock.hotkey.shift", "biometricLock.hotkey.option", "biometricLock.hotkey.control",
        "pinnedChannels", "glitcho.chatPreferencesByChannel",
        "player.volume", "player.muted",
        "hybridPlayerHeightRatio", "hybridDetailsCollapsed",
        "motionSmoothening.autoPreset", "motionSmoothening.preset",
        "motionSmoothening.forceFrameGenDebug", "motionSmoothening.lowMotionThreshold",
        "motionSmoothening.highMotionThreshold", "motionSmoothening.extremeMotionThreshold",
        "motionSmoothening.midpointShiftFactor", "motionSmoothening.maxShiftPixels",
        "motionSmoothening.maxInterpolationBudgetMs", "motionSmoothening.slowFramesForGuardrail",
        "motionSmoothening.overloadDurationSeconds", "motionSmoothening.cpuPressurePercent",
        "recordingsLibraryLayoutMode", "recordingsLibrarySortColumn",
        "recordingsLibrarySortAscending", "recordingsLibraryGroupByStreamer",
        "recordingDownloadAutoRetryEnabled", "recordingDownloadAutoRetryLimit",
        "recordingDownloadAutoRetryDelaySeconds",
        "sidebar.pinnedCollapsed", "sidebar.followingCollapsed",
        "settingsExpandedSections",
        "companionAPIEnabled", "companionAPIPort", "companionAPIToken",
        "iCloudSyncPaths"
    ]

    private static let pathKeys: Set<String> = [
        "recordingsDirectory", "streamlinkPath", "ffmpegPath"
    ]

    // MARK: - Public

    func start() {
        cloud.synchronize()
        mergeOnLaunch()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Key helpers

    private var activeKeys: Set<String> {
        var keys = Self.syncedKeys
        if defaults.bool(forKey: "iCloudSyncPaths") {
            keys.formUnion(Self.pathKeys)
        }
        return keys
    }

    private func shouldSync(_ key: String) -> Bool {
        if Self.syncedKeys.contains(key) { return true }
        if Self.pathKeys.contains(key) && defaults.bool(forKey: "iCloudSyncPaths") { return true }
        return false
    }

    // MARK: - Timestamps

    private func localTimestamps() -> [String: TimeInterval] {
        defaults.dictionary(forKey: timestampsKey) as? [String: TimeInterval] ?? [:]
    }

    private func cloudTimestamps() -> [String: TimeInterval] {
        cloud.dictionary(forKey: timestampsKey) as? [String: TimeInterval] ?? [:]
    }

    private func setLocalTimestamp(_ time: TimeInterval, forKey key: String) {
        var ts = localTimestamps()
        ts[key] = time
        defaults.set(ts, forKey: timestampsKey)
    }

    private func setCloudTimestamp(_ time: TimeInterval, forKey key: String) {
        var ts = cloudTimestamps()
        ts[key] = time
        cloud.set(ts, forKey: timestampsKey)
    }

    // MARK: - Initial merge

    private func mergeOnLaunch() {
        let localTS = localTimestamps()
        let cloudTS = cloudTimestamps()
        let now = Date().timeIntervalSinceReferenceDate

        isSyncingFromCloud = true
        defer { isSyncingFromCloud = false }

        for key in activeKeys {
            let localTime = localTS[key] ?? 0
            let cloudTime = cloudTS[key] ?? 0
            let cloudValue = cloud.object(forKey: key)
            let localValue = defaults.object(forKey: key)

            if cloudTime > localTime, let cloudValue {
                defaults.set(cloudValue, forKey: key)
                setLocalTimestamp(cloudTime, forKey: key)
            } else if localValue != nil, localTime >= cloudTime {
                cloud.set(localValue, forKey: key)
                let ts = localTime > 0 ? localTime : now
                setCloudTimestamp(ts, forKey: key)
                if localTime == 0 {
                    setLocalTimestamp(ts, forKey: key)
                }
            }
        }
    }

    // MARK: - Cloud → Local

    @objc private func cloudDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else { return }

        guard reason == NSUbiquitousKeyValueStoreServerChange ||
              reason == NSUbiquitousKeyValueStoreInitialSyncChange else { return }

        let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        let cloudTS = cloudTimestamps()
        let localTS = localTimestamps()

        isSyncingFromCloud = true
        defer { isSyncingFromCloud = false }

        for key in changedKeys where shouldSync(key) {
            let cloudTime = cloudTS[key] ?? Date().timeIntervalSinceReferenceDate
            let localTime = localTS[key] ?? 0

            if cloudTime > localTime, let value = cloud.object(forKey: key) {
                defaults.set(value, forKey: key)
                setLocalTimestamp(cloudTime, forKey: key)
            }
        }
    }

    // MARK: - Local → Cloud

    private var pendingPushKeys = Set<String>()
    private var pushWorkItem: DispatchWorkItem?

    @objc private func localDidChange(_ notification: Notification) {
        guard !isSyncingFromCloud else { return }

        for key in activeKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            let cloudValue = cloud.object(forKey: key)
            if !valuesEqual(value, cloudValue) {
                pendingPushKeys.insert(key)
            }
        }

        guard !pendingPushKeys.isEmpty else { return }

        pushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushPendingPush()
            }
        }
        pushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func flushPendingPush() {
        let keys = pendingPushKeys
        pendingPushKeys.removeAll()
        let now = Date().timeIntervalSinceReferenceDate

        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            cloud.set(value, forKey: key)
            setLocalTimestamp(now, forKey: key)
            setCloudTimestamp(now, forKey: key)
        }
    }

    // MARK: - Comparison

    private func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a as String, b as String): return a == b
        case let (a as Bool, b as Bool): return a == b
        case let (a as Int, b as Int): return a == b
        case let (a as Double, b as Double): return a == b
        case let (a as Data, b as Data): return a == b
        case let (a as NSNumber, b as NSNumber): return a == b
        default:
            let da = try? JSONSerialization.data(withJSONObject: a as Any)
            let db = try? JSONSerialization.data(withJSONObject: b as Any)
            return da == db
        }
    }
}

#endif
