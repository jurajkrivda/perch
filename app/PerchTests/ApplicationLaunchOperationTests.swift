import XCTest

@MainActor
final class ApplicationLaunchOperationTests: XCTestCase {
    func testCompletedLaunchReturnsItsResult() async throws {
        let result = try await ApplicationLaunchOperation.wait(
            timeout: .seconds(1), timeoutMessage: "timeout"
        ) { complete in complete(.launched) }
        XCTAssertEqual(result, .launched)
    }

    func testMissingSystemCallbackHasABoundedWait() async throws {
        let result = try await ApplicationLaunchOperation.wait(
            timeout: .milliseconds(5), timeoutMessage: "timeout"
        ) { _ in }
        XCTAssertEqual(result, .failed("timeout"))
    }

    func testAlreadyCancelledRequestDoesNotStartTheApplication() async throws {
        var didStart = false
        let task = Task {
            try await ApplicationLaunchOperation.wait(
                timeout: .seconds(60), timeoutMessage: "timeout"
            ) { _ in didStart = true }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation before launch")
        } catch is CancellationError { }
        XCTAssertFalse(didStart)
    }

    func testCancellationEndsWaitAndLateCallbackIsIgnored() async throws {
        var completion: ApplicationLaunchOperation.Completion?
        let task = Task {
            try await ApplicationLaunchOperation.wait(
                timeout: .seconds(60), timeoutMessage: "timeout"
            ) { completion = $0 }
        }
        try await waitUntil { completion != nil }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        completion?(.launched)
        await Task.yield()
    }

    func testLateAndRepeatedCallbackCannotReplaceATimeout() async throws {
        var completion: ApplicationLaunchOperation.Completion?
        let result = try await ApplicationLaunchOperation.wait(
            timeout: .milliseconds(5), timeoutMessage: "timeout"
        ) { completion = $0 }
        completion?(.launched)
        completion?(.failed("late"))
        await Task.yield()
        XCTAssertEqual(result, .failed("timeout"))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition())
    }
}
