import XCTest

@MainActor
final class RestoreInteractionTests: XCTestCase {
    private let displays = [DisplayInfo(id: 1, uuid: "display",
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true)]

    func testProgressIsVisibleBeforeCompletionAndStoppingPreservesUndo() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let originalFrame = fixture.mover.candidates[0].frame
        fixture.mover.pauseAfterFirstMove = true
        let task = Task { try await fixture.engine.restore(slotID: "work") }
        try await waitUntil { fixture.engine.restoreSession.result?.succeeded == 1 }
        XCTAssertTrue(fixture.engine.restoreSession.isRunning)
        XCTAssertEqual(fixture.engine.restoreSession.completedCount, 1)
        fixture.engine.cancelRestore()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let partial = try XCTUnwrap(fixture.engine.restoreSession.result)
        XCTAssertEqual(partial.details.map(\.outcome), [.restored, .cancelled])
        XCTAssertEqual(fixture.mover.movedWindowHashes, [1])
        XCTAssertTrue(fixture.engine.restoreSession.canUndo)

        fixture.mover.pauseAfterFirstMove = false
        let undone = try await fixture.engine.undoLastRestore()
        XCTAssertEqual(undone.succeeded, 1)
        XCTAssertEqual(fixture.mover.candidates[0].frame, originalFrame)
        XCTAssertFalse(fixture.engine.restoreSession.canUndo)
        XCTAssertFalse(fixture.engine.restoreSession.canRetry)
    }

    func testCancellationDuringFrameWriteCanStillBeUndone() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let originalFrame = fixture.mover.candidates[0].frame
        fixture.mover.pauseDuringFirstWrite = true
        let task = Task { try await fixture.engine.restore(slotID: "work") }
        try await waitUntil { fixture.mover.movedWindowHashes.count == 1 }
        fixture.engine.cancelRestore()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(fixture.engine.restoreSession.result?.succeeded, 0)
        XCTAssertTrue(fixture.engine.restoreSession.canUndo)
        fixture.mover.pauseDuringFirstWrite = false
        _ = try await fixture.engine.undoLastRestore()
        XCTAssertEqual(fixture.mover.candidates[0].frame, originalFrame)
    }

    func testRetryDoesNotMoveSuccessfulSiblingOrLetItBeClaimedByAMissingWindow() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let missing = fixture.mover.candidates.removeLast()
        _ = try await fixture.engine.restore(slotID: "work")
        XCTAssertEqual(fixture.engine.restoreSession.result?.succeeded, 1)
        fixture.mover.candidates[0].title = "Second"
        fixture.mover.candidates[0].normalizedTitle = WindowTitleSimilarity.normalize("Second")
        let retry = try await fixture.engine.retryLastRestore()
        XCTAssertEqual(retry.succeeded, 1)
        XCTAssertEqual(fixture.mover.movedWindowHashes, [1])
        XCTAssertTrue(fixture.mover.receivedBatches.last?.contains { !$0.shouldMove && $0.reservation != nil } == true)

        fixture.mover.candidates.append(missing)
        let completed = try await fixture.engine.retryLastRestore()
        XCTAssertEqual(completed.succeeded, 2)
        XCTAssertEqual(fixture.mover.movedWindowHashes, [1, 2])
        XCTAssertEqual(fixture.engine.restoreSession.undoMoves.count, 2)
        _ = try await fixture.engine.undoLastRestore()
        XCTAssertEqual(fixture.mover.candidates.map(\.frame), [CGRect(x: 11, y: 20, width: 600, height: 400), missing.frame])
    }

    func testSingleWindowRetryLeavesOtherFailedWindowsPendingForAnotherAttempt() async throws {
        let fixture = try await fixture(windowCount: 3)
        defer { fixture.remove() }
        let third = fixture.mover.candidates.removeLast()
        let second = fixture.mover.candidates.removeLast()
        _ = try await fixture.engine.restore(slotID: "work")
        fixture.mover.candidates += [second, third]
        let result = try await fixture.engine.retryLastRestore(windowIDs: ["2"])
        XCTAssertEqual(result.details.map(\.isSuccess), [true, true, false])
        XCTAssertEqual(fixture.mover.movedWindowHashes, [1, 2])
        XCTAssertFalse(fixture.mover.receivedBatches.last?.contains { $0.snapshot.id == "3" } == true)
    }

    func testRetryRejectsEditedLayoutAndPreservesPreviousReport() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        fixture.mover.candidates.removeLast()
        let result = try await fixture.engine.restore(slotID: "work")
        try await fixture.store.update { $0.slots[0].windows[1].frame.x = 999 }
        do {
            _ = try await fixture.engine.retryLastRestore()
            XCTFail("A stale report cannot move windows from an edited layout")
        } catch SlotEngineError.layoutChangedSinceRestore { }
        XCTAssertEqual(fixture.engine.restoreSession.result, result)
        XCTAssertEqual(fixture.mover.movedWindowHashes, [1])
        XCTAssertNotNil(fixture.engine.restoreSession.errorMessage)
        XCTAssertTrue(fixture.engine.restoreSession.canUndo)
    }

    func testUndoWillNotMoveAReplacementWindowWithTheSameTitleAndProcessID() async throws {
        let fixture = try await fixture(windowCount: 1)
        defer { fixture.remove() }
        _ = try await fixture.engine.restore(slotID: "work")
        fixture.mover.candidates[0].processLaunchDate = Date()
        fixture.mover.candidates[0].axElementHash = 999
        let result = try await fixture.engine.undoLastRestore()
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(fixture.mover.movedWindowHashes, [1])
    }

    func testUndoRequiresOriginalDisplayGeometryAndRetainsRecoveryWhenUnavailable() async throws {
        let fixture = try await fixture(windowCount: 1)
        defer { fixture.remove() }
        _ = try await fixture.engine.restore(slotID: "work")
        fixture.environment.topology = nil
        do {
            _ = try await fixture.engine.undoLastRestore()
            XCTFail("Must not put windows off-screen on a different display arrangement")
        } catch SlotEngineError.undoDisplayConfigurationChanged { }
        XCTAssertTrue(fixture.engine.restoreSession.canUndo)
        XCTAssertEqual(fixture.mover.movedWindowHashes, [1])
    }

    func testFailedFrameWriteKeepsOriginalPositionForUndo() async throws {
        let fixture = try await fixture(windowCount: 1)
        defer { fixture.remove() }
        let original = fixture.mover.candidates[0].frame
        fixture.mover.failWrites = true
        let result = try await fixture.engine.restore(slotID: "work")
        XCTAssertEqual(result.details.first?.outcome, .frameWriteFailed)
        XCTAssertTrue(fixture.engine.restoreSession.canUndo)
        fixture.mover.failWrites = false
        _ = try await fixture.engine.undoLastRestore()
        XCTAssertEqual(fixture.mover.candidates[0].frame, original)
    }

    func testParentCancellationStopsTheManagedRestoreAndReleasesTheGuard() async throws {
        let fixture = try await fixture(windowCount: 1)
        defer { fixture.remove() }
        fixture.mover.pauseAfterFirstMove = true
        let task = Task { try await fixture.engine.restore(slotID: "work") }
        try await waitUntil { fixture.engine.restoreSession.result?.succeeded == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(fixture.engine.restoreSession.isRunning)
        fixture.mover.pauseAfterFirstMove = false
        _ = try await fixture.engine.restore(slotID: "work")
        XCTAssertEqual(fixture.mover.movedWindowHashes.count, 2)
    }

    func testOpeningAppFromReportIsScopedToTheSelectedFailureAndDoesNotChangeSettings() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let first = makeSnapshot(id: "a", bundleIdentifier: "first.app")
        let second = makeSnapshot(id: "b", bundleIdentifier: "second.app")
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [first, second])]))
        let mover = FakeWindowMover(outcomes: [.appNotRunning, .appNotRunning, .appNotRunning, .success])
        let launcher = FakeApplicationLauncher(results: ["first.app": .launched])
        let engine = SlotEngine(store: store, windowMover: mover, applicationLauncher: launcher,
                                accessibilityTrusted: { true }, capturedTopologyProvider: { nil }, launchRetryTimeout: 0)
        _ = try await engine.restore(slotID: "work")
        let result = try await engine.retryLastRestore(windowIDs: [first.id], openApplications: true)
        XCTAssertEqual(launcher.launchedBundles, [first.bundleIdentifier])
        XCTAssertEqual(result.details.map(\.outcome), [.launchedAndRestored, .appNotRunning])
        let document = try await store.load()
        XCTAssertFalse(document.settings.opensMissingApplicationsOnRestore)
    }

    private func fixture(windowCount: Int = 2) async throws -> Fixture {
        let (directory, url) = makeTemporaryStoreURL()
        let store = try SlotStore(fileURL: url)
        let snapshots = (1...windowCount).map { index in
            var snapshot = makeSnapshot(id: String(index))
            snapshot.windowTitle = ["First", "Second", "Third"][index - 1]
            snapshot.frame.x = Double(index * 200)
            return snapshot
        }
        let topology = DisplayTopologyFingerprint(displays: displays)
        try await store.save(SlotStoreDocument(
            slots: [Slot(id: "work", name: "Work", windows: snapshots, capturedTopology: topology)],
            settings: PerchSettings(stabilizationTimeout: 0, matchStrictness: .strict)
        ))
        let mover = InteractiveWindowMover(snapshots: snapshots)
        let environment = Environment(topology: topology)
        let displays = displays
        let engine = SlotEngine(store: store, windowMover: mover, accessibilityTrusted: { true },
                                displayProvider: { displays }, capturedTopologyProvider: { environment.topology },
                                launchRetryTimeout: 0, launchRetryIntervalNanoseconds: 0)
        return Fixture(directory: directory, store: store, mover: mover, engine: engine, environment: environment)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition())
    }

    private final class Environment {
        var topology: DisplayTopologyFingerprint?
        init(topology: DisplayTopologyFingerprint) { self.topology = topology }
    }

    private struct Fixture {
        let directory: URL
        let store: SlotStore
        let mover: InteractiveWindowMover
        let engine: SlotEngine
        let environment: Environment
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
