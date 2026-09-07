import CoreGraphics
import Foundation
import XCTest

final class LayoutRestoreRetryTests: XCTestCase {
    @MainActor
    func testContinuouslyChangingTopologyCannotExtendRetryForeverOrReportSuccess() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let snapshot = makeSnapshot(id: "first", bundleIdentifier: "audit.app")
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [Slot(id: "work", name: "Work", windows: [snapshot])],
            settings: PerchSettings(stabilizationTimeout: 0, opensMissingApplicationsOnRestore: true)
        ))
        let mover = FakeWindowMover(outcomes: [.appNotRunning, .success, .success])
        var displayReadCount = 0
        let engine = SlotEngine(
            store: store, windowMover: mover,
            applicationLauncher: FakeApplicationLauncher(results: ["audit.app": .launched]),
            accessibilityTrusted: { true },
            displayProvider: {
                displayReadCount += 1
                return [DisplayInfo(id: 1, uuid: "display", bounds: CGRect(x: displayReadCount, y: 0, width: 1000, height: 800), isMain: true)]
            },
            launchRetryTimeout: 0, launchRetryIntervalNanoseconds: 0
        )
        let result = try await engine.restore(slotID: "work")
        XCTAssertEqual(mover.moveCount, 3)
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.details.first?.outcome, .frameWriteFailed)
    }

    @MainActor
    func testAlreadyRunningAppRetriesWindowsThatAppearLaterWithoutLaunching() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let first = makeSnapshot(id: "first", bundleIdentifier: "audit.app")
        let second = makeSnapshot(id: "second", bundleIdentifier: "audit.app")
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [Slot(id: "work", name: "Work", windows: [first, second])],
            settings: PerchSettings(stabilizationTimeout: 0, opensMissingApplicationsOnRestore: false)
        ))
        let mover = FakeWindowMover(outcomes: [.success, .windowNotFound, .success])
        let launcher = FakeApplicationLauncher(results: [:])
        let engine = SlotEngine(
            store: store, windowMover: mover, applicationLauncher: launcher,
            accessibilityTrusted: { true }, displayProvider: { [] },
            launchRetryTimeout: 0.2, launchRetryIntervalNanoseconds: 0
        )
        let result = try await engine.restore(slotID: "work")
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.details.map(\.outcome), [.restored, .restored])
        XCTAssertEqual(mover.movedSnapshotIDs, ["first", "second", "second"])
        XCTAssertTrue(launcher.launchedBundles.isEmpty)
    }

    @MainActor
    func testLaunchRetryMovesEachWindowOnlyUntilItSucceeds() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let firstSnapshot = makeSnapshot(id: "window-1", bundleIdentifier: "com.example.ProgressiveApp")
        let secondSnapshot = makeSnapshot(id: "window-2", bundleIdentifier: "com.example.ProgressiveApp")
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [Slot(id: "work", name: "Work", windows: [firstSnapshot, secondSnapshot])],
            settings: PerchSettings(opensMissingApplicationsOnRestore: true)
        ))

        let mover = FakeWindowMover(outcomes: [
            .appNotRunning,
            .success,
            .windowNotFound,
            .success
        ])
        let launcher = FakeApplicationLauncher(results: ["com.example.ProgressiveApp": .launched])
        var displayReadCount = 0
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            displayProvider: {
                displayReadCount += 1
                return []
            },
            launchRetryTimeout: 0.2,
            launchRetryIntervalNanoseconds: 0
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.details.map(\.outcome), [.launchedAndRestored, .launchedAndRestored])
        XCTAssertEqual(mover.movedSnapshotIDs, ["window-1", "window-1", "window-2", "window-2"])
        XCTAssertGreaterThanOrEqual(displayReadCount, 3)
    }

    @MainActor
    func testLaunchRetryDoesNotReportTwoSuccessesWhenReservedWindowChangesTitle() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        var firstSnapshot = makeSnapshot(id: "window-1", bundleIdentifier: "com.example.TitleChangingApp")
        firstSnapshot.windowTitle = "First Saved Window"
        var secondSnapshot = makeSnapshot(id: "window-2", bundleIdentifier: "com.example.TitleChangingApp")
        secondSnapshot.windowTitle = "Second Saved Window"
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [Slot(id: "work", name: "Work", windows: [firstSnapshot, secondSnapshot])],
            settings: PerchSettings(opensMissingApplicationsOnRestore: true)
        ))

        let mover = TitleChangingReservationMover()
        let launcher = FakeApplicationLauncher(results: ["com.example.TitleChangingApp": .launched])
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            displayProvider: { [] },
            launchRetryTimeout: 0.015,
            launchRetryIntervalNanoseconds: 1_000_000
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.details.map(\.outcome), [.launchedAndRestored, .windowNotFound])
        XCTAssertEqual(mover.movedSnapshotIDs, ["window-1"])
    }

    @MainActor
    func testLaunchRetryRemapsSuccessfulWindowsOnceWhenDisplayTopologyChanges() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        var firstSnapshot = makeSnapshot(id: "window-1", bundleIdentifier: "com.example.DockingApp")
        firstSnapshot.displayUUID = "DISPLAY"
        firstSnapshot.displayLocalFrame = CodableRect(CGRect(x: 100, y: 100, width: 800, height: 600))
        var secondSnapshot = makeSnapshot(id: "window-2", bundleIdentifier: "com.example.DockingApp")
        secondSnapshot.displayUUID = "DISPLAY"
        secondSnapshot.displayLocalFrame = CodableRect(CGRect(x: 200, y: 150, width: 700, height: 500))

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [Slot(id: "work", name: "Work", windows: [firstSnapshot, secondSnapshot])],
            settings: PerchSettings(opensMissingApplicationsOnRestore: true)
        ))

        let mover = FakeWindowMover(outcomes: [
            .appNotRunning,
            .success,
            .windowNotFound,
            .success,
            .windowNotFound,
            .success
        ])
        let launcher = FakeApplicationLauncher(results: ["com.example.DockingApp": .launched])
        let originalDisplay = DisplayInfo(
            id: 1,
            uuid: "DISPLAY",
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isMain: true
        )
        let movedDisplay = DisplayInfo(
            id: 2,
            uuid: "DISPLAY",
            bounds: CGRect(x: 1000, y: 0, width: 1440, height: 900),
            isMain: true
        )
        var displayReadCount = 0
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            displayProvider: {
                displayReadCount += 1
                return displayReadCount <= 2 ? [originalDisplay] : [movedDisplay]
            },
            launchRetryTimeout: 0.2,
            launchRetryIntervalNanoseconds: 0
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(mover.movedSnapshotIDs, [
            "window-1", // Initial closed-app probe.
            "window-1", "window-2", // First topology.
            "window-1", "window-2", // One remap for the changed topology.
            "window-2" // Same topology: first window stays reserved, not moved again.
        ])
        XCTAssertEqual(
            mover.movedFramesBySnapshotID["window-1"]?.map(\.origin.x),
            [100, 100, 1100]
        )
    }

    @MainActor
    func testLaunchRetryDetectsTopologyChangeDuringSuccessfulMove() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        var snapshot = makeSnapshot(
            id: "window-1",
            bundleIdentifier: "com.example.DockingDuringMoveApp"
        )
        snapshot.displayUUID = "DISPLAY"
        snapshot.displayLocalFrame = CodableRect(
            CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [Slot(id: "work", name: "Work", windows: [snapshot])],
            settings: PerchSettings(opensMissingApplicationsOnRestore: true)
        ))

        let mover = FakeWindowMover(outcomes: [.appNotRunning, .success, .success])
        let launcher = FakeApplicationLauncher(
            results: ["com.example.DockingDuringMoveApp": .launched]
        )
        let originalDisplay = DisplayInfo(
            id: 1,
            uuid: "DISPLAY",
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isMain: true
        )
        let movedDisplay = DisplayInfo(
            id: 2,
            uuid: "DISPLAY",
            bounds: CGRect(x: 1000, y: 0, width: 1440, height: 900),
            isMain: true
        )
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            displayProvider: {
                // The second move completes against topology A, then the
                // completion check observes topology B.
                mover.moveCount >= 2 ? [movedDisplay] : [originalDisplay]
            },
            launchRetryTimeout: 0.2,
            launchRetryIntervalNanoseconds: 0
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(
            mover.movedFramesBySnapshotID["window-1"]?.map(\.origin.x),
            [100, 100, 1100]
        )
    }
}
