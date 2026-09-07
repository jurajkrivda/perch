import CoreGraphics
import Foundation
import XCTest

final class SlotEngineTests: XCTestCase {
    @MainActor
    func testSavePersistsCurrentDisplayTopology() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let snapshot = makeSnapshot()
        let displays = [
            DisplayInfo(
                id: 10,
                uuid: "external-display",
                bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                isMain: false
            ),
            DisplayInfo(
                id: 11,
                uuid: "built-in-display",
                bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                isMain: true
            )
        ]
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work")]))
        let engine = SlotEngine(
            store: store,
            snapshotter: SuccessfulWindowSnapshotter(snapshots: [snapshot]),
            displayProvider: { displays },
            capturedTopologyProvider: {
                DisplayTopologyFingerprint(displays: displays)
            }
        )

        _ = try await engine.save(slotID: "work")
        let savedDocument = try await store.load()
        let savedSlot = try XCTUnwrap(savedDocument.slots.first)

        XCTAssertEqual(savedSlot.windows, [snapshot])
        XCTAssertEqual(
            savedSlot.capturedTopology,
            DisplayTopologyFingerprint(displays: displays)
        )
    }

    @MainActor
    func testSaveClearsStaleTopologyWhenCurrentIdentityIsIncomplete() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let staleTopology = DisplayTopologyFingerprint(entries: [
            .init(
                uuid: "old-display",
                bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                isMain: true
            )
        ])
        let snapshot = makeSnapshot()
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(
                id: "work",
                name: "Work",
                windows: [makeSnapshot(id: "old-window")],
                capturedTopology: staleTopology
            )
        ]))
        let engine = SlotEngine(
            store: store,
            snapshotter: SuccessfulWindowSnapshotter(snapshots: [snapshot]),
            capturedTopologyProvider: { nil }
        )

        _ = try await engine.save(slotID: "work")
        let savedDocument = try await store.load()
        let savedSlot = try XCTUnwrap(savedDocument.slots.first)

        XCTAssertEqual(savedSlot.windows, [snapshot])
        XCTAssertNil(savedSlot.capturedTopology)
    }

    @MainActor
    func testIncompleteAccessibilityCaptureDoesNotOverwriteSavedLayout() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let previousSnapshot = makeSnapshot(id: "previous-window")
        let previousSaveDate = Date(timeIntervalSince1970: 1_700_000_000)
        let originalDocument = SlotStoreDocument(slots: [
            Slot(
                id: "work",
                name: "Work",
                lastSaved: previousSaveDate,
                windows: [previousSnapshot]
            )
        ])
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(originalDocument)
        let engine = SlotEngine(
            store: store,
            snapshotter: IncompleteWindowSnapshotter(processIdentifier: 4242)
        )

        do {
            _ = try await engine.save(slotID: "work")
            XCTFail("Expected incomplete Accessibility capture to abort the save")
        } catch WindowSnapshotterError.incompleteAccessibilityRead(let processIdentifier) {
            XCTAssertEqual(processIdentifier, 4242)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let persistedDocument = try await store.load()
        XCTAssertEqual(persistedDocument, originalDocument)
    }

    @MainActor
    func testSaveDuringDisplayChangePreservesPreviousLayout() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let snapshot = makeSnapshot(id: "old", bundleIdentifier: "audit.app")
        let store = try SlotStore(fileURL: fileURL)
        let original = SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [snapshot])])
        try await store.save(original)
        var readCount = 0
        let engine = SlotEngine(
            store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: []),
            capturedTopologyProvider: {
                readCount += 1
                return DisplayTopologyFingerprint(entries: [
                    .init(uuid: "display-\(readCount)", bounds: CGRect(x: 0, y: 0, width: 100, height: 100), isMain: true)
                ])
            }
        )
        do {
            _ = try await engine.save(slotID: "work")
            XCTFail("An inconsistent capture must not overwrite the saved layout")
        } catch SlotEngineError.displayConfigurationChanged { }
        let persisted = try await store.load()
        XCTAssertEqual(persisted, original)
    }

    @MainActor
    func testSharedEngineReturnsSameInstance() throws {
        let first = try SlotEngine.shared()
        let second = try SlotEngine.shared()
        XCTAssertTrue(first === second)
    }
}
