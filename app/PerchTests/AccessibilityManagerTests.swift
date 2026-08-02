import Foundation
import XCTest

final class AccessibilityManagerTests: XCTestCase {
    func testRedactedPathForLoggingDoesNotExposeHomeDirectory() {
        let homePath = NSHomeDirectory()
            .appending("/Library/Developer/Xcode/DerivedData/Perch/Build/Products/Debug/Perch.app")

        let redactedPath = AccessibilityManager.redactedPathForLogging(homePath)

        XCTAssertFalse(redactedPath.contains(NSHomeDirectory()))
        XCTAssertEqual(redactedPath, "~/.../Perch.app")
    }

    func testRedactedPathForLoggingKeepsApplicationsContext() {
        let redactedPath = AccessibilityManager.redactedPathForLogging("/Applications/Perch.app")

        XCTAssertEqual(redactedPath, "/Applications/Perch.app")
    }

    func testRelaunchArgumentsWaitForOldProcessAndPassValuesPositionally() {
        let arguments = AccessibilityManager.relaunchArguments(
            processIdentifier: 4242,
            bundlePath: "/Applications/My Perch.app"
        )

        XCTAssertEqual(arguments.count, 5)
        XCTAssertEqual(arguments[0], "-c")
        XCTAssertEqual(arguments[2], "perch-relaunch")
        XCTAssertEqual(arguments[3], "4242")
        XCTAssertEqual(arguments[4], "/Applications/My Perch.app")

        let script = arguments[1]
        XCTAssertTrue(script.contains("kill -0 \"$1\""), "script must wait for the old PID to exit")
        XCTAssertTrue(script.contains("/usr/bin/open -n \"$2\""), "script must reopen the bundle path argument")
        XCTAssertFalse(script.contains("4242"), "PID must not be interpolated into the script")
        XCTAssertFalse(script.contains("My Perch.app"), "bundle path must not be interpolated into the script")
    }

    func testRedactedPathForLoggingRedactsTemporaryDirectory() {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("Perch.app")
            .path

        let redactedPath = AccessibilityManager.redactedPathForLogging(tempPath)

        XCTAssertEqual(redactedPath, "<temporary>/Perch.app")
    }
}
