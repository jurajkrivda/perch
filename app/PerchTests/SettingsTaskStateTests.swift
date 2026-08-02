import XCTest

final class SettingsTaskStateTests: XCTestCase {
    func testOnlyNewestRefreshGenerationCanApply() {
        var state = SettingsRefreshState()

        let olderGeneration = state.beginLoad()
        let newerGeneration = state.beginLoad()

        XCTAssertFalse(state.shouldApply(generation: olderGeneration))
        XCTAssertTrue(state.shouldApply(generation: newerGeneration))
    }

    func testDirectMutationInvalidatesOlderLoad() {
        var state = SettingsRefreshState()

        let loadBeforeSettingsWrite = state.beginLoad()
        state.invalidateLoads()

        XCTAssertFalse(state.shouldApply(generation: loadBeforeSettingsWrite))
    }

    func testNotificationsCoalesceBeforeLoadAndDuringLoad() {
        var state = SettingsRefreshState()

        XCTAssertTrue(state.requestScheduledRefresh())
        XCTAssertFalse(state.requestScheduledRefresh(), "A burst before loading needs only one pass")

        state.beginScheduledRefreshPass()
        XCTAssertFalse(state.requestScheduledRefresh())
        XCTAssertFalse(state.requestScheduledRefresh())
        XCTAssertTrue(state.finishScheduledRefreshPass(), "Changes during loading need one follow-up")

        state.beginScheduledRefreshPass()
        XCTAssertFalse(state.finishScheduledRefreshPass())
        XCTAssertTrue(state.requestScheduledRefresh(), "The worker can be scheduled again after draining")
    }

    func testCreateSubmissionIsBlockedUntilCompletion() {
        var state = SettingsMutationState()

        XCTAssertTrue(state.beginCreate())
        XCTAssertFalse(state.beginCreate())
        state.finishCreate()
        XCTAssertTrue(state.beginCreate())
    }

    func testDuplicateRenameCollapsesAndOlderCompletionCannotClearNewerRename() throws {
        var state = SettingsMutationState()

        let first = try XCTUnwrap(state.beginRename(layoutID: "work", name: "Deep Work"))
        XCTAssertNil(state.beginRename(layoutID: "work", name: "Deep Work"))
        let newer = try XCTUnwrap(state.beginRename(layoutID: "work", name: "Writing"))

        state.finishRename(first)
        XCTAssertNil(state.beginRename(layoutID: "work", name: "Writing"))

        state.finishRename(newer)
        XCTAssertNotNil(state.beginRename(layoutID: "work", name: "Writing"))
    }

    func testDeleteAndHotkeyRequestsAreDeduplicatedPerLayout() throws {
        var state = SettingsMutationState()
        let hotkey = HotkeyBinding(keyCode: 12, modifiers: 256)

        let clearToken = try XCTUnwrap(state.beginHotkey(layoutID: "focus", hotkey: nil))
        XCTAssertNil(state.beginHotkey(layoutID: "focus", hotkey: nil))
        state.finishHotkey(clearToken)

        let token = try XCTUnwrap(state.beginHotkey(layoutID: "work", hotkey: hotkey))
        XCTAssertNil(state.beginHotkey(layoutID: "work", hotkey: hotkey))
        state.finishHotkey(token)
        XCTAssertNotNil(state.beginHotkey(layoutID: "work", hotkey: hotkey))

        XCTAssertTrue(state.beginDelete(layoutID: "work"))
        XCTAssertFalse(state.beginDelete(layoutID: "work"))
        XCTAssertNil(state.beginRename(layoutID: "work", name: "Deleted"))
        XCTAssertNil(state.beginHotkey(layoutID: "work", hotkey: nil))
        state.finishDelete(layoutID: "work")
        XCTAssertTrue(state.beginDelete(layoutID: "work"))
    }
}
