#if canImport(SwiftUI)
import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
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
        }
    }
}

#endif
