import XCTest
@testable import Glitcho

final class MotionSmootheningCapabilityTests: XCTestCase {
    func testEvaluate_DisablesWhenOpticalFlowUnavailable() {
        let capability = MotionSmootheningCapability.evaluate(environment: .init(
            refreshRate: 144,
            hasMetalDevice: true,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            supportsAIInterpolation: false
        ))

        XCTAssertFalse(capability.supported)
        XCTAssertFalse(capability.aiInterpolationSupported)
        XCTAssertTrue(capability.reason.contains("AI interpolation"))
    }

    func testEvaluate_EnablesWhenAllRequirementsSatisfied() {
        let capability = MotionSmootheningCapability.evaluate(environment: .init(
            refreshRate: 120,
            hasMetalDevice: true,
            lowPowerModeEnabled: false,
            thermalState: .fair,
            supportsAIInterpolation: true
        ))

        XCTAssertTrue(capability.supported)
        XCTAssertTrue(capability.aiInterpolationSupported)
        XCTAssertEqual(capability.maxRefreshRate, 120)
    }

    func testEvaluate_DisablesWhenLowPowerModeEnabledEvenIfAIAvailable() {
        let capability = MotionSmootheningCapability.evaluate(environment: .init(
            refreshRate: 120,
            hasMetalDevice: true,
            lowPowerModeEnabled: true,
            thermalState: .nominal,
            supportsAIInterpolation: true
        ))

        XCTAssertFalse(capability.supported)
        XCTAssertTrue(capability.aiInterpolationSupported)
        XCTAssertTrue(capability.reason.contains("Low Power Mode"))
    }

    func testTargetRefreshRate_CapsAt120WhenDisplaySupportsMore() {
        let capability = MotionSmootheningCapability(
            supported: true,
            aiInterpolationSupported: true,
            maxRefreshRate: 144,
            reason: "ok"
        )

        XCTAssertEqual(capability.targetRefreshRate, 120)
    }

    func testTargetRefreshRate_FloorsAt60WhenDisplayReportsLess() {
        let capability = MotionSmootheningCapability(
            supported: true,
            aiInterpolationSupported: true,
            maxRefreshRate: 48,
            reason: "ok"
        )

        XCTAssertEqual(capability.targetRefreshRate, 60)
    }
}
