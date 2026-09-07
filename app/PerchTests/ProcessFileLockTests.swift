import XCTest

@MainActor
final class ProcessFileLockTests: XCTestCase {
    func testOnlyOneInstanceOwnsTheLockAndReleaseAllowsTheNext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PerchLockTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Perch.lock")
        let first = ProcessFileLock()
        let second = ProcessFileLock()
        XCTAssertTrue(first.acquire(at: url))
        XCTAssertFalse(second.acquire(at: url))
        first.release()
        XCTAssertTrue(second.acquire(at: url))
        second.release()
    }

    func testInvalidLockPathRejectsLaunchInsteadOfRunningWithoutALock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PerchLockTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidLock = directory.appendingPathComponent("is-a-directory")
        try FileManager.default.createDirectory(at: invalidLock, withIntermediateDirectories: true)
        XCTAssertFalse(ProcessFileLock().acquire(at: invalidLock))
    }

    func testLockDoesNotFollowOrTruncateASymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PerchLockTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("keep.txt")
        let link = directory.appendingPathComponent("Perch.lock")
        let original = Data("keep this data".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(ProcessFileLock().acquire(at: link))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
