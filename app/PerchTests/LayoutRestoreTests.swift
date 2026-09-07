import CoreGraphics
import Foundation
import XCTest

final class LayoutRestoreTests: XCTestCase {
    @MainActor
    func testRestoreSkipsClosedAppWhenOpeningMissingAppsIsDisabled() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        await MainActor.run { LocalizationManager.shared.selectedLanguage = .english }

        let snapshot = makeSnapshot(bundleIdentifier: "com.example.ClosedApp")
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", windows: [snapshot])
        ]))

        let mover = FakeWindowMover(outcomes: [.appNotRunning])
        let launcher = FakeApplicationLauncher(results: [
            "com.example.ClosedApp": .launched
        ])
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            launchRetryTimeout: 0,
            launchRetryIntervalNanoseconds: 0
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.openedAppCount, 0)
        XCTAssertEqual(result.restoreSummary, "Restored 0/1 window")
        XCTAssertEqual(result.details.first?.outcome, .appNotRunning)
        XCTAssertEqual(result.details.first?.message, "Application is closed.")
        XCTAssertEqual(result.details.first?.didLaunchApplication, false)
        XCTAssertEqual(launcher.launchedBundles, [])
        XCTAssertEqual(mover.moveCount, 1)
    }

    @MainActor
    func testRestoreLaunchesMissingAppAndRetriesMove() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        await MainActor.run { LocalizationManager.shared.selectedLanguage = .english }

        let snapshot = makeSnapshot(bundleIdentifier: "com.example.MissingApp")
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [
                Slot(id: "work", name: "Work", windows: [snapshot])
            ],
            settings: PerchSettings(opensMissingApplicationsOnRestore: true)
        ))

        let mover = FakeWindowMover(outcomes: [.appNotRunning, .success])
        let launcher = FakeApplicationLauncher(results: [
            "com.example.MissingApp": .launched
        ])
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            launchRetryTimeout: 0,
            launchRetryIntervalNanoseconds: 0
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.openedAppCount, 1)
        XCTAssertEqual(result.restoreSummary, "Restored 1/1; opened 1 app")
        XCTAssertEqual(result.details.first?.outcome, .launchedAndRestored)
        XCTAssertEqual(result.details.first?.didLaunchApplication, true)
        XCTAssertEqual(launcher.launchedBundles, ["com.example.MissingApp"])
        XCTAssertEqual(mover.moveCount, 2)
    }

    @MainActor
    func testRestoreReportsAppNotInstalled() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        LocalizationManager.shared.selectedLanguage = .english

        let snapshot = makeSnapshot(bundleIdentifier: "com.example.NotInstalled")
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [
                Slot(id: "work", name: "Work", windows: [snapshot])
            ],
            settings: PerchSettings(opensMissingApplicationsOnRestore: true)
        ))

        let mover = FakeWindowMover(outcomes: [.appNotRunning])
        let launcher = FakeApplicationLauncher(results: [
            "com.example.NotInstalled": .notInstalled
        ])
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            launchRetryTimeout: 0,
            launchRetryIntervalNanoseconds: 0
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.restoreSummary, "Restored 0/1 window")
        XCTAssertEqual(result.details.first?.outcome, .appNotInstalled)
        XCTAssertEqual(result.details.first?.message, "Application is not installed.")
    }

    @MainActor
    func testRestoreLaunchesAppOnceForMultipleMissingWindowsFromSameApp() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let firstSnapshot = makeSnapshot(id: "window-1", bundleIdentifier: "com.example.SharedApp")
        let secondSnapshot = makeSnapshot(id: "window-2", bundleIdentifier: "com.example.SharedApp")
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [
                Slot(id: "work", name: "Work", windows: [firstSnapshot, secondSnapshot])
            ],
            settings: PerchSettings(opensMissingApplicationsOnRestore: true)
        ))

        let mover = FakeWindowMover(outcomes: [
            .appNotRunning,
            .windowNotFound,
            .success
        ])
        let launcher = FakeApplicationLauncher(results: [
            "com.example.SharedApp": .launched
        ])
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            launchRetryTimeout: 0,
            launchRetryIntervalNanoseconds: 0
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.openedAppCount, 1)
        XCTAssertEqual(launcher.launchedBundles, ["com.example.SharedApp"])
        XCTAssertEqual(result.details.map(\.outcome), [.windowNotFound, .launchedAndRestored])
        XCTAssertEqual(result.details.map(\.didLaunchApplication), [true, true])
        XCTAssertEqual(mover.moveCount, 3)
    }

    @MainActor
    func testRestoreDefensivelyHandlesDuplicateMoverResultIDs() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let snapshot = makeSnapshot()
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", windows: [snapshot])
        ]))
        let engine = SlotEngine(
            store: store,
            windowMover: DuplicateResultWindowMover(),
            accessibilityTrusted: { true }
        )

        let result = try await engine.restore(slotID: "work")

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.details.first?.outcome, .restored)
    }

    @MainActor
    func testRestoreRejectsConcurrentWindowOperationAndRecoversAfterCompletion() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(
            slots: [Slot(id: "work", name: "Work", windows: [makeSnapshot()])],
            settings: PerchSettings(opensMissingApplicationsOnRestore: true)
        ))

        let busyOutcomes: [FakeWindowMover.Outcome] = [.appNotRunning]
            + Array(repeating: .windowNotFound, count: 400)
        let mover = FakeWindowMover(outcomes: busyOutcomes)
        let launcher = FakeApplicationLauncher(results: ["com.example.App": .launched])
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            applicationLauncher: launcher,
            accessibilityTrusted: { true },
            launchRetryTimeout: 0.5,
            launchRetryIntervalNanoseconds: 10_000_000
        )

        async let firstRestore = engine.restore(slotID: "work")
        try await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await engine.restore(slotID: "work")
            XCTFail("Expected the concurrent restore to be rejected")
        } catch SlotEngineError.operationInProgress {
            // expected
        }

        do {
            _ = try await engine.save(slotID: "work")
            XCTFail("Expected the concurrent save to be rejected")
        } catch SlotEngineError.operationInProgress {
            // expected
        }

        let firstResult = try await firstRestore
        XCTAssertEqual(firstResult.total, 1)

        // The guard must release after the first restore finishes; the leftover
        // fake outcomes make this restore report misses, but it must not be rejected.
        let secondResult = try await engine.restore(slotID: "work")
        XCTAssertEqual(secondResult.total, 1)
    }

    @MainActor
    func testRestorePreflightRejectionMovesNoWindowsAndReleasesExclusiveGuard() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", windows: [makeSnapshot()])
        ]))
        let mover = FakeWindowMover(outcomes: [.success])
        let engine = SlotEngine(
            store: store,
            windowMover: mover,
            accessibilityTrusted: { true }
        )

        do {
            _ = try await engine.restore(slotID: "work", preflight: { _ in false })
            XCTFail("Expected the automatic restore preflight to reject the operation")
        } catch SlotEngineError.restorePreflightRejected {
            // expected
        }

        XCTAssertEqual(mover.moveCount, 0)

        let result = try await engine.restore(slotID: "work", preflight: { _ in true })
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(mover.moveCount, 1)
    }
}
