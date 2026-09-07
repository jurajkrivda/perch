import XCTest

final class LayoutHistoryTests: XCTestCase {
    func testOverwriteKeepsPreviousWindowsAndSettingsDoNotCreateVersions() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let original = Slot(id: "work", name: "Work", windows: [makeSnapshot()])
        try await store.save(SlotStoreDocument(slots: [original]))
        try await store.update { $0.settings.autoRestoreMode = .automatic }
        let beforeOverwrite = try await store.layoutHistory()
        XCTAssertTrue(beforeOverwrite.isEmpty)
        try await store.update { $0.slots[0].windows[0].frame.x = 500 }
        let revisions = try await store.layoutHistory()
        XCTAssertEqual(revisions.map(\.layout), [original])
        let historyURL = directory.appendingPathComponent("Layout History")
        XCTAssertEqual(try posixPermissions(of: historyURL), 0o700)
        let revisionURL = historyURL.appendingPathComponent(try XCTUnwrap(revisions.first).id + ".json")
        XCTAssertEqual(try posixPermissions(of: revisionURL), 0o600)
    }

    func testRecoveryPreservesCurrentNamesShortcutsAndSettingsAndCanBeReversed() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let original = makeSnapshot()
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [original])]))
        try await store.update {
            $0.slots[0].windows[0].frame.x = 500
            $0.slots[0].name = "Renamed"
            $0.slots[0].restoreHotkeyDisabled = true
            $0.settings.autoRestoreMode = .off
        }
        let revisions = try await store.layoutHistory()
        try await store.restoreRevision(id: try XCTUnwrap(revisions.first).id)
        let recovered = try await store.load()
        XCTAssertEqual(recovered.slots[0].windows, [original])
        XCTAssertEqual(recovered.slots[0].name, "Renamed")
        XCTAssertTrue(recovered.slots[0].restoreHotkeyDisabled)
        XCTAssertEqual(recovered.settings.autoRestoreMode, .off)
        let newHistory = try await store.layoutHistory()
        XCTAssertTrue(newHistory.contains { $0.layout.windows[0].frame.x == 500 })
    }

    func testDeletedLayoutCanBeRecoveredWithoutTakingAnOccupiedShortcut() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [makeSnapshot()])]))
        try await store.deleteLayout(id: "work")
        _ = try await store.createLayout(name: "New")
        let revisions = try await store.layoutHistory()
        try await store.restoreRevision(id: try XCTUnwrap(revisions.first).id)
        let recovered = try await store.load()
        XCTAssertEqual(recovered.slots.count, 2)
        XCTAssertTrue(recovered.slots[1].restoreHotkeyDisabled)
        XCTAssertNil(recovered.effectiveRestoreHotkey(for: "work"))
        try recovered.validate()
    }

    func testHistoryKeepsTheTenNewestVersionsPerLayout() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [makeSnapshot()])]))
        for index in 1...14 {
            try await store.update { $0.slots[0].windows[0].frame.x = Double(index) }
        }
        let revisions = try await store.layoutHistory()
        XCTAssertEqual(revisions.count, 10)
        XCTAssertEqual(revisions.map { $0.layout.windows[0].frame.x }, Array((4...13).reversed()).map(Double.init))
    }

    func testDamagedLiveStoreDoesNotDestroyValidHistory() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [makeSnapshot()])]))
        try await store.update { $0.slots[0].windows[0].frame.x = 500 }
        try Data("invalid json".utf8).write(to: url)
        let revisions = try await store.layoutHistory()
        try await store.restoreRevision(id: try XCTUnwrap(revisions.first).id)
        let recovered = try await store.load()
        XCTAssertEqual(recovered.slots.first(where: { $0.id == "work" })?.windows, [makeSnapshot()])
        let notice = try await store.recoveryNotice()
        XCTAssertNotNil(notice)
    }

    func testFailedHistoryWriteDoesNotOverwriteTheLiveLayout() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [makeSnapshot()])])
        let store = try SlotStore(fileURL: url)
        try await store.save(original)
        let rejecting = try SlotStore(fileURL: url, fileManager: RejectingHistoryFileManager())
        do {
            try await rejecting.update { $0.slots[0].windows[0].frame.x = 500 }
            XCTFail("Must retain the old layout if its recovery point cannot be written")
        } catch CocoaError.fileWriteOutOfSpace { }
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, original)
    }

    func testMalformedHistoryEntriesAreSkippedWithoutHidingValidVersions() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [makeSnapshot()])]))
        try await store.update { $0.slots[0].windows[0].frame.x = 500 }
        let history = directory.appendingPathComponent("Layout History")
        try Data("broken".utf8).write(to: history.appendingPathComponent(UUID().uuidString + ".json"))
        let revisions = try await store.layoutHistory()
        XCTAssertEqual(revisions.count, 1)
    }

    func testHistoryHasAGlobalLimitAcrossManyLayouts() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let slots = (0..<12).map {
            Slot(id: "layout-\($0)", name: "Layout \($0)", restoreHotkeyDisabled: true,
                 windows: [makeSnapshot()])
        }
        try await store.save(SlotStoreDocument(slots: slots))
        for revision in 1...10 {
            try await store.update { document in
                for index in document.slots.indices {
                    document.slots[index].windows[0].frame.x = Double(revision)
                }
            }
        }
        let history = try await store.layoutHistory()
        XCTAssertEqual(history.count, 100)
        XCTAssertTrue(history.allSatisfy { $0.layout.windows[0].frame.x <= 9 })
        XCTAssertEqual(history.filter { $0.layout.windows[0].frame.x == 9 }.count, 12)
    }
}

private final class RejectingHistoryFileManager: FileManager {
    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if url.lastPathComponent == "Layout History" { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
