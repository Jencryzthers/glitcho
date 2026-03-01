#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import Foundation

@MainActor
final class BiometricHotkeyMonitor {
    private var monitor: Any?
    private var key = ""
    private var modifiers: NSEvent.ModifierFlags = []
    var onTrigger: (() -> Void)?

    func start(key: String, modifiers: NSEvent.ModifierFlags) {
        stop()
        guard !key.isEmpty else { return }

        self.key = key
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.matches(event) else { return event }
            self.onTrigger?()
            return nil
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func matches(_ event: NSEvent) -> Bool {
        let pressed = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard pressed == modifiers else { return false }
        guard
            let eventChars = event.charactersIgnoringModifiers,
            let eventKey = BiometricLockSettings.normalizedHotkeyKey(from: eventChars)
        else {
            return false
        }
        return eventKey == key
    }
}

#endif
