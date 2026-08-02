import ServiceManagement
import XCTest

final class LaunchAtLoginTests: XCTestCase {
    func testEnabledAndRequiresApprovalAreActiveRegistrations() {
        XCTAssertTrue(LaunchAtLogin.isRegistrationActive(.enabled))
        XCTAssertTrue(LaunchAtLogin.isRegistrationActive(.requiresApproval))
    }

    func testNotRegisteredAndNotFoundAreInactiveRegistrations() {
        XCTAssertFalse(LaunchAtLogin.isRegistrationActive(.notRegistered))
        XCTAssertFalse(LaunchAtLogin.isRegistrationActive(.notFound))
    }
}
