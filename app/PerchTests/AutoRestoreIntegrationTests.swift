import AppKit
import XCTest

@MainActor
final class AutoRestoreIntegrationTests: XCTestCase {
    func testStartupOffersSavedLayoutWithoutAnySystemNotification() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.prompts.count == 1 }
        XCTAssertEqual(fixture.presentation.prompts.first?.layoutName, "Work")
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        XCTAssertTrue(AutoRestoreDiagnostics.lastDecision.contains("applicationLaunch"))
    }

    func testAutomaticStartupRestoresThroughTheRealEngine() async throws {
        let fixture = try await AutoRestoreFixture(mode: .automatic)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.results.count == 1 }
        XCTAssertEqual(fixture.presentation.results.first?.succeeded, 1)
        XCTAssertTrue(fixture.presentation.prompts.isEmpty)
    }

    func testStartupUsesThePersistedSettleTimeoutForItsFirstWait() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt, settleTimeout: 42)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.prompts.count == 1 }
        XCTAssertEqual(fixture.recordedSettleTimeouts.first, 42)
    }

    func testDisabledModeDoesNothingAtStartup() async throws {
        let fixture = try await AutoRestoreFixture(mode: .off)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.lastDecision == .autoRestoreDecisionDisabled }
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        XCTAssertTrue(fixture.presentation.prompts.isEmpty)
    }

    func testStartupWaitsForPositiveSessionVisibility() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.visible = nil
        fixture.start()
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(fixture.presentation.prompts.isEmpty)
        fixture.visible = true
        fixture.unlock()
        try await waitUntil { fixture.presentation.prompts.count == 1 }
    }

    func testPromptModeWaitsForConfirmationBeforeMovingWindows() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        let movesBeforeConfirmation = await fixture.mover.moves
        XCTAssertEqual(movesBeforeConfirmation, 0)
        fixture.presentation.currentPrompt?.onConfirm()
        try await waitUntil { fixture.presentation.results.count == 1 }
        XCTAssertEqual(fixture.presentation.results.first?.succeeded, 1)
    }

    func testSwitchingAnOpenPromptToAutomaticRestoresWithoutConfirmation() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        let oldPrompt = try XCTUnwrap(fixture.presentation.currentPrompt)
        _ = try await fixture.engine.updateSettings { $0.autoRestoreMode = .automatic }
        try await waitUntil { fixture.presentation.results.count == 1 }
        XCTAssertNil(fixture.presentation.currentPrompt)
        XCTAssertEqual(fixture.presentation.results.first?.succeeded, 1)
        oldPrompt.onConfirm()
        await Task.yield()
        XCTAssertEqual(fixture.presentation.restoreCount, 1)
    }

    func testLateDisplayWaveReplacesUnconfirmedPromptForSameTopology() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.prompts.count == 1 }
        let stalePrompt = try XCTUnwrap(fixture.presentation.currentPrompt)
        fixture.applicationCenter.post(name: .perchDisplayDidReconfigure, object: nil)
        try await waitUntil { fixture.presentation.prompts.count == 2 }
        stalePrompt.onConfirm()
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        fixture.presentation.currentPrompt?.onConfirm()
        try await waitUntil { fixture.presentation.results.count == 1 }
    }

    func testSwitchingToAutomaticWhileLockedWaitsForUnlock() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        fixture.visible = false
        fixture.distributedCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        try await waitUntil { fixture.presentation.currentPrompt == nil }
        _ = try await fixture.engine.updateSettings { $0.autoRestoreMode = .automatic }
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        fixture.visible = true
        fixture.unlock()
        try await waitUntil { fixture.presentation.results.count == 1 }
        XCTAssertNil(fixture.presentation.currentPrompt)
    }

    func testSwitchingAnOpenPromptToAutomaticWaitsForChangedDisplaysToSettle() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        fixture.topology = DisplayTopologyFingerprint(entries: [
            .init(uuid: "audit-display", bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000), isMain: true)
        ])
        _ = try await fixture.engine.updateSettings { $0.autoRestoreMode = .automatic }
        try await waitUntil { fixture.presentation.currentPrompt == nil }
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        fixture.applicationCenter.post(name: .perchDisplayDidReconfigure, object: nil)
        try await waitUntil { fixture.presentation.results.count == 1 }
        XCTAssertEqual(fixture.presentation.results.first?.succeeded, 1)
    }

    func testSleepHidesPromptAndDisplayCallbacksCannotReopenIt() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        // The session dictionary can still say visible while displays sleep.
        fixture.workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await waitUntil { fixture.presentation.currentPrompt == nil }
        fixture.applicationCenter.post(name: .perchDisplayDidReconfigure, object: nil)
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertNil(fixture.presentation.currentPrompt)
        fixture.workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await waitUntil { fixture.presentation.prompts.count == 2 }
    }

    func testLockDuringSettlingDefersPromptUntilUnlock() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        let gate = AuditAsyncGate()
        fixture.settleGate = gate
        fixture.start()
        try await waitUntil { fixture.settleCount == 1 }
        fixture.visible = false
        fixture.distributedCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        await gate.open()
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(fixture.presentation.prompts.isEmpty)
        fixture.visible = true
        fixture.unlock()
        try await waitUntil { fixture.presentation.prompts.count == 1 }
    }

    func testTurningOffBeforeCommitPreventsQueuedAutomaticRestore() async throws {
        let fixture = try await AutoRestoreFixture(mode: .automatic)
        defer { fixture.stop() }
        let gate = AuditAsyncGate()
        fixture.presentation.restoreGate = gate
        fixture.start()
        try await waitUntil { fixture.presentation.restoreCount == 1 }
        _ = try await fixture.engine.updateSettings { $0.autoRestoreMode = .off }
        await gate.open()
        try await waitUntil { fixture.presentation.finishedCount == 1 }
        XCTAssertTrue(fixture.presentation.results.isEmpty)
        let moves = await fixture.mover.moves
        XCTAssertEqual(moves, 0)
    }

    func testSwitchingToAskBeforeCommitShowsPromptInsteadOfMoving() async throws {
        let fixture = try await AutoRestoreFixture(mode: .automatic)
        defer { fixture.stop() }
        let gate = AuditAsyncGate()
        fixture.presentation.restoreGate = gate
        fixture.start()
        try await waitUntil { fixture.presentation.restoreCount == 1 }
        _ = try await fixture.engine.updateSettings { $0.autoRestoreMode = .prompt }
        await gate.open()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        XCTAssertTrue(fixture.presentation.results.isEmpty)
        let moves = await fixture.mover.moves
        XCTAssertEqual(moves, 0)
    }

    func testStopRemovesObserversAndRejectsOldConfirmation() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        let prompt = try XCTUnwrap(fixture.presentation.currentPrompt)
        fixture.coordinator?.stop()
        prompt.onConfirm()
        fixture.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        XCTAssertEqual(fixture.presentation.prompts.count, 1)
    }

    func testLateSecondWakeSignalDoesNotRepeatACompletedOffer() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.prompts.count == 1 }
        fixture.presentation.currentPrompt?.onDismiss()
        fixture.workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitUntil { fixture.presentation.currentPrompt == nil }
        fixture.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { fixture.presentation.prompts.count == 2 }
        fixture.presentation.currentPrompt?.onDismiss()
        fixture.workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await waitUntil { fixture.presentation.lastDecision == .autoRestoreDecisionTopologyUnchanged }
        XCTAssertEqual(fixture.presentation.prompts.count, 2)
    }

    func testUnstableDisplaysDeferStartupUntilAStableCallback() async throws {
        let fixture = try await AutoRestoreFixture(mode: .automatic)
        defer { fixture.stop() }
        fixture.displaysStabilize = false
        fixture.start()
        try await waitUntil { fixture.settleCount > 0 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        fixture.displaysStabilize = true
        fixture.applicationCenter.post(name: .perchDisplayDidReconfigure, object: nil)
        try await waitUntil { fixture.presentation.results.count == 1 }
        XCTAssertEqual(fixture.presentation.results.first?.succeeded, 1)
    }

    func testTurningOffDismissesAnAlreadyVisibleOffer() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        _ = try await fixture.engine.updateSettings { $0.autoRestoreMode = .off }
        try await waitUntil { fixture.presentation.currentPrompt == nil }
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        XCTAssertEqual(fixture.presentation.lastDecision, .autoRestoreDecisionDisabled)
    }

    func testChangingPreferredLayoutReplacesAnOpenOfferAndInvalidatesItsCallback() async throws {
        let fixture = try await AutoRestoreFixture(mode: .prompt)
        defer { fixture.stop() }
        fixture.start()
        try await waitUntil { fixture.presentation.currentPrompt != nil }
        let previousPrompt = try XCTUnwrap(fixture.presentation.currentPrompt)
        try await fixture.engine.store.update { document in
            var preferred = document.slots[0]
            preferred.id = "focus"
            preferred.name = "Focus"
            document.slots.append(preferred)
        }
        try await fixture.engine.setPreferredLayout("focus", for: fixture.topology)
        try await waitUntil { fixture.presentation.currentPrompt?.layoutName == "Focus" }
        previousPrompt.onConfirm()
        XCTAssertEqual(fixture.presentation.restoreCount, 0)
        fixture.presentation.currentPrompt?.onConfirm()
        try await waitUntil { fixture.presentation.results.count == 1 }
        XCTAssertEqual(fixture.presentation.results[0].slotID, "focus")
    }

    func testPreferredLayoutChangedBeforeAutomaticCommitUsesTheNewChoice() async throws {
        let fixture = try await AutoRestoreFixture(mode: .automatic)
        defer { fixture.stop() }
        let gate = AuditAsyncGate()
        fixture.presentation.restoreGate = gate
        fixture.start()
        try await waitUntil { fixture.presentation.restoreCount == 1 }
        try await fixture.engine.store.update { document in
            var preferred = document.slots[0]
            preferred.id = "focus"
            preferred.name = "Focus"
            document.slots.append(preferred)
        }
        try await fixture.engine.setPreferredLayout("focus", for: fixture.topology)
        try await waitUntil { fixture.presentation.restoreCount == 2 }
        await gate.open()
        try await waitUntil { fixture.presentation.finishedCount == 2 }
        XCTAssertEqual(fixture.presentation.results.map(\.slotID), ["focus"])
        XCTAssertTrue(fixture.presentation.prompts.isEmpty)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the event pipeline")
    }
}

actor AuditAsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class AutoRestoreFixture {
    let workspaceCenter = NotificationCenter()
    let applicationCenter = NotificationCenter()
    let distributedCenter = NotificationCenter()
    let directory: URL
    let engine: SlotEngine
    let mover = AuditWindowMover()
    let presentation: AuditAutoRestorePresentation
    var topology = DisplayTopologyFingerprint(entries: [
        .init(uuid: "audit-display", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), isMain: true)
    ])
    var visible: Bool? = true
    var settleGate: AuditAsyncGate?
    var settleCount = 0
    var recordedSettleTimeouts: [TimeInterval] = []
    var displaysStabilize = true
    var coordinator: AutoRestoreCoordinator?

    init(mode: AutoRestoreMode, settleTimeout: TimeInterval = 10) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PerchAudit-\(UUID())")
        let store = try SlotStore(fileURL: directory.appendingPathComponent("slots.json"))
        engine = SlotEngine(store: store, windowMover: mover, accessibilityTrusted: { true }, displayProvider: { [] })
        presentation = AuditAutoRestorePresentation(engine: engine)
        let snapshot = WindowSnapshot(
            bundleIdentifier: "audit.app", windowTitle: "Test",
            frame: CodableRect(x: 10, y: 20, width: 400, height: 300),
            displayUUID: nil, displayLocalFrame: nil, windowRole: "AXWindow",
            processIdentifier: 1, capturedAt: Date()
        )
        try await store.save(SlotStoreDocument(slots: [Slot(id: "work", name: "Work", windows: [snapshot], capturedTopology: topology)], settings: PerchSettings(stabilizationTimeout: 0, autoRestoreMode: mode, autoRestoreSettleTimeout: settleTimeout)))
    }

    func start() {
        coordinator = AutoRestoreCoordinator(
            slotEngine: engine,
            menuBarController: presentation,
            topologyProvider: { [weak self] in self?.topology },
            makeObserver: { [unowned self] timeout, triggered, visibility, settled in
                EnvironmentChangeObserver(
                    settleTimeout: timeout, onTriggered: triggered,
                    onSessionVisibilityChanged: visibility, onSettled: settled,
                    workspaceCenter: workspaceCenter, applicationCenter: applicationCenter,
                    distributedCenter: distributedCenter,
                    sessionVisibility: { [weak self] in self?.visible ?? nil },
                    waitForStable: { [weak self] timeout in
                        let gate = await MainActor.run {
                            self?.settleCount += 1
                            self?.recordedSettleTimeouts.append(timeout)
                            return self?.settleGate
                        }
                        await gate?.wait()
                        return await self?.displaysStabilize ?? false
                    },
                    sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }
                )
            }
        )
        coordinator?.start()
    }

    func unlock() {
        distributedCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    func stop() {
        coordinator?.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor AuditWindowMover: WindowMoving {
    private(set) var moves = 0
    func move(snapshot: WindowSnapshot, to frame: CGRect, attempts: Int, strictness: MatchStrictness) async throws -> CGRect {
        moves += 1
        return frame
    }
}

@MainActor
private final class AuditAutoRestorePresentation: AutoRestorePresenting {
    let engine: SlotEngine
    var prompts: [AutoRestorePrompt] = []
    var currentPrompt: AutoRestorePrompt?
    var results: [SlotOperationResult] = []
    var restoreCount = 0
    var finishedCount = 0
    var restoreGate: AuditAsyncGate?
    var lastDecision: LocalizationKey?

    init(engine: SlotEngine) { self.engine = engine }

    func restoreLayout(id: String, preflight: RestorePreflight?) -> Task<Void, Never> {
        restoreCount += 1
        return Task { @MainActor in
            defer { finishedCount += 1 }
            await restoreGate?.wait()
            do {
                results.append(try await engine.restore(slotID: id, preflight: preflight))
            } catch { }
        }
    }

    func registeredRestoreShortcutDescription(for layoutID: String, in document: SlotStoreDocument) -> String? { nil }
    func updateLastAutomaticDecision(key: LocalizationKey, argument: String?) { lastDecision = key }
    func showRestorePrompt(_ prompt: AutoRestorePrompt) -> Bool {
        prompts.append(prompt)
        currentPrompt = prompt
        return true
    }
    func invalidateRestorePrompt() { currentPrompt = nil }
}
