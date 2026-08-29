import Foundation

/// Pure bookkeeping for the coordinator's actionable decisions.
///
/// A topology becomes the baseline as soon as a decision is made. If an
/// internal environment event invalidates a prompt or an automatic restore
/// before it commits, that baseline must be rolled back so the same final
/// topology can be offered again. User dismissal and a committed restore are
/// terminal and deliberately keep the baseline.
struct AutoRestoreAttemptState: Equatable, Sendable {
    enum PendingKind: Equatable, Sendable {
        case prompt
        case automatic
    }

    struct PendingAttempt: Equatable, Sendable {
        let id: Int
        let generation: Int
        var kind: PendingKind
    }

    private(set) var topologyAtLastDecision: DisplayTopologyFingerprint?
    private(set) var alreadyPromptedForCurrentTopology = false
    private(set) var pendingAttempt: PendingAttempt?
    private var nextAttemptID = 0

    mutating func establishBaseline(_ topology: DisplayTopologyFingerprint?) {
        topologyAtLastDecision = topology
        alreadyPromptedForCurrentTopology = false
        pendingAttempt = nil
    }

    mutating func prepareForDecision(currentTopology: DisplayTopologyFingerprint) {
        if topologyAtLastDecision?.matchesIdentity(of: currentTopology) != true {
            alreadyPromptedForCurrentTopology = false
        }
    }

    @discardableResult
    mutating func record(
        decision: AutoRestoreDecision,
        topology: DisplayTopologyFingerprint,
        generation: Int
    ) -> PendingAttempt? {
        topologyAtLastDecision = topology

        let kind: PendingKind
        switch decision {
        case .doNothing:
            pendingAttempt = nil
            return nil
        case .prompt:
            alreadyPromptedForCurrentTopology = true
            kind = .prompt
        case .restore:
            kind = .automatic
        }

        nextAttemptID &+= 1
        let attempt = PendingAttempt(
            id: nextAttemptID,
            generation: generation,
            kind: kind
        )
        pendingAttempt = attempt
        return attempt
    }

    func isPending(_ attemptID: Int, kind: PendingKind? = nil) -> Bool {
        guard let pendingAttempt, pendingAttempt.id == attemptID else {
            return false
        }
        return kind == nil || pendingAttempt.kind == kind
    }

    @discardableResult
    mutating func transitionToAutomatic(_ attemptID: Int) -> Bool {
        guard isPending(attemptID, kind: .prompt) else { return false }
        pendingAttempt?.kind = .automatic
        return true
    }

    @discardableResult
    mutating func downgradeToPrompt(_ attemptID: Int) -> Bool {
        guard isPending(attemptID, kind: .automatic) else { return false }
        pendingAttempt?.kind = .prompt
        alreadyPromptedForCurrentTopology = true
        return true
    }

    /// Marks an attempt terminal while retaining the topology baseline.
    @discardableResult
    mutating func complete(_ attemptID: Int) -> Bool {
        guard isPending(attemptID) else { return false }
        pendingAttempt = nil
        return true
    }

    /// Commits an automatic attempt while retaining the topology baseline.
    @discardableResult
    mutating func commit(_ attemptID: Int) -> Bool {
        guard isPending(attemptID, kind: .automatic) else { return false }
        pendingAttempt = nil
        return true
    }

    /// Invalidates an unresolved action and rolls back the decision baseline.
    /// Stale callbacks can pass an ID and cannot invalidate a newer attempt.
    @discardableResult
    mutating func invalidatePending(_ attemptID: Int? = nil) -> Bool {
        guard let pendingAttempt,
              attemptID == nil || pendingAttempt.id == attemptID
        else {
            return false
        }

        self.pendingAttempt = nil
        topologyAtLastDecision = nil
        alreadyPromptedForCurrentTopology = false
        return true
    }
}

/// Allows one delayed topology re-check per environment generation.
struct AutoRestoreRetryState: Equatable, Sendable {
    private(set) var claimedGeneration: Int?

    mutating func claimRetry(for generation: Int) -> Bool {
        guard claimedGeneration != generation else { return false }
        claimedGeneration = generation
        return true
    }

    mutating func reset() {
        claimedGeneration = nil
    }
}

/// Distinguishes consecutive restore tasks that belong to the same logical
/// attempt (automatic → prompt → confirmed automatic). A late completion from
/// the first task must never clear the replacement task.
struct AutoRestoreTaskTokenState: Equatable, Sendable {
    private(set) var currentToken: Int?
    private var nextToken = 0

    mutating func begin() -> Int {
        nextToken &+= 1
        currentToken = nextToken
        return nextToken
    }

    func isCurrent(_ token: Int) -> Bool {
        currentToken == token
    }

    @discardableResult
    mutating func finish(_ token: Int) -> Bool {
        guard isCurrent(token) else { return false }
        currentToken = nil
        return true
    }

    mutating func invalidate() {
        currentToken = nil
    }
}

/// Retains the semantic trigger while one automatic-restore decision is still
/// unresolved. A late display callback may begin a replacement generation
/// while the previous decision is suspended on disk I/O; wake intent and the
/// earliest interaction timestamp must survive that replacement.
struct AutoRestoreDecisionContextState: Sendable {
    struct Context: Sendable {
        let generation: Int
        let reason: EnvironmentChangeReason
        let triggerStartedAt: Date
    }

    private(set) var context: Context?
    private var deferredWakeReason: EnvironmentChangeReason?

    @discardableResult
    mutating func begin(
        generation: Int,
        reason: EnvironmentChangeReason,
        triggerStartedAt: Date
    ) -> Context {
        var effectiveReason = reason
        var effectiveStartedAt = triggerStartedAt

        if let context {
            effectiveReason = context.reason.coalesced(with: effectiveReason)
            effectiveStartedAt = min(context.triggerStartedAt, effectiveStartedAt)
        } else if let deferredWakeReason {
            effectiveReason = deferredWakeReason.coalesced(with: effectiveReason)
        }

        deferredWakeReason = nil
        let nextContext = Context(
            generation: generation,
            reason: effectiveReason,
            triggerStartedAt: effectiveStartedAt
        )
        context = nextContext
        return nextContext
    }

    mutating func finish(
        generation: Int,
        hasPendingAttempt: Bool = false
    ) {
        guard context?.generation == generation else { return }
        guard !hasPendingAttempt else { return }
        context = nil
    }

    mutating func sessionBecameHidden() {
        if let reason = context?.reason, reason.isWake {
            deferredWakeReason = reason
        }
        context = nil
    }

    mutating func reset() {
        context = nil
        deferredWakeReason = nil
    }
}
