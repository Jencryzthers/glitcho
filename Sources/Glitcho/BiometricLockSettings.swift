#if canImport(SwiftUI)
import Foundation

enum BiometricLockSettings {
    static let enabledStorageKey = "biometricLock.enabled"
    static let hideRecordingsStorageKey = "biometricLock.hideRecordings"
    static let recordingsRequireAuthOnOpenStorageKey = "biometricLock.recordingsRequireAuthOnOpen"
    static let hidePinnedStorageKey = "biometricLock.hidePinned"
    static let hideRecentStorageKey = "biometricLock.hideRecent"
    static let protectedStreamersStorageKey = "biometricLock.protectedStreamers"
    static let autoProtectAllowlistedStorageKey = "biometricLock.autoProtectAllowlisted"
    static let hidePrivacySettingsUntilAuthenticatedStorageKey = "biometricLock.hidePrivacySettingsUntilAuthenticated"
    static let authenticateOnSettingsOpenStorageKey = "biometricLock.authenticateOnSettingsOpen"
    static let hotkeyKeyStorageKey = "biometricLock.hotkey.key"
    static let hotkeyCommandStorageKey = "biometricLock.hotkey.command"
    static let hotkeyShiftStorageKey = "biometricLock.hotkey.shift"
    static let hotkeyOptionStorageKey = "biometricLock.hotkey.option"
    static let hotkeyControlStorageKey = "biometricLock.hotkey.control"

    static let defaultHotkeyKey = "l"
    static let defaultHotkeyCommand = true
    static let defaultHotkeyShift = true
    static let defaultHotkeyOption = false
    static let defaultHotkeyControl = false
    static let defaultRecordingsRequireAuthOnOpen = false
    static let defaultAutoProtectAllowlisted = false
    static let defaultHidePrivacySettingsUntilAuthenticated = false

    static func normalizedHotkeyKey(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            return String(scalar).lowercased()
        }
        return nil
    }

    static func normalizedHotkeyInput(_ raw: String) -> String {
        normalizedHotkeyKey(from: raw) ?? defaultHotkeyKey
    }

    static func hotkeyDisplay(
        keyRaw: String,
        useCommand: Bool,
        useShift: Bool,
        useOption: Bool,
        useControl: Bool
    ) -> String {
        let key = (normalizedHotkeyKey(from: keyRaw) ?? defaultHotkeyKey).uppercased()
        var parts: [String] = []
        if useCommand { parts.append("Cmd") }
        if useShift { parts.append("Shift") }
        if useOption { parts.append("Option") }
        if useControl { parts.append("Control") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

#endif
