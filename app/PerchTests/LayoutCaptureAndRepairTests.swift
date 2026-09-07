import XCTest

@MainActor
final class LayoutCaptureAndRepairTests: XCTestCase {
    func testCreateCapturesWindowsAndTopologyInASingleSavedLayout() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let topology = DisplayTopologyFingerprint(entries: [
            .init(uuid: "display", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true)
        ])
        let engine = SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: [makeSnapshot()]),
                                capturedTopologyProvider: { topology })
        let layout = try await engine.createLayoutFromCurrentWindows(name: "  New Layout  ")
        let document = try await store.load()
        let saved = try XCTUnwrap(document.slots.first(where: { $0.id == layout.id }))
        XCTAssertEqual(saved.name, "New Layout")
        XCTAssertEqual(saved.windows, [makeSnapshot()])
        XCTAssertEqual(saved.capturedTopology, topology)
        XCTAssertNotNil(saved.lastSaved)
    }

    func testEmptyCaptureAndFailedCaptureDoNotLeaveEmptyRecords() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        try await store.save(SlotStoreDocument(slots: []))
        let empty = SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: []))
        do {
            _ = try await empty.createLayoutFromCurrentWindows(name: "Empty")
            XCTFail("A capture action must not silently create a placeholder")
        } catch SlotEngineError.noWindowsToCapture { }
        let failed = SlotEngine(store: store, snapshotter: IncompleteWindowSnapshotter(processIdentifier: 1))
        do {
            _ = try await failed.createLayoutFromCurrentWindows(name: "Failed")
            XCTFail("Incomplete captures must not be saved")
        } catch WindowSnapshotterError.incompleteAccessibilityRead { }
        let document = try await store.load()
        XCTAssertTrue(document.slots.isEmpty)
    }

    func testDisplayChangeDuringCreateLeavesDocumentUnchanged() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let original = SlotStoreDocument(slots: [])
        try await store.save(original)
        var reads = 0
        let engine = SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: [makeSnapshot()]),
                                capturedTopologyProvider: {
            reads += 1
            return DisplayTopologyFingerprint(entries: [
                .init(uuid: "display-\(reads)", bounds: CGRect(x: 0, y: 0, width: 100, height: 100), isMain: true)
            ])
        })
        do {
            _ = try await engine.createLayoutFromCurrentWindows(name: "Unstable")
            XCTFail("The display arrangement must be consistent with the saved windows")
        } catch SlotEngineError.displayConfigurationChanged { }
        let document = try await store.load()
        XCTAssertEqual(document, original)
    }

    func testSettingsCreateClearsNameOnlyAfterSuccessfulCapture() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let engine = SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: [makeSnapshot()]),
                                capturedTopologyProvider: { nil })
        let model = SettingsModel(slotEngine: engine)
        model.newLayoutName = "Captured"
        model.createLayout()
        while model.isCreatingLayout { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(model.newLayoutName, "")
        XCTAssertEqual(model.document.slots.last?.windows, [makeSnapshot()])
        XCTAssertNil(model.errorMessage)

        let failing = SettingsModel(slotEngine: SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: [])))
        failing.newLayoutName = "Keep this name"
        failing.createLayout()
        while failing.isCreatingLayout { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(failing.newLayoutName, "Keep this name")
        XCTAssertNotNil(failing.errorMessage)
    }

    func testRepairPreservesDestinationCreatesHistoryAndAllowsRetryFromTheReport() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let original = makeSnapshot()
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [original])]))
        var candidate = original
        candidate.windowTitle = "New title"
        candidate.cgWindowID = 55
        candidate.frame.x = 900
        let engine = SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: [candidate]),
                                windowMover: FakeWindowMover(outcomes: [.windowNotFound, .windowNotFound, .success]),
                                accessibilityTrusted: { true }, capturedTopologyProvider: { nil }, launchRetryTimeout: 0)
        _ = try await engine.restore(slotID: "work")
        try await engine.reassignWindow(layoutID: "work", windowID: original.id, to: candidate)
        let document = try await store.load()
        XCTAssertEqual(document.slots[0].windows[0].frame, original.frame)
        XCTAssertEqual(document.slots[0].windows[0].windowTitle, candidate.windowTitle)
        XCTAssertEqual(document.slots[0].windows[0].cgWindowID, candidate.cgWindowID)
        let history = try await engine.layoutHistory(layoutID: "work")
        XCTAssertEqual(history.first?.layout.windows, [original])
        let retry = try await engine.retryLastRestore()
        XCTAssertEqual(retry.succeeded, 1)
    }

    func testRepairRejectsAnotherApplicationsWindowAndAlreadyAssignedWindow() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let first = makeSnapshot(id: "first")
        var second = makeSnapshot(id: "second")
        second.cgWindowID = 77
        let original = SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [first, second])])
        try await store.save(original)
        let foreign = makeSnapshot(bundleIdentifier: "another.app")
        let engine = SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: [second, foreign]))
        do {
            try await engine.reassignWindow(layoutID: "work", windowID: first.id, to: second)
            XCTFail("Two saved positions cannot claim the same open window")
        } catch SlotEngineError.windowAlreadyAssigned { }
        do {
            try await engine.reassignWindow(layoutID: "work", windowID: first.id, to: foreign)
            XCTFail("The chosen window must belong to the same application")
        } catch SlotEngineError.repairWindowUnavailable { }
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, original)
    }

    func testRepairDoesNotClaimToResolveIdenticalWindowsWithoutDistinctIdentities() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let first = makeSnapshot()
        var indistinguishable = first
        indistinguishable.id = "another-live-window"
        indistinguishable.frame.x = 600
        let original = SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [first])])
        try await store.save(original)
        let engine = SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: [first, indistinguishable]))
        do {
            try await engine.reassignWindow(layoutID: "work", windowID: first.id, to: indistinguishable)
            XCTFail("Saving identical metadata cannot resolve an ambiguous assignment")
        } catch SlotEngineError.repairWindowUnavailable { }
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, original)
    }
}
