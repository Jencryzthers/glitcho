#if canImport(SwiftUI)
import Foundation
import SwiftUI
import LocalAuthentication

@MainActor
final class RecordingsUnlockManager: ObservableObject {
    @Published private(set) var isUnlocked = false

    private var isAuthenticating = false
    private var lastAttemptAt = Date.distantPast
    private let minimumAttemptInterval: TimeInterval = 1.5

    func authenticateIfNeeded() {
        authenticate(interactive: false)
    }

    func requestAuthentication(onResult: ((Bool) -> Void)? = nil) {
        authenticate(interactive: true, onResult: onResult)
    }

    func lock() {
        isUnlocked = false
    }

    func toggleLock(onResult: ((Bool) -> Void)? = nil) {
        if isUnlocked {
            isUnlocked = false
            onResult?(true)
            return
        }
        authenticate(interactive: true, onResult: onResult)
    }

    private func authenticate(interactive: Bool, onResult: ((Bool) -> Void)? = nil) {
        if isUnlocked {
            onResult?(true)
            return
        }
        guard !isAuthenticating else {
            onResult?(false)
            return
        }
        let now = Date()
        if !interactive, now.timeIntervalSince(lastAttemptAt) < minimumAttemptInterval {
            onResult?(false)
            return
        }
        lastAttemptAt = now

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        context.localizedFallbackTitle = ""
        context.interactionNotAllowed = !interactive
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            onResult?(false)
            return
        }

        isAuthenticating = true
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock protected sections."
        ) { [weak self] success, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.isUnlocked = true
                }
                onResult?(success)
            }
        }
    }
}

#endif
