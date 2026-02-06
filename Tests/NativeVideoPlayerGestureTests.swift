import XCTest
import SwiftUI
import AVKit
import AVFoundation
import QuartzCore

@testable import Glitcho

@MainActor
final class NativeVideoPlayerGestureTests: XCTestCase {
    func testApplyZoomAndPan_ClampsZoomAndPanWithinBounds() {
        var isPlayingValue = false
        var zoomValue: CGFloat = 10.0
        var panValue = CGSize(width: 500, height: -500)

        let isPlaying = Binding(get: { isPlayingValue }, set: { isPlayingValue = $0 })
        let zoom = Binding(get: { zoomValue }, set: { zoomValue = $0 })
        let pan = Binding(get: { panValue }, set: { panValue = $0 })

        let player = NativeVideoPlayer(
            url: URL(string: "https://example.com/video.mp4")!,
            isPlaying: isPlaying,
            pipController: nil,
            zoom: zoom,
            pan: pan,
            minZoom: 1.0,
            maxZoom: 4.0
        )

        let coordinator = NativeVideoPlayer.Coordinator(parent: player, pipController: nil)

        let view = AVPlayerView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.wantsLayer = true
        view.layer?.bounds = CGRect(origin: .zero, size: view.bounds.size)

        let videoLayer = AVPlayerLayer()
        videoLayer.frame = view.bounds
        view.layer?.addSublayer(videoLayer)

        coordinator.applyZoomAndPan(to: view)

        // Zoom should clamp to maxZoom (4.0).
        let t = videoLayer.affineTransform()
        XCTAssertEqual(t.a, 4.0, accuracy: 0.0001)
        XCTAssertEqual(t.d, 4.0, accuracy: 0.0001)

        // Pan should clamp based on bounds and zoom.
        // bounds: 200x100, zoom: 4 => maxX=300, maxY=150
        // raw pan: (500, -500) => clamped: (300, -150)
        // center: (100, 50) => expected position: (400, -100)
        XCTAssertEqual(videoLayer.position.x, 400.0, accuracy: 0.0001)
        XCTAssertEqual(videoLayer.position.y, -100.0, accuracy: 0.0001)
    }

    func testApplyZoomAndPan_ClampsToMinZoomAndResetsPanWhenNotZoomed() {
        var isPlayingValue = false
        var zoomValue: CGFloat = 0.5
        var panValue = CGSize(width: 50, height: 25)

        let isPlaying = Binding(get: { isPlayingValue }, set: { isPlayingValue = $0 })
        let zoom = Binding(get: { zoomValue }, set: { zoomValue = $0 })
        let pan = Binding(get: { panValue }, set: { panValue = $0 })

        let player = NativeVideoPlayer(
            url: URL(string: "https://example.com/video.mp4")!,
            isPlaying: isPlaying,
            pipController: nil,
            zoom: zoom,
            pan: pan,
            minZoom: 1.0,
            maxZoom: 4.0
        )

        let coordinator = NativeVideoPlayer.Coordinator(parent: player, pipController: nil)

        let view = AVPlayerView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.wantsLayer = true
        view.layer?.bounds = CGRect(origin: .zero, size: view.bounds.size)

        let videoLayer = AVPlayerLayer()
        videoLayer.frame = view.bounds
        view.layer?.addSublayer(videoLayer)

        coordinator.applyZoomAndPan(to: view)

        // Zoom should clamp up to minZoom (1.0).
        let t = videoLayer.affineTransform()
        XCTAssertEqual(t.a, 1.0, accuracy: 0.0001)
        XCTAssertEqual(t.d, 1.0, accuracy: 0.0001)

        // Pan should be treated as zero at min zoom.
        XCTAssertEqual(videoLayer.position.x, 100.0, accuracy: 0.0001)
        XCTAssertEqual(videoLayer.position.y, 50.0, accuracy: 0.0001)
    }
}
