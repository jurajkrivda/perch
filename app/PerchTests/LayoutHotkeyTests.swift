import CoreGraphics
import Foundation
import XCTest

final class LayoutHotkeyTests: XCTestCase {
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
}
