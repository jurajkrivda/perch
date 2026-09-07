import XCTest

@MainActor
final class SettingsModelTests: XCTestCase {
    func testRapidSettingChangesPersistTheLatestValueForEveryControl() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = try SlotStore(fileURL: fileURL)
        let model = SettingsModel(slotEngine: SlotEngine(store: store))
        await model.refreshDocument()

        model.updateMenuBarLabelVisibility(false)
        model.updateAutoRestoreMode(.automatic)
        model.updateMenuBarLabelVisibility(true)
        model.updateMissingApplicationsRestoreBehavior(true)
        model.updateAutoRestoreMode(.off)
        model.updateAutoRestoreSettleTimeout(20)
        try await waitUntil {
            model.document.settings.autoRestoreSettleTimeout == 20
        }

        let document = try await store.load()
        XCTAssertTrue(document.settings.showsMenuBarLabel)
        XCTAssertTrue(document.settings.opensMissingApplicationsOnRestore)
        XCTAssertEqual(document.settings.autoRestoreMode, .off)
        XCTAssertEqual(model.autoRestoreMode, .off)
        XCTAssertTrue(model.showsMenuBarLabel)
    }

    func testFailedSettingsWriteRollsBackControlAndKeepsErrorVisible() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let initialStore = try SlotStore(fileURL: fileURL)
        try await initialStore.save(SlotStoreDocument())
        let store = try SlotStore(fileURL: fileURL, fileManager: RejectingWriteFileManager())
        let model = SettingsModel(slotEngine: SlotEngine(store: store))
        await model.refreshDocument()

        model.updateMenuBarLabelVisibility(false)
        try await waitUntil { model.errorMessage != nil }

        XCTAssertTrue(model.showsMenuBarLabel)
        XCTAssertFalse(try XCTUnwrap(model.errorMessage).isEmpty)
        let document = try await initialStore.load()
        XCTAssertTrue(document.settings.showsMenuBarLabel)
    }

    func testNonFiniteTimeoutCannotReachPersistenceOrBreakTheStepper() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = try SlotStore(fileURL: fileURL)
        let model = SettingsModel(slotEngine: SlotEngine(store: store))
        await model.refreshDocument()
        model.updateAutoRestoreSettleTimeout(.nan)
        model.updateAutoRestoreSettleTimeout(.infinity)
        XCTAssertEqual(model.autoRestoreSettleTimeout, 10)
        XCTAssertNil(model.errorMessage)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition())
    }
}

/// Real reads and validation, with only the save's directory creation failing.
/// This reproduces the former error-clearing bug after a successful reload.
private final class RejectingWriteFileManager: FileManager {
    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
