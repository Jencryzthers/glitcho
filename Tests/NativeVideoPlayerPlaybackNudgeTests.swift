import XCTest

@testable import Glitcho

final class NativeVideoPlayerPlaybackNudgeTests: XCTestCase {
    private typealias Signature = NativeVideoPlayer.Coordinator.MotionPipelineSignature

    func testShouldNudge_WhenPipelineFirstBecomesEnabledAndPlaying() {
        let next = Signature(
            processingEnabled: true,
            interpolationEnabled: false,
            upscalerEnabled: true,
            imageOptimizeEnabled: false,
            itemID: nil
        )

        let result = NativeVideoPlayer.Coordinator.shouldNudgePlaybackAfterPipelineChange(
            previous: nil,
            next: next,
            isPlaying: true
        )

        XCTAssertTrue(result)
    }

    func testShouldNotNudge_WhenPlaybackIsPaused() {
        let previous = Signature(
            processingEnabled: false,
            interpolationEnabled: false,
            upscalerEnabled: false,
            imageOptimizeEnabled: false,
            itemID: nil
        )
        let next = Signature(
            processingEnabled: true,
            interpolationEnabled: true,
            upscalerEnabled: false,
            imageOptimizeEnabled: false,
            itemID: nil
        )

        let result = NativeVideoPlayer.Coordinator.shouldNudgePlaybackAfterPipelineChange(
            previous: previous,
            next: next,
            isPlaying: false
        )

        XCTAssertFalse(result)
    }

    func testShouldNudge_WhenEnabledPipelineModeChanges() {
        let previous = Signature(
            processingEnabled: true,
            interpolationEnabled: true,
            upscalerEnabled: false,
            imageOptimizeEnabled: false,
            itemID: nil
        )
        let next = Signature(
            processingEnabled: true,
            interpolationEnabled: false,
            upscalerEnabled: true,
            imageOptimizeEnabled: false,
            itemID: nil
        )

        let result = NativeVideoPlayer.Coordinator.shouldNudgePlaybackAfterPipelineChange(
            previous: previous,
            next: next,
            isPlaying: true
        )

        XCTAssertTrue(result)
    }

    func testShouldNotNudge_WhenSignatureIsUnchanged() {
        let signature = Signature(
            processingEnabled: true,
            interpolationEnabled: false,
            upscalerEnabled: true,
            imageOptimizeEnabled: false,
            itemID: nil
        )

        let result = NativeVideoPlayer.Coordinator.shouldNudgePlaybackAfterPipelineChange(
            previous: signature,
            next: signature,
            isPlaying: true
        )

        XCTAssertFalse(result)
    }
}
