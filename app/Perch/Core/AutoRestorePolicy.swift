import Foundation

/// The signal that caused an automatic-restore decision. These values are
/// independent of AppKit so wake semantics remain part of the pure policy.
enum EnvironmentChangeReason: String, Sendable {
    case applicationLaunch
    case systemWake
    case screensWake
    case displayReconfiguration
    case screenUnlock
    case sessionActive

    var isWake: Bool {
        switch self {
        case .systemWake, .screensWake:
            true
        case .applicationLaunch, .displayReconfiguration, .screenUnlock, .sessionActive:
            false
        }
    }

    /// Login items can start after every wake/session notification was posted.
    /// Startup therefore needs its own restore opportunity, even on unchanged displays.
    var requiresRestoreEvaluation: Bool { isWake || self == .applicationLaunch }

    /// Keep wake intent when macOS follows a wake notification with display,
    /// unlock, or session callbacks in the same coalesced burst. For bursts
    /// without a wake, preserve the existing last-signal diagnostic behavior.
    func coalesced(with newerReason: Self) -> Self {
        if requiresRestoreEvaluation {
            return self
        }
        if newerReason.requiresRestoreEvaluation {
            return newerReason
        }
        return newerReason
    }
}

/// Pure state used by the observer to retain wake intent across coalesced
/// callbacks and the secure login UI. A wake received while the session is
/// hidden is consumed by the first visible unlock/session burst.
struct EnvironmentChangeReasonAccumulator: Sendable {
    private var activeReason: EnvironmentChangeReason?
    private var deferredWakeReason: EnvironmentChangeReason?

    /// Returns the reason that should start a new visible burst, or nil when
    /// this signal only updates an existing/deferred burst.
    mutating func receive(
        _ reason: EnvironmentChangeReason,
        isSessionVisible: Bool,
        beginsNewBurst: Bool
    ) -> EnvironmentChangeReason? {
        guard isSessionVisible else {
            deferWakeIfNeeded(reason)
            return nil
        }

        var effectiveReason = reason
        if let deferredWakeReason {
            effectiveReason = deferredWakeReason.coalesced(with: effectiveReason)
            self.deferredWakeReason = nil
        }

        if beginsNewBurst {
            activeReason = (activeReason ?? effectiveReason).coalesced(with: effectiveReason)
            return activeReason
        }

        activeReason = (activeReason ?? effectiveReason).coalesced(with: effectiveReason)
        return nil
    }

    mutating func sessionBecameHidden() {
        if let activeReason {
            deferWakeIfNeeded(activeReason)
        }
        activeReason = nil
    }

    mutating func finish(fallback: EnvironmentChangeReason) -> EnvironmentChangeReason {
        let reason = activeReason ?? fallback
        activeReason = nil
        return reason
    }

    mutating func reset() {
        activeReason = nil
        deferredWakeReason = nil
    }

    private mutating func deferWakeIfNeeded(_ reason: EnvironmentChangeReason) {
        guard reason.requiresRestoreEvaluation else { return }
        deferredWakeReason = (deferredWakeReason ?? reason).coalesced(with: reason)
    }
}

enum AutoRestoreDecision: Equatable, Sendable {
    case doNothing(reason: String)
    case prompt(layoutID: String, layoutName: String)
    case restore(layoutID: String, layoutName: String)
}

struct AutoRestoreInput: Sendable {
    var mode: AutoRestoreMode
    var trigger: EnvironmentChangeReason
    var currentTopology: DisplayTopologyFingerprint
    var topologyAtLastDecision: DisplayTopologyFingerprint?
    var slots: [Slot]
    var userInteractedSinceTrigger: Bool
    var alreadyPromptedForCurrentTopology: Bool
}

enum AutoRestorePolicy {
    static func decide(_ input: AutoRestoreInput) -> AutoRestoreDecision {
        guard input.mode != .off else {
            return .doNothing(reason: "disabled")
        }

        // A wake is a new restore opportunity even when the connected display
        // UUIDs did not change: macOS may still have scattered windows while
        // sleeping. Other callbacks remain topology-gated to avoid false
        // prompts from unlock/session activity and no-op display events.
        guard input.trigger.requiresRestoreEvaluation ||
                input.topologyAtLastDecision?.matchesIdentity(of: input.currentTopology) != true
        else {
            return .doNothing(reason: "topology unchanged")
        }

        // "Already offered" suppresses duplicate callbacks for one display
        // transition, but must not suppress a later, distinct wake cycle.
        guard input.trigger.requiresRestoreEvaluation || !input.alreadyPromptedForCurrentTopology else {
            return .doNothing(reason: "already offered")
        }

        guard let candidate = input.slots
            .filter({ $0.capturedTopology?.matchesIdentity(of: input.currentTopology) == true })
            .max(by: wasSavedBefore)
        else {
            return .doNothing(reason: "no layout for this arrangement")
        }

        guard !candidate.windows.isEmpty else {
            return .doNothing(reason: "layout is empty")
        }

        if input.mode == .automatic, !input.userInteractedSinceTrigger {
            return .restore(layoutID: candidate.id, layoutName: candidate.name)
        }

        return .prompt(layoutID: candidate.id, layoutName: candidate.name)
    }

    private static func wasSavedBefore(_ lhs: Slot, _ rhs: Slot) -> Bool {
        switch (lhs.lastSaved, rhs.lastSaved) {
        case let (.some(lhsDate), .some(rhsDate)):
            lhsDate < rhsDate
        case (.none, .some):
            true
        case (.some, .none), (.none, .none):
            false
        }
    }
}
