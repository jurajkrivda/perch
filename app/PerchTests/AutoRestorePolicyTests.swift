import CoreGraphics
import Foundation
import XCTest

final class AutoRestorePolicyTests: XCTestCase {
    func testOffModeDoesNothingBeforeAllOtherChecks() {
        let topology = makeTopology(uuid: "current")
        let input = makeInput(
            mode: .off,
            trigger: .systemWake,
            currentTopology: topology,
            topologyAtLastDecision: topology,
            slots: [makeSlot(topology: topology)],
            alreadyPromptedForCurrentTopology: true
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .doNothing(reason: "disabled")
        )
    }

    func testUnchangedTopologyFromDisplayCallbackDoesNothingBeforeAlreadyOfferedCheck() {
        let current = makeTopology(uuid: "current", x: 1)
        let sameIdentityWithDifferentBounds = makeTopology(uuid: "current", x: 500)
        let input = makeInput(
            currentTopology: current,
            topologyAtLastDecision: sameIdentityWithDifferentBounds,
            slots: [makeSlot(topology: current)],
            alreadyPromptedForCurrentTopology: true
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .doNothing(reason: "topology unchanged")
        )
    }

    func testWakeWithUnchangedTopologyOffersPromptAgain() {
        let topology = makeTopology(uuid: "current")
        let input = makeInput(
            trigger: .systemWake,
            currentTopology: topology,
            topologyAtLastDecision: topology,
            slots: [makeSlot(id: "work", name: "Work", topology: topology)],
            alreadyPromptedForCurrentTopology: true
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .prompt(layoutID: "work", layoutName: "Work")
        )
    }

    func testWakeWithUnchangedTopologyRestoresInAutomaticMode() {
        let topology = makeTopology(uuid: "current")
        let input = makeInput(
            mode: .automatic,
            trigger: .screensWake,
            currentTopology: topology,
            topologyAtLastDecision: topology,
            slots: [makeSlot(id: "work", name: "Work", topology: topology)]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .restore(layoutID: "work", layoutName: "Work")
        )
    }

    func testSystemWakeWithUnchangedTopologyRestoresAutomatically() {
        let topology = makeTopology(uuid: "current")
        let input = makeInput(
            mode: .automatic,
            trigger: .systemWake,
            currentTopology: topology,
            topologyAtLastDecision: topology,
            slots: [makeSlot(id: "work", name: "Work", topology: topology)]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .restore(layoutID: "work", layoutName: "Work")
        )
    }

    func testUnlockWithUnchangedTopologyDoesNotTriggerRestore() {
        let topology = makeTopology(uuid: "current")
        let input = makeInput(
            mode: .automatic,
            trigger: .screenUnlock,
            currentTopology: topology,
            topologyAtLastDecision: topology,
            slots: [makeSlot(id: "work", name: "Work", topology: topology)]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .doNothing(reason: "topology unchanged")
        )
    }

    func testCoalescingKeepsWakeIntentAcrossLaterDisplayCallback() {
        XCTAssertEqual(
            EnvironmentChangeReason.systemWake.coalesced(with: .displayReconfiguration),
            .systemWake
        )
        XCTAssertEqual(
            EnvironmentChangeReason.displayReconfiguration.coalesced(with: .screensWake),
            .screensWake
        )
        XCTAssertFalse(
            EnvironmentChangeReason.screenUnlock
                .coalesced(with: .sessionActive)
                .isWake
        )
    }

    func testReplacementDecisionKeepsWakeOpportunityForUnchangedTopology() {
        let topology = makeTopology(uuid: "current")
        var context = AutoRestoreDecisionContextState()
        _ = context.begin(
            generation: 1,
            reason: .systemWake
        )
        let replacement = context.begin(
            generation: 2,
            reason: .displayReconfiguration
        )
        let input = makeInput(
            trigger: replacement.reason,
            currentTopology: topology,
            topologyAtLastDecision: topology,
            slots: [makeSlot(id: "work", name: "Work", topology: topology)]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .prompt(layoutID: "work", layoutName: "Work")
        )
    }

    func testWakeWhileLockedIsDeferredIntoFirstVisibleBurst() {
        var accumulator = EnvironmentChangeReasonAccumulator()

        XCTAssertNil(accumulator.receive(
            .systemWake,
            isSessionVisible: false,
            beginsNewBurst: false
        ))
        XCTAssertEqual(
            accumulator.receive(
                .screenUnlock,
                isSessionVisible: true,
                beginsNewBurst: true
            ),
            .systemWake
        )
        XCTAssertEqual(
            accumulator.finish(fallback: .screenUnlock),
            .systemWake
        )

        XCTAssertEqual(
            accumulator.receive(
                .displayReconfiguration,
                isSessionVisible: true,
                beginsNewBurst: true
            ),
            .displayReconfiguration
        )
        XCTAssertFalse(
            accumulator.finish(fallback: .displayReconfiguration).isWake
        )
    }

    func testLockDuringVisibleWakePreservesWakeForUnlock() {
        var accumulator = EnvironmentChangeReasonAccumulator()

        XCTAssertEqual(
            accumulator.receive(
                .screensWake,
                isSessionVisible: true,
                beginsNewBurst: true
            ),
            .screensWake
        )
        accumulator.sessionBecameHidden()
        XCTAssertEqual(
            accumulator.receive(
                .sessionActive,
                isSessionVisible: true,
                beginsNewBurst: true
            ),
            .screensWake
        )
    }

    func testHiddenNonWakeCallbackDoesNotTurnUnlockIntoWake() {
        var accumulator = EnvironmentChangeReasonAccumulator()

        XCTAssertNil(accumulator.receive(
            .displayReconfiguration,
            isSessionVisible: false,
            beginsNewBurst: false
        ))
        XCTAssertEqual(
            accumulator.receive(
                .screenUnlock,
                isSessionVisible: true,
                beginsNewBurst: true
            ),
            .screenUnlock
        )
        XCTAssertFalse(accumulator.finish(fallback: .screenUnlock).isWake)
    }

    func testAlreadyOfferedTopologyDoesNothingBeforeCandidateLookup() {
        let input = makeInput(
            currentTopology: makeTopology(uuid: "current"),
            slots: [],
            alreadyPromptedForCurrentTopology: true
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .doNothing(reason: "already offered")
        )
    }

    func testNoMatchingLayoutDoesNothing() {
        let input = makeInput(
            currentTopology: makeTopology(uuid: "current"),
            slots: [makeSlot(topology: makeTopology(uuid: "other"))]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .doNothing(reason: "no layout for this arrangement")
        )
    }

    func testPreVersionThreeLayoutWithoutCapturedTopologyIsNeverSelected() {
        let input = makeInput(
            currentTopology: makeTopology(uuid: "current"),
            slots: [makeSlot(topology: nil)]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .doNothing(reason: "no layout for this arrangement")
        )
    }

    func testMatchingLayoutUsesTopologyIdentityRatherThanBounds() {
        let current = makeTopology(uuid: "current", x: 0)
        let captured = makeTopology(uuid: "current", x: 1_000)
        let input = makeInput(
            currentTopology: current,
            slots: [makeSlot(id: "work", name: "Work", topology: captured)]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .prompt(layoutID: "work", layoutName: "Work")
        )
    }

    func testMostRecentlySavedMatchingLayoutWins() {
        let topology = makeTopology(uuid: "current")
        let older = makeSlot(
            id: "older",
            name: "Older",
            lastSaved: Date(timeIntervalSince1970: 100),
            topology: topology
        )
        let newer = makeSlot(
            id: "newer",
            name: "Newer",
            lastSaved: Date(timeIntervalSince1970: 200),
            topology: topology
        )
        let input = makeInput(currentTopology: topology, slots: [older, newer])

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .prompt(layoutID: "newer", layoutName: "Newer")
        )
    }

    func testDatedMatchingLayoutWinsOverLayoutWithoutLastSavedDate() {
        let topology = makeTopology(uuid: "current")
        let undated = makeSlot(id: "undated", name: "Undated", topology: topology)
        let dated = makeSlot(
            id: "dated",
            name: "Dated",
            lastSaved: Date(timeIntervalSince1970: -1),
            topology: topology
        )
        let input = makeInput(currentTopology: topology, slots: [dated, undated])

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .prompt(layoutID: "dated", layoutName: "Dated")
        )
    }

    func testEmptyLayoutDoesNotHideAnOlderUsableLayout() {
        let topology = makeTopology(uuid: "current")
        let populated = makeSlot(
            id: "populated",
            name: "Populated",
            lastSaved: Date(timeIntervalSince1970: 100),
            topology: topology
        )
        let empty = makeSlot(
            id: "empty",
            name: "Empty",
            lastSaved: Date(timeIntervalSince1970: 200),
            topology: topology,
            windows: []
        )
        let input = makeInput(currentTopology: topology, slots: [populated, empty])

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .prompt(layoutID: "populated", layoutName: "Populated")
        )
    }

    func testPromptModeOffersMatchingLayout() {
        let topology = makeTopology(uuid: "current")
        let input = makeInput(
            mode: .prompt,
            currentTopology: topology,
            slots: [makeSlot(id: "work", name: "Work", topology: topology)]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .prompt(layoutID: "work", layoutName: "Work")
        )
    }

    func testAutomaticModeRestoresMatchingLayout() {
        let topology = makeTopology(uuid: "current")
        let input = makeInput(
            mode: .automatic,
            currentTopology: topology,
            slots: [makeSlot(id: "work", name: "Work", topology: topology)]
        )

        XCTAssertEqual(
            AutoRestorePolicy.decide(input),
            .restore(layoutID: "work", layoutName: "Work")
        )
    }

    func testEachModeKeepsItsContractForEveryEligibleEnvironmentTrigger() {
        let topology = makeTopology(uuid: "current")
        let triggers: [EnvironmentChangeReason] = [
            .applicationLaunch, .systemWake, .screensWake,
            .displayReconfiguration, .screenUnlock, .sessionActive
        ]
        for trigger in triggers {
            for mode in AutoRestoreMode.allCases {
                let input = makeInput(
                    mode: mode, trigger: trigger, currentTopology: topology,
                    slots: [makeSlot(id: "work", name: "Work", topology: topology)]
                )
                let expected: AutoRestoreDecision = switch mode {
                case .off: .doNothing(reason: "disabled")
                case .prompt: .prompt(layoutID: "work", layoutName: "Work")
                case .automatic: .restore(layoutID: "work", layoutName: "Work")
                }
                XCTAssertEqual(AutoRestorePolicy.decide(input), expected, "\(mode), \(trigger)")
            }
        }
    }
}

private extension AutoRestorePolicyTests {
    func makeInput(
        mode: AutoRestoreMode = .prompt,
        trigger: EnvironmentChangeReason = .displayReconfiguration,
        currentTopology: DisplayTopologyFingerprint,
        topologyAtLastDecision: DisplayTopologyFingerprint? = nil,
        slots: [Slot],
        alreadyPromptedForCurrentTopology: Bool = false
    ) -> AutoRestoreInput {
        AutoRestoreInput(
            mode: mode,
            trigger: trigger,
            currentTopology: currentTopology,
            topologyAtLastDecision: topologyAtLastDecision,
            slots: slots,
            alreadyPromptedForCurrentTopology: alreadyPromptedForCurrentTopology
        )
    }

    func makeTopology(uuid: String, x: CGFloat = 0) -> DisplayTopologyFingerprint {
        DisplayTopologyFingerprint(displays: [
            DisplayInfo(
                id: 1,
                uuid: uuid,
                bounds: CGRect(x: x, y: 0, width: 1_920, height: 1_080),
                isMain: true
            )
        ])
    }

    func makeSlot(
        id: String = "layout",
        name: String = "Layout",
        lastSaved: Date? = nil,
        topology: DisplayTopologyFingerprint?,
        windows: [WindowSnapshot]? = nil
    ) -> Slot {
        Slot(
            id: id,
            name: name,
            lastSaved: lastSaved,
            windows: windows ?? [makeWindow()],
            capturedTopology: topology
        )
    }

    func makeWindow() -> WindowSnapshot {
        WindowSnapshot(
            id: "window",
            bundleIdentifier: "com.example.app",
            windowTitle: "Window",
            frame: CodableRect(x: 0, y: 0, width: 800, height: 600),
            displayUUID: "current",
            displayLocalFrame: nil,
            windowRole: "AXWindow",
            processIdentifier: 1,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
