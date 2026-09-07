import CoreGraphics
import Foundation
import XCTest

final class SlotStoreMigrationTests: XCTestCase {
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
}
