import XCTest

final class DisplayStabilizerTests: XCTestCase {
    func testTimeoutIsNotReportedAsStable() async {
        let stabilizer = DisplayStabilizer()
        await stabilizer.markChanged()
        let stable = await stabilizer.waitForStable(quietPeriod: 30, timeout: 0)
        XCTAssertFalse(stable)
    }

    func testAlreadyQuietDisplayCanCompleteWithoutWaiting() async {
        let stabilizer = DisplayStabilizer()
        let stable = await stabilizer.waitForStable(quietPeriod: 1, timeout: 0)
        XCTAssertTrue(stable)
    }

    func testCancellationIsNotReportedAsStable() async {
        let stabilizer = DisplayStabilizer()
        let task = Task {
            await Task.yield()
            return await stabilizer.waitForStable(quietPeriod: 0, timeout: 30)
        }
        task.cancel()
        let stable = await task.value
        XCTAssertFalse(stable)
    }
}
