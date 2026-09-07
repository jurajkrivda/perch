import XCTest

final class StoreRecoveryTests: XCTestCase {
    func testCorruptOriginalIsDiscoverableAfterRelaunchAndAcknowledgementPreservesBytes() async throws {
        let (directory, file) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{ broken original".utf8)
        try original.write(to: file)
        _ = try await SlotStore(fileURL: file).load()

        let reopenedStore = try SlotStore(fileURL: file)
        let pending = try await reopenedStore.recoveryNotice()
        let notice = try XCTUnwrap(pending)
        XCTAssertEqual(notice.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: notice.files[0]), original)

        try await reopenedStore.acknowledgeRecoveryNotice(notice)
        let reopenedNotice = try await SlotStore(fileURL: file).recoveryNotice()
        XCTAssertNil(reopenedNotice)
        let acknowledged = notice.files[0].appendingPathExtension("acknowledged")
        XCTAssertEqual(try Data(contentsOf: acknowledged), original)
        XCTAssertEqual(try posixPermissions(of: acknowledged), 0o600)
    }

    func testAcknowledgingOldNoticeDoesNotHideANewerCorruption() async throws {
        let (directory, file) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SlotStore(fileURL: file)
        try Data("broken first".utf8).write(to: file)
        _ = try await store.load()
        let firstPending = try await store.recoveryNotice()
        let first = try XCTUnwrap(firstPending)

        try Data("broken second".utf8).write(to: file)
        _ = try await store.load()
        try await store.acknowledgeRecoveryNotice(first)

        let secondPending = try await store.recoveryNotice()
        let second = try XCTUnwrap(secondPending)
        XCTAssertEqual(second.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: second.files[0]), Data("broken second".utf8))
    }

    func testValidStoreHasNoRecoveryNotice() async throws {
        let (directory, file) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: file)
        let beforeSave = try await store.recoveryNotice()
        XCTAssertNil(beforeSave)
        try await store.save(SlotStoreDocument())
        let afterSave = try await store.recoveryNotice()
        XCTAssertNil(afterSave)
    }

    func testNoticeIgnoresSymlinksDirectoriesAndUnrelatedNames() async throws {
        let (directory, file) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let other = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: other)
        let link = directory.appendingPathComponent("slots.json.corrupt-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("slots.json.corrupt-\(UUID())"),
            withIntermediateDirectories: true
        )
        try Data().write(to: directory.appendingPathComponent("slots.json.corrupt-not-a-uuid"))
        let store = try SlotStore(fileURL: file)
        let notice = try await store.recoveryNotice()
        XCTAssertNil(notice)
        try await store.acknowledgeRecoveryNotice(StoreRecoveryNotice(files: [other, link]))
        XCTAssertEqual(try Data(contentsOf: other), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testAcknowledgementFailureKeepsTheOriginalAndNotice() async throws {
        let (directory, file) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("broken".utf8)
        try original.write(to: file)
        _ = try await SlotStore(fileURL: file).load()
        let store = try SlotStore(fileURL: file, fileManager: RejectRecoveryAcknowledgement())
        let pending = try await store.recoveryNotice()
        let notice = try XCTUnwrap(pending)
        do {
            try await store.acknowledgeRecoveryNotice(notice)
            XCTFail("Expected acknowledgement to fail")
        } catch { }
        let afterFailure = try await store.recoveryNotice()
        XCTAssertEqual(afterFailure, notice)
        XCTAssertEqual(try Data(contentsOf: notice.files[0]), original)
    }

    @MainActor
    func testSettingsRetainsRecoveryNoticeAcrossReloadsAndCanAcknowledgeIt() async throws {
        let (directory, file) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: file)
        let model = SettingsModel(slotEngine: SlotEngine(store: try SlotStore(fileURL: file)))
        await model.refreshDocument()
        let notice = try XCTUnwrap(model.recoveryNotice)
        await model.refreshDocument()
        XCTAssertEqual(model.recoveryNotice, notice)
        model.acknowledgeRecoveryNotice()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isAcknowledgingRecovery, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(model.isAcknowledgingRecovery)
        XCTAssertNil(model.recoveryNotice)
        XCTAssertNil(model.recoveryErrorMessage)
    }
}

private final class RejectRecoveryAcknowledgement: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
