import CoreGraphics
import XCTest

final class AutoRestoreAttemptStateTests: XCTestCase {
    func testInternalInvalidationRollsBackPendingPromptForSameTopologyReoffer() throws {
        let oldTopology = topology(main: "laptop", "laptop")
        let newTopology = topology(main: "dock", "dock", "laptop")
        var state = AutoRestoreAttemptState()
        state.establishBaseline(oldTopology)
        state.prepareForDecision(currentTopology: newTopology)

        let attempt = try XCTUnwrap(state.record(
            decision: .prompt(layoutID: "work", layoutName: "Work"),
            topology: newTopology,
            generation: 1
        ))

        XCTAssertTrue(state.isPending(attempt.id, kind: .prompt))
        XCTAssertTrue(state.invalidatePending(attempt.id))
        XCTAssertNil(state.topologyAtLastDecision)
        XCTAssertFalse(state.alreadyPromptedForCurrentTopology)
        XCTAssertEqual(
            decision(using: state, topology: newTopology),
            .prompt(layoutID: "work", layoutName: "Work")
        )
    }

    func testUserDismissalKeepsBaselineAndPreventsSameTopologyReoffer() throws {
        let currentTopology = topology(main: "dock", "dock", "laptop")
        var state = AutoRestoreAttemptState()
        let attempt = try XCTUnwrap(state.record(
            decision: .prompt(layoutID: "work", layoutName: "Work"),
            topology: currentTopology,
            generation: 2
        ))

        XCTAssertTrue(state.complete(attempt.id))
        XCTAssertFalse(state.invalidatePending())
        XCTAssertTrue(state.topologyAtLastDecision?.matchesIdentity(of: currentTopology) == true)
        XCTAssertTrue(state.alreadyPromptedForCurrentTopology)
        XCTAssertEqual(
            decision(using: state, topology: currentTopology),
            .doNothing(reason: "topology unchanged")
        )
    }

    func testInternalInvalidationRollsBackUncommittedAutomaticRestoreForReoffer() throws {
        let currentTopology = topology(main: "dock", "dock", "laptop")
        var state = AutoRestoreAttemptState()
        let attempt = try XCTUnwrap(state.record(
            decision: .restore(layoutID: "work", layoutName: "Work"),
            topology: currentTopology,
            generation: 7
        ))

        XCTAssertTrue(state.invalidatePending(attempt.id))
        XCTAssertEqual(
            decision(using: state, topology: currentTopology, mode: .automatic),
            .restore(layoutID: "work", layoutName: "Work")
        )
    }

    func testCommittedAutomaticRestoreKeepsBaseline() throws {
        let currentTopology = topology(main: "dock", "dock", "laptop")
        var state = AutoRestoreAttemptState()
        let attempt = try XCTUnwrap(state.record(
            decision: .restore(layoutID: "work", layoutName: "Work"),
            topology: currentTopology,
            generation: 3
        ))

        XCTAssertTrue(state.commit(attempt.id))
        XCTAssertFalse(state.invalidatePending())
        XCTAssertTrue(state.topologyAtLastDecision?.matchesIdentity(of: currentTopology) == true)
        XCTAssertEqual(
            decision(using: state, topology: currentTopology),
            .doNothing(reason: "topology unchanged")
        )
    }

    func testStaleAttemptCannotMutateNewerPendingAttempt() throws {
        let currentTopology = topology(main: "dock", "dock")
        var state = AutoRestoreAttemptState()
        let oldAttempt = try XCTUnwrap(state.record(
            decision: .prompt(layoutID: "old", layoutName: "Old"),
            topology: currentTopology,
            generation: 4
        ))
        XCTAssertTrue(state.invalidatePending(oldAttempt.id))
        let newAttempt = try XCTUnwrap(state.record(
            decision: .restore(layoutID: "new", layoutName: "New"),
            topology: currentTopology,
            generation: 5
        ))

        XCTAssertFalse(state.complete(oldAttempt.id))
        XCTAssertTrue(state.isPending(newAttempt.id, kind: .automatic))
    }

    func testAutomaticAttemptCanDowngradeAndReturnToAutomaticOnConfirmation() throws {
        let currentTopology = topology(main: "dock", "dock")
        var state = AutoRestoreAttemptState()
        let attempt = try XCTUnwrap(state.record(
            decision: .restore(layoutID: "work", layoutName: "Work"),
            topology: currentTopology,
            generation: 6
        ))

        XCTAssertTrue(state.downgradeToPrompt(attempt.id))
        XCTAssertTrue(state.isPending(attempt.id, kind: .prompt))
        XCTAssertTrue(state.transitionToAutomatic(attempt.id))
        XCTAssertTrue(state.isPending(attempt.id, kind: .automatic))
    }

    func testRetryCanBeClaimedOnlyOncePerGeneration() {
        var state = AutoRestoreRetryState()

        XCTAssertTrue(state.claimRetry(for: 10))
        XCTAssertFalse(state.claimRetry(for: 10))
        XCTAssertTrue(state.claimRetry(for: 11))
        XCTAssertFalse(state.claimRetry(for: 11))

        state.reset()
        XCTAssertTrue(state.claimRetry(for: 11))
    }

    func testLateTaskCompletionCannotFinishReplacementTaskForSameAttempt() {
        var state = AutoRestoreTaskTokenState()
        let downgradedTask = state.begin()
        let confirmedTask = state.begin()

        XCTAssertFalse(state.finish(downgradedTask))
        XCTAssertTrue(state.isCurrent(confirmedTask))
        XCTAssertTrue(state.finish(confirmedTask))
        XCTAssertNil(state.currentToken)
    }

    func testLateDisplayWaveRetainsWakeForReplacementDecision() {
        var state = AutoRestoreDecisionContextState()

        _ = state.begin(
            generation: 1,
            reason: .systemWake
        )
        let replacement = state.begin(
            generation: 2,
            reason: .displayReconfiguration
        )

        XCTAssertEqual(replacement.reason, .systemWake)
    }

    func testStaleDecisionCannotClearReplacementContext() throws {
        var state = AutoRestoreDecisionContextState()
        _ = state.begin(
            generation: 1,
            reason: .systemWake
        )
        _ = state.begin(
            generation: 2,
            reason: .displayReconfiguration
        )

        state.finish(generation: 1)

        XCTAssertEqual(try XCTUnwrap(state.context).generation, 2)
        XCTAssertEqual(try XCTUnwrap(state.context).reason, .systemWake)
    }

    func testPendingPromptRetainsContextForLateDisplayWave() throws {
        var state = AutoRestoreDecisionContextState()
        _ = state.begin(
            generation: 1,
            reason: .systemWake
        )

        state.finish(generation: 1, hasPendingAttempt: true)
        let replacement = state.begin(
            generation: 2,
            reason: .displayReconfiguration
        )

        XCTAssertEqual(replacement.reason, .systemWake)
    }

    func testFinishedWakeDoesNotLeakIntoIndependentDisplayBurst() throws {
        var state = AutoRestoreDecisionContextState()
        _ = state.begin(
            generation: 1,
            reason: .screensWake
        )
        state.finish(generation: 1)

        let next = state.begin(
            generation: 2,
            reason: .displayReconfiguration
        )

        XCTAssertEqual(next.reason, .displayReconfiguration)
    }

    func testHiddenSessionCarriesWakeIntoUnlock() {
        var state = AutoRestoreDecisionContextState()
        _ = state.begin(
            generation: 1,
            reason: .systemWake
        )
        state.sessionBecameHidden()
        let unlock = state.begin(
            generation: 2,
            reason: .screenUnlock
        )

        XCTAssertEqual(unlock.reason, .systemWake)
    }

    private func topology(
        main mainUUID: String,
        _ uuids: String...
    ) -> DisplayTopologyFingerprint {
        DisplayTopologyFingerprint(entries: uuids.map { uuid in
            .init(
                uuid: uuid,
                bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                isMain: uuid == mainUUID
            )
        })
    }

    private func decision(
        using state: AutoRestoreAttemptState,
        topology: DisplayTopologyFingerprint,
        mode: AutoRestoreMode = .prompt
    ) -> AutoRestoreDecision {
        let display = topology.entries[0]
        let snapshot = WindowSnapshot(
            bundleIdentifier: "com.example.app",
            windowTitle: "Window",
            frame: CodableRect(display.bounds),
            displayUUID: display.uuid,
            displayLocalFrame: CodableRect(display.bounds),
            windowRole: "AXWindow",
            processIdentifier: 42,
            capturedAt: Date(timeIntervalSince1970: 1)
        )

        return AutoRestorePolicy.decide(AutoRestoreInput(
            mode: mode,
            trigger: .displayReconfiguration,
            currentTopology: topology,
            topologyAtLastDecision: state.topologyAtLastDecision,
            slots: [Slot(
                id: "work",
                name: "Work",
                windows: [snapshot],
                capturedTopology: topology
            )],
            alreadyPromptedForCurrentTopology: state.alreadyPromptedForCurrentTopology
        ))
    }
}
