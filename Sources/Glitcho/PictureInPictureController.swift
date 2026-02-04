#if canImport(SwiftUI)
import AppKit
import AVKit

final class PictureInPictureController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var isAvailable = false

    private weak var playerView: AVPlayerView?
    private var pipController: AVPictureInPictureController?

    func attach(_ view: AVPlayerView) {
        playerView = view
        configure(view)
    }

    func detach(_ view: AVPlayerView) {
        guard playerView === view else { return }
        playerView = nil
        isAvailable = false
        pipController = nil
    }

    func toggle() {
        if let pipController {
            if pipController.isPictureInPictureActive {
                pipController.stopPictureInPicture()
            } else {
                pipController.startPictureInPicture()
            }
            return
        }

        guard let view = playerView else { return }
        let toggleSelector = NSSelectorFromString("togglePictureInPicture:")
        if view.responds(to: toggleSelector) {
            view.perform(toggleSelector, with: nil)
            return
        }
        let startSelector = NSSelectorFromString("startPictureInPicture")
        if view.responds(to: startSelector) {
            view.perform(startSelector)
        }
    }

    private func configure(_ view: AVPlayerView) {
        var available = view.responds(to: NSSelectorFromString("togglePictureInPicture:"))
        if view.responds(to: NSSelectorFromString("setAllowsPictureInPicturePlayback:")) {
            view.setValue(true, forKey: "allowsPictureInPicturePlayback")
            available = true
        }
        if view.responds(to: NSSelectorFromString("setPictureInPictureButtonShown:")) {
            view.setValue(true, forKey: "pictureInPictureButtonShown")
        }
        if view.responds(to: NSSelectorFromString("setShowsPictureInPictureButton:")) {
            view.setValue(true, forKey: "showsPictureInPictureButton")
        }
        if let controller = view.value(forKey: "pictureInPictureController") as? AVPictureInPictureController {
            pipController = controller
            if controller.delegate == nil {
                controller.delegate = self
            }
            available = true
        }
        isAvailable = available
    }
}

#endif
