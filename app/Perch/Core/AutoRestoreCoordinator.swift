import CoreGraphics
import Foundation

private final class AutoRestoreNotificationTokenStore {
    var token: NSObjectProtocol?

    func remove() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }

    deinit {
        remove()
    }
}

@MainActor
final class AutoRestoreCoordinator {
    private static let incompleteTopologyRetryDelayNanoseconds: UInt64 = 3_000_000_000

    private let slotEngine: SlotEngine
    let menuBarController: any AutoRestorePresenting
    private let topologyProvider: @MainActor () -> DisplayTopologyFingerprint?
    private let interactionProvider: @MainActor (Date) -> Bool
    private let makeObserver: ObserverFactory

    typealias ObserverFactory = @MainActor (
        @escaping EnvironmentChangeObserver.SettleTimeoutProvider,
        @escaping EnvironmentChangeObserver.TriggeredHandler,
        @escaping EnvironmentChangeObserver.SessionVisibilityHandler,
        @escaping EnvironmentChangeObserver.SettledHandler
    ) -> EnvironmentChangeObserver

    private var environmentObserver: EnvironmentChangeObserver?
    private let documentChangeObserver = AutoRestoreNotificationTokenStore()
    private var decisionTask: Task<Void, Never>?
    private var incompleteTopologyRetryTask: Task<Void, Never>?
    var automaticRestoreTask: Task<Void, Never>?
    var automaticRestoreAttemptID: Int?
    var restoreTaskTokens = AutoRestoreTaskTokenState()
    var automaticRestoreHasCommitted = false
    var attemptState = AutoRestoreAttemptState()
    private var retryState = AutoRestoreRetryState()
    var decisionContextState = AutoRestoreDecisionContextState()
    var triggerGeneration = 0
    private var settleTimeout: TimeInterval = 10
    var isSessionVisible = true
    var isStarted = false

    init(
        slotEngine: SlotEngine,
        menuBarController: any AutoRestorePresenting,
        topologyProvider: @escaping @MainActor () -> DisplayTopologyFingerprint? = {
            DisplayManager.currentTopologyFingerprint()
        },
        interactionProvider: @escaping @MainActor (Date) -> Bool = {
            UserInteractionMonitor.interacted(since: $0)
        },
        makeObserver: @escaping ObserverFactory = {
            EnvironmentChangeObserver(settleTimeout: $0, onTriggered: $1, onSessionVisibilityChanged: $2, onSettled: $3)
        }
    ) {
        self.slotEngine = slotEngine
        self.menuBarController = menuBarController
        self.topologyProvider = topologyProvider
        self.interactionProvider = interactionProvider
        self.makeObserver = makeObserver
    }

    deinit {
        decisionTask?.cancel()
        incompleteTopologyRetryTask?.cancel()
        if !automaticRestoreHasCommitted {
            automaticRestoreTask?.cancel()
        }
    }

    var hasCommittedAutomaticRestoreInFlight: Bool {
        automaticRestoreHasCommitted && automaticRestoreTask != nil
    }

    func waitForCommittedAutomaticRestoreIfNeeded() async {
        guard hasCommittedAutomaticRestoreInFlight,
              let automaticRestoreTask
        else {
            return
        }

        await automaticRestoreTask.value
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Establish a baseline so no-op display, unlock, and session callbacks
        // do not offer a restore. Wake is intentionally allowed through the
        // policy even when display UUIDs are unchanged because macOS may still
        // have relocated windows while asleep.
        attemptState.establishBaseline(currentTopology())
        retryState.reset()
        decisionContextState.reset()

        let observer = makeObserver(
            { [weak self] in
                // Startup may reach this before the asynchronous initial
                // settings refresh. Honor the saved timeout on the first wait.
                await self?.refreshSettings()
                return self?.settleTimeout ?? 10
            },
            { [weak self] reason in
                self?.environmentTriggered(reason: reason)
            },
            { [weak self] isVisible in
                self?.sessionVisibilityChanged(isVisible: isVisible)
            },
            { [weak self] reason in
                self?.environmentSettled(reason: reason)
            }
        )
        environmentObserver = observer
        observer.start()

        documentChangeObserver.token = NotificationCenter.default.addObserver(
            forName: .perchDocumentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshSettings()
            }
        }

        Task { @MainActor [weak self] in
            await self?.refreshSettings()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        triggerGeneration &+= 1
        decisionTask?.cancel()
        decisionTask = nil
        incompleteTopologyRetryTask?.cancel()
        incompleteTopologyRetryTask = nil
        retryState.reset()

        _ = attemptState.invalidatePending()
        if !automaticRestoreHasCommitted {
            automaticRestoreTask?.cancel()
            automaticRestoreTask = nil
            automaticRestoreAttemptID = nil
            restoreTaskTokens.invalidate()
        }

        decisionContextState.reset()
        environmentObserver?.stop()
        environmentObserver = nil
        menuBarController.invalidateRestorePrompt()
        documentChangeObserver.remove()
    }

    private func environmentTriggered(reason: EnvironmentChangeReason) {
        triggerGeneration &+= 1
        _ = decisionContextState.begin(
            generation: triggerGeneration,
            reason: reason,
            triggerStartedAt: Date()
        )
        retryState.reset()
        incompleteTopologyRetryTask?.cancel()
        incompleteTopologyRetryTask = nil

        // A prompt or uncommitted automatic attempt created for the previous
        // stable arrangement is unsafe as soon as a new burst starts. Roll its
        // baseline back before dismissing the prompt so the same final display
        // identity can be offered again after a late DisplayLink wave.
        decisionTask?.cancel()
        decisionTask = nil
        let rolledBackPendingAttempt = attemptState.invalidatePending()
        if !automaticRestoreHasCommitted {
            automaticRestoreTask?.cancel()
            automaticRestoreTask = nil
            automaticRestoreAttemptID = nil
            restoreTaskTokens.invalidate()
        }
        menuBarController.invalidateRestorePrompt()

        AppLog.display.debug(
            "Invalidated automatic restore state for trigger \(reason.rawValue, privacy: .public); rolledBackPendingAttempt=\(rolledBackPendingAttempt)"
        )
    }

    private func sessionVisibilityChanged(isVisible: Bool) {
        guard self.isSessionVisible != isVisible else { return }
        self.isSessionVisible = isVisible
        guard !isVisible else { return }

        triggerGeneration &+= 1
        decisionContextState.sessionBecameHidden()
        retryState.reset()
        decisionTask?.cancel()
        decisionTask = nil
        incompleteTopologyRetryTask?.cancel()
        incompleteTopologyRetryTask = nil

        // Never let a pending offer expire invisibly behind the secure login UI.
        // A committed restore is allowed to finish so it can still report its
        // complete result; unresolved work is rolled back for the unlock burst.
        _ = attemptState.invalidatePending()
        if !automaticRestoreHasCommitted {
            automaticRestoreTask?.cancel()
            automaticRestoreTask = nil
            automaticRestoreAttemptID = nil
            restoreTaskTokens.invalidate()
        }
        menuBarController.invalidateRestorePrompt()
    }

    private func environmentSettled(reason: EnvironmentChangeReason) {
        let generation = triggerGeneration
        let context = decisionContextState.begin(
            generation: generation,
            reason: reason,
            triggerStartedAt: Date()
        )
        decisionTask?.cancel()
        decisionTask = Task { @MainActor [weak self] in
            await self?.decideAfterEnvironmentSettled(
                reason: context.reason,
                generation: generation,
                triggerStartedAt: context.triggerStartedAt
            )
        }
    }

    private func decideAfterEnvironmentSettled(
        reason: EnvironmentChangeReason,
        generation: Int,
        triggerStartedAt: Date
    ) async {
        guard isStarted,
              isSessionVisible,
              generation == triggerGeneration,
              !Task.isCancelled
        else { return }

        // Once the final preflight has passed, let that restore finish so a
        // cancellation cannot leave a partially moved layout without a report.
        // A new topology decision waits for the shared manual restore path to
        // produce its normal result toast first.
        if automaticRestoreHasCommitted, let automaticRestoreTask {
            await automaticRestoreTask.value
            guard isStarted,
                  isSessionVisible,
                  generation == triggerGeneration,
                  !Task.isCancelled
            else { return }
            self.automaticRestoreTask = nil
            automaticRestoreAttemptID = nil
            restoreTaskTokens.invalidate()
            automaticRestoreHasCommitted = false
        }

        do {
            let document = try await slotEngine.currentDocument()
            guard isStarted,
                  isSessionVisible,
                  generation == triggerGeneration,
                  !Task.isCancelled
            else { return }

            settleTimeout = document.settings.autoRestoreSettleTimeout

            guard let currentTopology = currentTopology() else {
                handleIncompleteTopology(
                    reason: reason,
                    generation: generation,
                    triggerStartedAt: triggerStartedAt
                )
                return
            }

            let topologyChanged = attemptState.topologyAtLastDecision?
                .matchesIdentity(of: currentTopology) != true
            attemptState.prepareForDecision(currentTopology: currentTopology)
            if topologyChanged {
                menuBarController.invalidateRestorePrompt()
            }

            let decision = AutoRestorePolicy.decide(AutoRestoreInput(
                mode: document.settings.autoRestoreMode,
                trigger: reason,
                currentTopology: currentTopology,
                topologyAtLastDecision: attemptState.topologyAtLastDecision,
                slots: document.slots,
                userInteractedSinceTrigger: userInteractedSinceTrigger(
                    startedAt: triggerStartedAt
                ),
                alreadyPromptedForCurrentTopology: attemptState.alreadyPromptedForCurrentTopology
            ))

            let pendingAttempt = attemptState.record(
                decision: decision,
                topology: currentTopology,
                generation: generation
            )
            let shouldFinishDecision = apply(
                decision,
                pendingAttempt: pendingAttempt,
                document: document,
                currentTopology: currentTopology,
                generation: generation,
                triggerStartedAt: triggerStartedAt,
                trigger: reason
            )
            guard shouldFinishDecision else { return }
        } catch {
            AppLog.display.error(
                "Automatic restore decision failed: \(error.localizedDescription, privacy: .private)"
            )
            recordDecision(
                menuKey: .autoRestoreDecisionError,
                diagnosticCode: "error",
                trigger: reason
            )
        }

        finishDecision(generation: generation)
    }

    func handleIncompleteTopology(
        reason: EnvironmentChangeReason,
        generation: Int,
        triggerStartedAt: Date
    ) {
        guard retryState.claimRetry(for: generation) else {
            AppLog.display.warning(
                "Automatic restore skipped because the display topology remained incomplete after one retry"
            )
            recordDecision(
                menuKey: .autoRestoreDecisionTopologyIncomplete,
                diagnosticCode: "do-nothing:topology-incomplete-final",
                trigger: reason
            )
            finishDecision(generation: generation)
            return
        }

        AppLog.display.warning(
            "Automatic restore deferred because the display topology is incomplete; scheduling one retry"
        )
        recordDecision(
            menuKey: .autoRestoreDecisionTopologyIncomplete,
            diagnosticCode: "deferred:topology-incomplete-retry",
            trigger: reason
        )
        decisionTask = nil
        scheduleIncompleteTopologyRetry(
            reason: reason,
            generation: generation,
            triggerStartedAt: triggerStartedAt
        )
    }

    private func scheduleIncompleteTopologyRetry(
        reason: EnvironmentChangeReason,
        generation: Int,
        triggerStartedAt: Date
    ) {
        incompleteTopologyRetryTask?.cancel()
        incompleteTopologyRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.incompleteTopologyRetryDelayNanoseconds
                )
            } catch {
                return
            }

            guard let self,
                  self.isStarted,
                  self.isSessionVisible,
                  generation == self.triggerGeneration,
                  !Task.isCancelled
            else {
                return
            }

            await self.decideAfterEnvironmentSettled(
                reason: reason,
                generation: generation,
                triggerStartedAt: triggerStartedAt
            )
        }
    }

    private func finishDecision(generation: Int) {
        guard generation == triggerGeneration else { return }
        decisionContextState.finish(
            generation: generation,
            hasPendingAttempt: attemptState.pendingAttempt != nil
        )
        decisionTask = nil
        incompleteTopologyRetryTask = nil
    }

    private func refreshSettings() async {
        do {
            let document = try await slotEngine.currentDocument()
            settleTimeout = document.settings.autoRestoreSettleTimeout
            if document.settings.autoRestoreMode == .off, attemptState.pendingAttempt != nil {
                _ = attemptState.invalidatePending()
                if !automaticRestoreHasCommitted {
                    automaticRestoreTask?.cancel()
                    automaticRestoreTask = nil
                    automaticRestoreAttemptID = nil
                    restoreTaskTokens.invalidate()
                }
                decisionContextState.reset()
                menuBarController.invalidateRestorePrompt()
            }
        } catch {
            AppLog.display.error(
                "Failed to refresh automatic restore settings: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func recordDecision(
        menuKey: LocalizationKey,
        menuArgument: String? = nil,
        diagnosticCode: String,
        trigger: EnvironmentChangeReason
    ) {
        AutoRestoreDiagnostics.record(decision: diagnosticCode, trigger: trigger)
        menuBarController.updateLastAutomaticDecision(
            key: menuKey,
            argument: menuArgument
        )
    }

    func localizationKey(forNoActionReason reason: String) -> LocalizationKey {
        switch reason {
        case "disabled": .autoRestoreDecisionDisabled
        case "topology unchanged": .autoRestoreDecisionTopologyUnchanged
        case "already offered": .autoRestoreDecisionAlreadyOffered
        case "no layout for this arrangement": .autoRestoreDecisionNoLayout
        case "layout is empty": .autoRestoreDecisionEmptyLayout
        default: .autoRestoreDecisionError
        }
    }

    func currentTopology() -> DisplayTopologyFingerprint? {
        topologyProvider()
    }

    func userInteractedSinceTrigger(startedAt: Date) -> Bool {
        interactionProvider(startedAt)
    }
}
