import CoreGraphics
import Foundation
import XCTest

final class SlotStoreTests: XCTestCase {
    func testRoundTripPreservesSlotsWindowsAndSettings() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let capturedAt = Date(timeIntervalSince1970: 1_779_190_400)
        let snapshot = WindowSnapshot(
            id: "window-1",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Apple - Safari",
            frame: CodableRect(CGRect(x: 100, y: 50, width: 1200, height: 800)),
            displayUUID: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            displayLocalFrame: CodableRect(x: 20, y: 30, width: 1200, height: 800),
            windowRole: "AXWindow",
            processIdentifier: 1234,
            capturedAt: capturedAt,
            cgWindowID: 99,
            accessibilityIdentifier: "main-window"
        )

        var slots = Slot.defaultSlots
        slots[0].lastSaved = capturedAt
        slots[0].windows = [snapshot]

        let document = SlotStoreDocument(
            slots: slots,
            settings: PerchSettings(
                stabilizationTimeout: 3.5,
                retryAttempts: 4,
                matchStrictness: .strict,
                opensMissingApplicationsOnRestore: true
            )
        )

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(document)

        let loadedDocument = try await store.load()

        XCTAssertEqual(loadedDocument, document)
        XCTAssertEqual(loadedDocument.slots[0].windows[0].cgWindowID, 99)
        XCTAssertEqual(loadedDocument.slots[0].windows[0].accessibilityIdentifier, "main-window")
        XCTAssertEqual(loadedDocument.slots.map(\.name), ["Work", "Focus", "Meeting"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(fileURL.path).tmp"))
        XCTAssertEqual(try posixPermissions(of: directoryURL), 0o700)
        XCTAssertEqual(try posixPermissions(of: fileURL), 0o600)
    }

    func testAutoRestoreSettingsUseSafeDefaults() {
        let settings = PerchSettings()

        XCTAssertEqual(settings.autoRestoreMode, .prompt)
        XCTAssertEqual(settings.autoRestoreSettleTimeout, 10)
    }

    func testSaveRejectsAutoRestoreSettleTimeoutOutsideAllowedRange() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        var document = SlotStoreDocument()
        document.settings.autoRestoreSettleTimeout = 60.1

        do {
            try await store.save(document)
            XCTFail("Expected automatic restore settle timeout validation to fail.")
        } catch SlotStoreDocument.ValidationError.autoRestoreSettleTimeoutOutOfRange(let timeout) {
            XCTAssertEqual(timeout, 60.1)
        }
    }

    func testLoadQuarantinesSemanticallyInvalidDocument() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let invalidJSON = """
        {
          "version": 2,
          "settings": {},
          "slots": [
            { "id": "duplicate", "name": "One", "windows": [] },
            { "id": "duplicate", "name": "Two", "windows": [] }
          ]
        }
        """
        try Data(invalidJSON.utf8).write(to: fileURL)

        let document = try await SlotStore(fileURL: fileURL).load()

        XCTAssertEqual(document, SlotStoreDocument())
        let contents = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(contents[0].hasPrefix("\(SlotStore.fileName).corrupt-"))
    }

    func testSaveRejectsInvalidRetryBundleAndFrameWithoutOverwritingStore() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        let original = SlotStoreDocument()
        try await store.save(original)
        let originalData = try Data(contentsOf: fileURL)

        var invalidRetry = original
        invalidRetry.settings.retryAttempts = 0
        do {
            try await store.save(invalidRetry)
            XCTFail("Expected retry bounds validation to fail.")
        } catch SlotStoreDocument.ValidationError.retryAttemptsOutOfRange(0) {
            // expected
        }

        var invalidSnapshot = makeSnapshot()
        invalidSnapshot.bundleIdentifier = "  "
        invalidSnapshot.frame = CodableRect(x: 0, y: 0, width: .infinity, height: 600)
        var invalidWindow = original
        invalidWindow.slots[0].windows = [invalidSnapshot]
        do {
            try await store.save(invalidWindow)
            XCTFail("Expected invalid window metadata validation to fail.")
        } catch SlotStoreDocument.ValidationError.emptyBundleIdentifier {
            // Bundle validation intentionally runs before frame validation.
        }

        invalidSnapshot.bundleIdentifier = "com.example.App"
        invalidWindow.slots[0].windows = [invalidSnapshot]
        do {
            try await store.save(invalidWindow)
            XCTFail("Expected invalid frame validation to fail.")
        } catch SlotStoreDocument.ValidationError.invalidWindowFrame {
            // expected
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testSaveRejectsDuplicateWindowIdentifiers() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let duplicate = makeSnapshot(id: "same-window")
        let document = SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", windows: [duplicate, duplicate])
        ])

        do {
            try await SlotStore(fileURL: fileURL).save(document)
            XCTFail("Expected duplicate window identifiers to be rejected.")
        } catch SlotStoreDocument.ValidationError.duplicateWindowID(let layoutID, let windowID) {
            XCTAssertEqual(layoutID, "work")
            XCTAssertEqual(windowID, "same-window")
        }
    }

    func testCreateLayoutPersistsAppendedLayout() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let store = try SlotStore(fileURL: fileURL)

        let createdLayout = try await store.createLayout(name: "Travel")
        let loadedDocument = try await SlotStore(fileURL: fileURL).load()

        XCTAssertEqual(loadedDocument.slots.map(\.name), ["Work", "Focus", "Meeting", "Travel"])
        XCTAssertEqual(loadedDocument.slots.last, createdLayout)
        XCTAssertFalse(createdLayout.id.isEmpty)
        XCTAssertTrue(createdLayout.windows.isEmpty)
        XCTAssertNil(createdLayout.lastSaved)
    }

    func testRenameLayoutPersistsNameAndPreservesSnapshotData() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let capturedAt = Date(timeIntervalSince1970: 1_779_190_400)
        let snapshot = WindowSnapshot(
            id: "window-1",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Apple - Safari",
            frame: CodableRect(CGRect(x: 100, y: 50, width: 1200, height: 800)),
            displayUUID: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            displayLocalFrame: CodableRect(x: 20, y: 30, width: 1200, height: 800),
            windowRole: "AXWindow",
            processIdentifier: 1234,
            capturedAt: capturedAt
        )
        let originalLayout = Slot(
            id: "custom",
            name: "Custom",
            lastSaved: capturedAt,
            windows: [snapshot]
        )
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [originalLayout]))

        try await store.renameLayout(id: "custom", name: "Planning")
        let loadedDocument = try await SlotStore(fileURL: fileURL).load()
        let loadedLayout = loadedDocument.slots[0]

        XCTAssertEqual(loadedLayout.id, "custom")
        XCTAssertEqual(loadedLayout.name, "Planning")
        XCTAssertEqual(loadedLayout.lastSaved, capturedAt)
        XCTAssertEqual(loadedLayout.windows, [snapshot])
    }

    func testDeleteLayoutPersistsRemovalAndAllowsEmptyDocument() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "custom-1", name: "Custom 1"),
            Slot(id: "custom-2", name: "Custom 2")
        ]))

        try await store.deleteLayout(id: "custom-1")
        let documentAfterFirstDelete = try await SlotStore(fileURL: fileURL).load()
        XCTAssertEqual(documentAfterFirstDelete.slots.map(\.id), ["custom-2"])

        try await store.deleteLayout(id: "custom-2")
        let documentAfterSecondDelete = try await SlotStore(fileURL: fileURL).load()
        XCTAssertEqual(documentAfterSecondDelete.slots, [])
    }

    func testUpdateAppliesMutationAndPersists() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument())

        let updated = try await store.update { document in
            document.settings.retryAttempts = 7
        }

        XCTAssertEqual(updated.settings.retryAttempts, 7)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.settings.retryAttempts, 7)
    }

    func testUpdateDoesNotPersistWhenMutationThrows() async throws {
        struct MutationError: Error {}
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument())

        do {
            try await store.update { _ in throw MutationError() }
            XCTFail("Expected update to rethrow the mutation error")
        } catch is MutationError {
            // expected
        }

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.settings.retryAttempts, 3)
    }

    func testLoadQuarantinesCorruptStoreAndReturnsDefaults() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: fileURL)

        let store = try SlotStore(fileURL: fileURL)
        let document = try await store.load()

        XCTAssertEqual(document, SlotStoreDocument())

        let contents = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(
            contents[0].hasPrefix("\(SlotStore.fileName).corrupt-"),
            "Expected quarantined file, found: \(contents)"
        )

        try await store.save(document)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveLeavesNoTemporaryFilesBehind() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument())
        try await store.save(SlotStoreDocument())

        let contents = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        XCTAssertEqual(contents.sorted(), [SlotStore.fileName])
    }
}
