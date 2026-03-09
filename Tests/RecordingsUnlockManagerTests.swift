import XCTest
import LocalAuthentication
@testable import Glitcho

final class RecordingsUnlockManagerTests: XCTestCase {
    func testAuthenticationPolicy_InteractiveUsesPasswordCapablePolicy() {
        XCTAssertEqual(
            RecordingsUnlockManager.authenticationPolicy(interactive: true),
            .deviceOwnerAuthentication
        )
    }

    func testAuthenticationPolicy_NonInteractiveUsesBiometricOnlyPolicy() {
        XCTAssertEqual(
            RecordingsUnlockManager.authenticationPolicy(interactive: false),
            .deviceOwnerAuthenticationWithBiometrics
        )
    }
}
