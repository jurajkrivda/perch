import XCTest

final class PreferredLayoutTests: XCTestCase {
    private let topology = DisplayTopologyFingerprint(entries: [
        .init(uuid: "display", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true)
    ])

    func testPreferenceWinsOverSaveOrderForEveryEligibleTrigger() {
        let old = Slot(id: "old", name: "Old", lastSaved: Date(timeIntervalSince1970: 1),
                       windows: [makeSnapshot()], capturedTopology: topology)
        let new = Slot(id: "new", name: "New", lastSaved: Date(timeIntervalSince1970: 2),
                       windows: [makeSnapshot()], capturedTopology: topology)
        for mode in [AutoRestoreMode.prompt, .automatic] {
            for trigger in [EnvironmentChangeReason.applicationLaunch, .systemWake, .displayReconfiguration] {
                let decision = AutoRestorePolicy.decide(AutoRestoreInput(
                    mode: mode, trigger: trigger, currentTopology: topology,
                    slots: [old, new], alreadyPromptedForCurrentTopology: false,
                    preferredLayoutsByTopology: [topology.identity: old.id]
                ))
                XCTAssertEqual(decision, mode == .automatic
                    ? .restore(layoutID: old.id, layoutName: old.name) : .prompt(layoutID: old.id, layoutName: old.name))
            }
        }
    }

    func testMissingEmptyAndWrongTopologyPreferencesFallBackToUsableLayout() {
        let good = Slot(id: "good", name: "Good", windows: [makeSnapshot()], capturedTopology: topology)
        let empty = Slot(id: "empty", name: "Empty", capturedTopology: topology)
        let wrong = Slot(id: "wrong", name: "Wrong", windows: [makeSnapshot()], capturedTopology: .init(entries: []))
        for id in ["deleted", empty.id, wrong.id] {
            XCTAssertEqual(AutoRestorePolicy.selectedLayout(
                slots: [good, empty, wrong], topology: topology,
                preferences: [topology.identity: id]
            )?.id, good.id)
        }
    }

    @MainActor
    func testPreferenceSurvivesRestartAndUnrelatedSavesButClearsWhenLayoutIsDeleted() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        let slot = Slot(id: "work", name: "Work", windows: [makeSnapshot()], capturedTopology: topology)
        try await store.save(SlotStoreDocument(slots: [slot]))
        let engine = SlotEngine(store: store)
        try await engine.setPreferredLayout(slot.id, for: topology)
        _ = try await store.createLayout(name: "Unrelated")
        let reopened = try SlotStore(fileURL: url)
        let persisted = try await reopened.load()
        XCTAssertEqual(persisted.settings.preferredLayoutsByTopology[topology.identity], slot.id)
        try await reopened.deleteLayout(id: slot.id)
        let deleted = try await reopened.load()
        XCTAssertTrue(deleted.settings.preferredLayoutsByTopology.isEmpty)
    }

    @MainActor
    func testResavingPreferredLayoutOnAnotherDisplayDoesNotTransferThePreference() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [makeSnapshot()], capturedTopology: topology)]))
        let engine = SlotEngine(store: store, snapshotter: SuccessfulWindowSnapshotter(snapshots: [makeSnapshot()]),
                                capturedTopologyProvider: { nil })
        try await engine.setPreferredLayout("work", for: topology)
        _ = try await engine.save(slotID: "work")
        let document = try await store.load()
        XCTAssertTrue(document.settings.preferredLayoutsByTopology.isEmpty)
    }

    @MainActor
    func testCannotPreferAnEmptyLayout() async throws {
        let (directory, url) = makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SlotStore(fileURL: url)
        try await store.save(SlotStoreDocument(slots: [Slot(id: "empty", name: "Empty", capturedTopology: topology)]))
        do {
            try await SlotEngine(store: store).setPreferredLayout("empty", for: topology)
            XCTFail("An empty layout is not an automatic restore target")
        } catch SlotEngineError.displayConfigurationChanged { }
    }

    func testLegacySettingsDecodeWithNoExplicitPreference() throws {
        let settings = try JSONDecoder().decode(PerchSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.preferredLayoutsByTopology.isEmpty)
    }
}
