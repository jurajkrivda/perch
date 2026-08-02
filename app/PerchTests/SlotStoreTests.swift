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

    func testVersion2DocumentMigratesToVersion3WithoutCapturedTopology() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let version2JSON = """
        {
          "version": 2,
          "settings": {},
          "slots": [
            {
              "id": "work",
              "name": "Work",
              "windows": []
            }
          ]
        }
        """
        try Data(version2JSON.utf8).write(to: fileURL)

        let document = try await SlotStore(fileURL: fileURL).load()

        XCTAssertEqual(document.version, 3)
        XCTAssertNil(document.slots[0].capturedTopology)

        let migratedData = try Data(contentsOf: fileURL)
        let migratedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedJSON["version"] as? Int, 3)
    }

    func testVersion3RoundTripPreservesCapturedTopology() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let topology = DisplayTopologyFingerprint(displays: [
            DisplayInfo(
                id: 2,
                uuid: "display-b",
                bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                isMain: false
            ),
            DisplayInfo(
                id: 1,
                uuid: "display-a",
                bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                isMain: true
            )
        ])
        let document = SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", capturedTopology: topology)
        ])
        let store = try SlotStore(fileURL: fileURL)

        try await store.save(document)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded.slots[0].capturedTopology, topology)
        XCTAssertEqual(loaded.slots[0].capturedTopology?.identity, "display-a*|display-b")
    }

    func testAutoRestoreSettingsUseSafeDefaults() {
        let settings = PerchSettings()

        XCTAssertEqual(settings.autoRestoreMode, .prompt)
        XCTAssertEqual(settings.autoRestoreSettleTimeout, 10)
    }

    func testUnknownAutoRestoreModeFallsBackToPrompt() throws {
        let data = Data("""
        {
          "version": 3,
          "settings": {
            "autoRestoreMode": "future-mode"
          },
          "slots": []
        }
        """.utf8)

        let document = try JSONDecoder().decode(SlotStoreDocument.self, from: data)

        XCTAssertEqual(document.settings.autoRestoreMode, .prompt)
        XCTAssertEqual(document.settings.autoRestoreSettleTimeout, 10)
        XCTAssertNoThrow(try document.validate())
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

    func testLegacySnapshotsWithoutWindowIdentityDecode() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let legacyJSON = """
        {
          "settings" : {
            "matchStrictness" : "fuzzy",
            "restoreNotification" : "toast",
            "retryAttempts" : 3,
            "showsMenuBarLabel" : true,
            "stabilizationTimeout" : 2.5
          },
          "slots" : [
            {
              "id" : "work",
              "lastSaved" : "2026-05-21T06:00:00Z",
              "name" : "Work",
              "windows" : [
                {
                  "bundleId" : "com.brave.Browser",
                  "capturedAt" : "2026-05-21T06:00:00Z",
                  "displayUUID" : "display-1",
                  "frame" : {
                    "h" : 900,
                    "w" : 1440,
                    "x" : 0,
                    "y" : 0
                  },
                  "id" : "window-1",
                  "normalizedTitle" : "from • hbo max – brave",
                  "processIdentifier" : 1234,
                  "role" : "AXWindow",
                  "title" : "From • HBO Max – Brave"
                }
              ]
            }
          ],
          "version" : 1
        }
        """

        try Data(legacyJSON.utf8).write(to: fileURL)

        let loadedDocument = try await SlotStore(fileURL: fileURL).load()
        let snapshot = try XCTUnwrap(loadedDocument.slots.first?.windows.first)

        XCTAssertNil(snapshot.cgWindowID)
        XCTAssertNil(snapshot.accessibilityIdentifier)
        XCTAssertEqual(snapshot.bundleIdentifier, "com.brave.Browser")
        XCTAssertFalse(loadedDocument.settings.opensMissingApplicationsOnRestore)
        XCTAssertEqual(loadedDocument.version, SlotStoreDocument.currentVersion)
        XCTAssertEqual(loadedDocument.slots[0].restoreHotkey, HotkeyBinding.defaultRestore(for: 0))

        let migratedData = try Data(contentsOf: fileURL)
        let migratedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        XCTAssertEqual(migratedJSON["version"] as? Int, SlotStoreDocument.currentVersion)
    }

    func testVersion1MigrationPreservesCustomRestoreAndDisablesOnlyCollidingPositionalRestore() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let customHotkey = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 3))
        try makeVersion1StoreData(hotkeys: [customHotkey, nil, nil, nil]).write(to: fileURL)

        let document = try await SlotStore(fileURL: fileURL).load()

        XCTAssertEqual(document.slots.map(\.id), ["layout-0", "layout-1", "layout-2", "layout-3"])
        XCTAssertEqual(document.slots.map(\.name), ["Layout 0", "Layout 1", "Layout 2", "Layout 3"])
        XCTAssertEqual(document.settings.retryAttempts, 5)
        XCTAssertEqual(document.settings.matchStrictness, .strict)
        XCTAssertTrue(document.settings.opensMissingApplicationsOnRestore)
        XCTAssertEqual(document.slots[0].restoreHotkey, customHotkey)
        XCTAssertFalse(document.slots[0].restoreHotkeyDisabled)
        XCTAssertTrue(document.slots[3].restoreHotkeyDisabled)
        XCTAssertNil(document.effectiveRestoreHotkey(for: "layout-3"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
            [SlotStore.fileName]
        )
    }

    func testVersion1MigrationPreservesCustomRestoreAndDisablesCollidingPositionalSave() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let customHotkey = try XCTUnwrap(HotkeyBinding.defaultSave(for: 3))
        try makeVersion1StoreData(hotkeys: [customHotkey, nil, nil, nil]).write(to: fileURL)

        let document = try await SlotStore(fileURL: fileURL).load()

        XCTAssertEqual(document.slots.map(\.id), ["layout-0", "layout-1", "layout-2", "layout-3"])
        XCTAssertEqual(document.slots.map(\.name), ["Layout 0", "Layout 1", "Layout 2", "Layout 3"])
        XCTAssertEqual(document.settings.retryAttempts, 5)
        XCTAssertEqual(document.settings.matchStrictness, .strict)
        XCTAssertTrue(document.settings.opensMissingApplicationsOnRestore)
        XCTAssertEqual(document.slots[0].restoreHotkey, customHotkey)
        XCTAssertEqual(document.settings.disabledDefaultSaveHotkeys, [customHotkey])
        XCTAssertNil(document.effectiveSaveHotkey(at: 3))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
            [SlotStore.fileName]
        )
    }

    func testLoadRefusesVersion4WithoutChangingOrQuarantiningFile() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let originalData = Data("{\"version\":4,\"slots\":[],\"settings\":{}}".utf8)
        try originalData.write(to: fileURL)

        let store = try SlotStore(fileURL: fileURL)
        do {
            _ = try await store.load()
            XCTFail("Expected a future schema version to be refused.")
        } catch SlotStore.StoreError.unsupportedSchemaVersion(let found, let supported) {
            XCTAssertEqual(found, 4)
            XCTAssertEqual(supported, SlotStoreDocument.currentVersion)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
            [SlotStore.fileName]
        )
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

    @MainActor
    func testSetRestoreHotkeyRejectsDuplicateRestoreShortcut() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let workHotkey = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 0))
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", restoreHotkey: workHotkey),
            Slot(id: "focus", name: "Focus", restoreHotkey: HotkeyBinding.defaultRestore(for: 1))
        ]))
        let engine = SlotEngine(store: store)

        do {
            try await engine.setRestoreHotkey(layoutID: "focus", hotkey: workHotkey)
            XCTFail("Expected duplicate restore shortcut to be rejected.")
        } catch SlotEngineError.hotkeyConflict(let conflict) {
            XCTAssertEqual(conflict.action, .restore)
            XCTAssertEqual(conflict.layoutID, "work")
            XCTAssertEqual(conflict.layoutName, "Work")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testSetRestoreHotkeyRejectsSaveShortcutConflict() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let workSaveHotkey = try XCTUnwrap(HotkeyBinding.defaultSave(for: 0))
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", restoreHotkey: HotkeyBinding.defaultRestore(for: 0)),
            Slot(id: "focus", name: "Focus", restoreHotkey: HotkeyBinding.defaultRestore(for: 1))
        ]))
        let engine = SlotEngine(store: store)

        do {
            try await engine.setRestoreHotkey(layoutID: "focus", hotkey: workSaveHotkey)
            XCTFail("Expected save shortcut conflict to be rejected.")
        } catch SlotEngineError.hotkeyConflict(let conflict) {
            XCTAssertEqual(conflict.action, .save)
            XCTAssertEqual(conflict.layoutID, "work")
            XCTAssertEqual(conflict.layoutName, "Work")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCreateLayoutRejectsDefaultRestoreShortcutConflict() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fourthDefault = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 3))
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", restoreHotkey: fourthDefault),
            Slot(id: "focus", name: "Focus", restoreHotkey: HotkeyBinding.defaultRestore(for: 1)),
            Slot(id: "meeting", name: "Meeting", restoreHotkey: HotkeyBinding.defaultRestore(for: 2))
        ]))
        let engine = SlotEngine(store: store)

        do {
            _ = try await engine.createLayout(name: "Travel")
            XCTFail("Expected the new layout's positional default to conflict.")
        } catch SlotEngineError.hotkeyConflict(let conflict) {
            XCTAssertEqual(conflict.action, .restore)
            XCTAssertEqual(conflict.layoutID, "work")
        }

        let unchanged = try await store.load()
        XCTAssertEqual(unchanged.slots.map(\.id), ["work", "focus", "meeting"])
    }

    @MainActor
    func testCreateLayoutRejectsNewDefaultSaveShortcutConflict() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fourthSave = try XCTUnwrap(HotkeyBinding.defaultSave(for: 3))
        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "work", name: "Work", restoreHotkey: fourthSave),
            Slot(id: "focus", name: "Focus", restoreHotkey: HotkeyBinding.defaultRestore(for: 1)),
            Slot(id: "meeting", name: "Meeting", restoreHotkey: HotkeyBinding.defaultRestore(for: 2))
        ]))
        let engine = SlotEngine(store: store)

        do {
            _ = try await engine.createLayout(name: "Travel")
            XCTFail("Expected the new layout's save shortcut to conflict.")
        } catch SlotEngineError.hotkeyConflict(let conflict) {
            XCTAssertEqual(conflict.action, .save)
            XCTAssertEqual(conflict.layoutName, "Travel")
        }

        let unchanged = try await store.load()
        XCTAssertEqual(unchanged.slots.map(\.id), ["work", "focus", "meeting"])
    }

    func testDeleteLayoutPreservesEffectiveRestoreShortcutsAfterIndexShift() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        try await store.save(SlotStoreDocument(slots: [
            Slot(id: "first", name: "First"),
            Slot(id: "second", name: "Second"),
            Slot(id: "third", name: "Third")
        ]))

        try await store.deleteLayout(id: "first")
        let document = try await store.load()

        XCTAssertEqual(document.slots.map(\.id), ["second", "third"])
        XCTAssertEqual(document.slots[0].restoreHotkey, HotkeyBinding.defaultRestore(for: 1))
        XCTAssertEqual(document.slots[1].restoreHotkey, HotkeyBinding.defaultRestore(for: 2))
    }

    func testDeleteAcrossDefaultShortcutBoundaryKeepsPreviouslyUnboundLayoutUnbound() async throws {
        let (directoryURL, fileURL) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = try SlotStore(fileURL: fileURL)
        let layouts = (0..<10).map { index in
            Slot(id: "layout-\(index)", name: "Layout \(index)")
        }
        try await store.save(SlotStoreDocument(slots: layouts))

        try await store.deleteLayout(id: "layout-0")
        let document = try await store.load()
        let shiftedPreviouslyUnboundLayout = try XCTUnwrap(
            document.slots.first(where: { $0.id == "layout-9" })
        )

        XCTAssertTrue(shiftedPreviouslyUnboundLayout.restoreHotkeyDisabled)
        XCTAssertNil(document.effectiveRestoreHotkey(for: "layout-9"))
        XCTAssertEqual(
            document.effectiveRestoreHotkey(for: "layout-8"),
            HotkeyBinding.defaultRestore(for: 8)
        )
    }

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
            _ = try await engine.restore(slotID: "work", preflight: { false })
            XCTFail("Expected the automatic restore preflight to reject the operation")
        } catch SlotEngineError.restorePreflightRejected {
            // expected
        }

        XCTAssertEqual(mover.moveCount, 0)

        let result = try await engine.restore(slotID: "work", preflight: { true })
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(mover.moveCount, 1)
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

    @MainActor
    func testSharedEngineReturnsSameInstance() throws {
        let first = try SlotEngine.shared()
        let second = try SlotEngine.shared()
        XCTAssertTrue(first === second)
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

    private func makeTemporaryStoreURL() -> (directoryURL: URL, fileURL: URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerchTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("slots.json", isDirectory: false)
        return (directoryURL, fileURL)
    }

    private func makeVersion1StoreData(hotkeys: [HotkeyBinding?]) throws -> Data {
        let slots: [[String: Any]] = hotkeys.enumerated().map { index, hotkey in
            var slot: [String: Any] = [
                "id": "layout-\(index)",
                "name": "Layout \(index)",
                "windows": []
            ]
            if let hotkey {
                slot["restoreHotkey"] = [
                    "keyCode": NSNumber(value: hotkey.keyCode),
                    "modifiers": NSNumber(value: hotkey.modifiers)
                ]
            }
            return slot
        }

        return try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "settings": [
                "matchStrictness": "strict",
                "opensMissingApplicationsOnRestore": true,
                "retryAttempts": 5,
                "showsMenuBarLabel": false,
                "stabilizationTimeout": 4.5
            ],
            "slots": slots
        ])
    }

    private func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func makeSnapshot(
        id: String = "window-1",
        bundleIdentifier: String = "com.example.App"
    ) -> WindowSnapshot {
        WindowSnapshot(
            id: id,
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Example Window",
            frame: CodableRect(CGRect(x: 100, y: 100, width: 800, height: 600)),
            displayUUID: nil,
            displayLocalFrame: nil,
            windowRole: "AXWindow",
            processIdentifier: 1234,
            capturedAt: Date(timeIntervalSince1970: 1_779_190_400)
        )
    }
}

private struct SuccessfulWindowSnapshotter: WindowSnapshotting {
    let snapshots: [WindowSnapshot]

    func captureCurrentWindows() async throws -> [WindowSnapshot] {
        snapshots
    }
}

private struct IncompleteWindowSnapshotter: WindowSnapshotting {
    let processIdentifier: Int32

    func captureCurrentWindows() async throws -> [WindowSnapshot] {
        throw WindowSnapshotterError.incompleteAccessibilityRead(
            processIdentifier: processIdentifier
        )
    }
}

@MainActor
private final class FakeWindowMover: WindowMoving {
    enum Outcome {
        case success
        case appNotRunning
        case windowNotFound
        case frameWriteFailed
    }

    private var outcomes: [Outcome]
    private(set) var moveCount = 0
    private(set) var movedSnapshotIDs: [String] = []
    private(set) var movedFramesBySnapshotID: [String: [CGRect]] = [:]
    private var reservationsBySnapshotID: [String: WindowCandidateReservation] = [:]

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int,
        strictness: MatchStrictness
    ) throws -> CGRect {
        moveCount += 1
        movedSnapshotIDs.append(snapshot.id)
        movedFramesBySnapshotID[snapshot.id, default: []].append(frame)

        guard !outcomes.isEmpty else {
            return frame
        }

        switch outcomes.removeFirst() {
        case .success:
            return frame
        case .appNotRunning:
            throw WindowMoverError.appNotRunning(bundleIdentifier: snapshot.bundleIdentifier)
        case .windowNotFound:
            throw WindowMoverError.windowNotFound(
                bundleIdentifier: snapshot.bundleIdentifier,
                title: snapshot.windowTitle
            )
        case .frameWriteFailed:
            throw WindowMoverError.frameWriteFailed
        }
    }

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) throws -> [WindowBatchMoveResult] {
        var results: [WindowBatchMoveResult] = []

        for request in requests {
            if !request.shouldMove {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: request.frame,
                    matchReason: .titleMatch,
                    error: nil,
                    reservation: request.reservation ?? reservationsBySnapshotID[request.snapshot.id]
                ))
                continue
            }

            do {
                let restoredFrame = try move(
                    snapshot: request.snapshot,
                    to: request.frame,
                    attempts: request.attempts,
                    strictness: strictness
                )
                let reservation = request.reservation
                    ?? reservationsBySnapshotID[request.snapshot.id]
                    ?? WindowCandidateReservation(
                        processIdentifier: request.snapshot.processIdentifier,
                        processLaunchDate: request.snapshot.capturedAt.addingTimeInterval(-60),
                        cgWindowID: nil,
                        axElementHash: UInt(bitPattern: request.snapshot.id.hashValue)
                    )
                reservationsBySnapshotID[request.snapshot.id] = reservation
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: restoredFrame,
                    matchReason: .titleMatch,
                    error: nil,
                    reservation: reservation
                ))
            } catch WindowMoverError.appNotRunning where results.isEmpty {
                throw WindowMoverError.appNotRunning(bundleIdentifier: bundleIdentifier)
            } catch let error as WindowMoverError {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: error
                ))
            } catch {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: .frameWriteFailed
                ))
            }
        }

        return results
    }
}

@MainActor
private final class TitleChangingReservationMover: WindowMoving {
    private let processLaunchDate = Date(timeIntervalSince1970: 1_779_190_300)
    private let axElementHash: UInt = 77
    private var batchCallCount = 0
    private(set) var movedSnapshotIDs: [String] = []

    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int,
        strictness: MatchStrictness
    ) throws -> CGRect {
        movedSnapshotIDs.append(snapshot.id)
        return frame
    }

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) throws -> [WindowBatchMoveResult] {
        batchCallCount += 1
        if batchCallCount == 1 {
            throw WindowMoverError.appNotRunning(bundleIdentifier: bundleIdentifier)
        }

        let liveTitle = batchCallCount == 2
            ? "First Saved Window"
            : "Second Saved Window"
        let candidate = WindowMoveCandidate(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 1234,
            processLaunchDate: processLaunchDate,
            cgWindowID: nil,
            accessibilityIdentifier: nil,
            title: liveTitle,
            normalizedTitle: WindowMover.normalizedTitle(liveTitle),
            role: "AXWindow",
            isMinimized: false,
            isFullscreen: false,
            frame: requests.first?.frame,
            axElementHash: axElementHash
        )
        let matchRequests = requests.map { request in
            WindowMover.WindowMatchRequest(
                title: request.snapshot.windowTitle,
                processIdentifier: request.snapshot.processIdentifier,
                capturedAt: request.snapshot.capturedAt,
                cgWindowID: request.snapshot.cgWindowID,
                accessibilityIdentifier: request.snapshot.accessibilityIdentifier,
                frame: request.frame,
                reservation: request.reservation,
                rejectsConflictingAccessibilityIdentifier: false
            )
        }
        let selections = WindowMover.bestWindowSelections(
            in: [candidate],
            matching: matchRequests,
            strictness: strictness
        )
        let usedCandidateIndices = Set(selections.values.map(\.index))

        return requests.enumerated().map { index, request in
            guard let selection = selections[index] else {
                return WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: WindowMover.unresolvedSelectionError(
                        bundleIdentifier: bundleIdentifier,
                        title: request.snapshot.windowTitle,
                        candidateCount: 1,
                        usedCandidateIndices: usedCandidateIndices
                    )
                )
            }

            if request.shouldMove {
                movedSnapshotIDs.append(request.snapshot.id)
            }

            return WindowBatchMoveResult(
                snapshotID: request.snapshot.id,
                restoredFrame: request.frame,
                matchReason: selection.reason,
                error: nil,
                reservation: WindowCandidateReservation(
                    processIdentifier: candidate.processIdentifier,
                    processLaunchDate: candidate.processLaunchDate,
                    cgWindowID: candidate.cgWindowID,
                    axElementHash: candidate.axElementHash
                )
            )
        }
    }
}

private struct DuplicateResultWindowMover: WindowMoving {
    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int,
        strictness: MatchStrictness
    ) throws -> CGRect {
        frame
    }

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) throws -> [WindowBatchMoveResult] {
        guard let request = requests.first else {
            return []
        }

        return [
            WindowBatchMoveResult(
                snapshotID: request.snapshot.id,
                restoredFrame: request.frame,
                matchReason: .titleMatch,
                error: nil
            ),
            WindowBatchMoveResult(
                snapshotID: request.snapshot.id,
                restoredFrame: nil,
                matchReason: nil,
                error: .frameWriteFailed
            )
        ]
    }
}

@MainActor
private final class FakeApplicationLauncher: ApplicationLaunching {
    private let results: [String: ApplicationLaunchResult]
    private(set) var launchedBundles: [String] = []

    init(results: [String: ApplicationLaunchResult]) {
        self.results = results
    }

    func launchApplication(bundleIdentifier: String) async -> ApplicationLaunchResult {
        launchedBundles.append(bundleIdentifier)
        return results[bundleIdentifier] ?? .notInstalled
    }
}
