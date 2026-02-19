import XCTest

@testable import Glitcho

final class MotionInterpolationHeuristicsTests: XCTestCase {
    func testDecision_UsesBlendPolicyWhenMotionCoherenceIsLow() {
        let decision = MotionInterpolationHeuristics.decision(
            motionMagnitude: 1.6,
            coherence: 0.1,
            configuration: .productionDefault
        )

        XCTAssertFalse(decision.usesOpticalFlowWarp)
        XCTAssertEqual(decision.blendReason, "low_coherence")
    }

    func testDecision_UsesOpticalFlowForModerateCoherentMotion() {
        let decision = MotionInterpolationHeuristics.decision(
            motionMagnitude: 1.2,
            coherence: 0.72,
            configuration: .productionDefault
        )

        XCTAssertTrue(decision.usesOpticalFlowWarp)
        XCTAssertNil(decision.blendReason)
    }
}
