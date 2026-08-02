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
enum AutoRestoreDiagnostics {
    private(set) static var lastDecision = "not started"

    static func record(decision: String, trigger: EnvironmentChangeReason) {
        lastDecision = "\(decision); trigger=\(trigger.rawValue)"
    }
}

@MainActor
final class AutoRestoreCoordinator {
    private static let recentInteractionThreshold: TimeInterval = 3
    private static let incompleteTopologyRetryDelayNanoseconds: UInt64 = 3_000_000_000

    private let slotEngine: SlotEngine
    private let menuBarController: MenuBarController

    private var environmentObserver: EnvironmentChangeObserver?
    private let documentChangeObserver = AutoRestoreNotificationTokenStore()
    private var decisionTask: Task<Void, Never>?
    private var incompleteTopologyRetryTask: Task<Void, Never>?
    private var automaticRestoreTask: Task<Void, Never>?
    private var automaticRestoreAttemptID: Int?
    private var restoreTaskTokens = AutoRestoreTaskTokenState()
    private var automaticRestoreHasCommitted = false
    private var attemptState = AutoRestoreAttemptState()
    private var retryState = AutoRestoreRetryState()
    private var triggerGeneration = 0
    private var triggerStartedAt: Date?
    private var settleTimeout: TimeInterval = 10
    private var isSessionVisible = true
    private var isStarted = false

    init(
        slotEngine: SlotEngine,
        menuBarController: MenuBarController
    ) {
        self.slotEngine = slotEngine
        self.menuBarController = menuBarController
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

        let observer = EnvironmentChangeObserver(
            settleTimeout: { [weak self] in
                self?.settleTimeout ?? 10
            },
            onTriggered: { [weak self] reason in
                self?.environmentTriggered(reason: reason)
            },
            onSessionVisibilityChanged: { [weak self] isVisible in
                self?.sessionVisibilityChanged(isVisible: isVisible)
            },
            onSettled: { [weak self] reason in
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

        triggerStartedAt = nil
        environmentObserver?.stop()
        environmentObserver = nil
        RestorePromptWindow.dismissCurrent()
        documentChangeObserver.remove()
    }

    private func environmentTriggered(reason: EnvironmentChangeReason) {
        triggerGeneration &+= 1
        triggerStartedAt = Date()
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
        RestorePromptWindow.dismissCurrent()

        AppLog.display.debug(
            "Invalidated automatic restore state for trigger \(reason.rawValue, privacy: .public); rolledBackPendingAttempt=\(rolledBackPendingAttempt)"
        )
    }

    private func sessionVisibilityChanged(isVisible: Bool) {
        self.isSessionVisible = isVisible
        guard !isVisible else { return }

        triggerGeneration &+= 1
        triggerStartedAt = nil
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
        RestorePromptWindow.dismissCurrent()
    }

    private func environmentSettled(reason: EnvironmentChangeReason) {
        let generation = triggerGeneration
        let startedAt = triggerStartedAt ?? Date()
        decisionTask?.cancel()
        decisionTask = Task { @MainActor [weak self] in
            await self?.decideAfterEnvironmentSettled(
                reason: reason,
                generation: generation,
                triggerStartedAt: startedAt
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
                RestorePromptWindow.dismissCurrent()
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
            apply(
                decision,
                pendingAttempt: pendingAttempt,
                document: document,
                currentTopology: currentTopology,
                generation: generation,
                triggerStartedAt: triggerStartedAt,
                trigger: reason
            )
        } catch {
            AppLog.display.error(
                "Automatic restore decision failed: \(error.localizedDescription, privacy: .public)"
            )
            recordDecision(
                menuKey: .autoRestoreDecisionError,
                diagnosticCode: "error",
                trigger: reason
            )
        }

        finishDecision(generation: generation)
    }

    private func handleIncompleteTopology(
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
        triggerStartedAt = nil
        decisionTask = nil
        incompleteTopologyRetryTask = nil
    }

    private func apply(
        _ decision: AutoRestoreDecision,
        pendingAttempt: AutoRestoreAttemptState.PendingAttempt?,
        document: SlotStoreDocument,
        currentTopology: DisplayTopologyFingerprint,
        generation: Int,
        triggerStartedAt: Date,
        trigger: EnvironmentChangeReason
    ) {
        switch decision {
        case let .doNothing(reason):
            AppLog.display.debug(
                "Automatic restore did nothing: \(reason, privacy: .public)"
            )
            recordDecision(
                menuKey: localizationKey(forNoActionReason: reason),
                diagnosticCode: "do-nothing:\(reason)",
                trigger: trigger
            )

        case let .prompt(layoutID, layoutName):
            guard let pendingAttempt else { return }
            let shortcut = menuBarController.registeredRestoreShortcutDescription(
                for: layoutID,
                in: document
            )
            showRestorePrompt(
                attemptID: pendingAttempt.id,
                layoutID: layoutID,
                layoutName: layoutName,
                shortcutDescription: shortcut,
                expectedTopology: currentTopology,
                generation: generation,
                trigger: trigger
            )

        case let .restore(layoutID, layoutName):
            guard let pendingAttempt else { return }
            let shortcut = menuBarController.registeredRestoreShortcutDescription(
                for: layoutID,
                in: document
            )
            recordDecision(
                menuKey: .autoRestoreDecisionRestoreFormat,
                menuArgument: layoutName,
                diagnosticCode: "restore:\(layoutID)",
                trigger: trigger
            )
            launchRestoreTask(
                attemptID: pendingAttempt.id,
                layoutID: layoutID,
                preflight: { @MainActor [weak self] in
                    self?.automaticRestorePreflight(
                        attemptID: pendingAttempt.id,
                        layoutID: layoutID,
                        layoutName: layoutName,
                        shortcutDescription: shortcut,
                        expectedTopology: currentTopology,
                        generation: generation,
                        triggerStartedAt: triggerStartedAt,
                        trigger: trigger
                    ) ?? false
                }
            )
        }
    }

    private func launchRestoreTask(
        attemptID: Int,
        layoutID: String,
        preflight: @escaping RestorePreflight
    ) {
        guard !automaticRestoreHasCommitted else { return }

        automaticRestoreTask?.cancel()
        automaticRestoreHasCommitted = false
        automaticRestoreAttemptID = attemptID
        let taskToken = restoreTaskTokens.begin()
        let restoreTask = menuBarController.restoreLayout(
            id: layoutID,
            preflight: preflight
        )
        automaticRestoreTask = restoreTask

        Task { @MainActor [weak self] in
            await restoreTask.value
            self?.automaticRestoreFinished(
                attemptID: attemptID,
                taskToken: taskToken
            )
        }
    }

    private func automaticRestoreFinished(attemptID: Int, taskToken: Int) {
        guard automaticRestoreAttemptID == attemptID,
              restoreTaskTokens.finish(taskToken)
        else {
            return
        }

        automaticRestoreTask = nil
        automaticRestoreAttemptID = nil
        if automaticRestoreHasCommitted {
            automaticRestoreHasCommitted = false
            return
        }

        // A rejected exclusive-operation/preflight leaves no visible prompt.
        // Roll it back so a future environment event can offer the same final
        // topology. A downgrade-to-prompt remains pending and is not touched.
        if attemptState.isPending(attemptID, kind: .automatic) {
            _ = attemptState.invalidatePending(attemptID)
        }
    }

    private func refreshSettings() async {
        do {
            let document = try await slotEngine.currentDocument()
            settleTimeout = document.settings.autoRestoreSettleTimeout
        } catch {
            AppLog.display.error(
                "Failed to refresh automatic restore settings: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func recordDecision(
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

    private func localizationKey(forNoActionReason reason: String) -> LocalizationKey {
        switch reason {
        case "disabled": .autoRestoreDecisionDisabled
        case "topology unchanged": .autoRestoreDecisionTopologyUnchanged
        case "already offered": .autoRestoreDecisionAlreadyOffered
        case "no layout for this arrangement": .autoRestoreDecisionNoLayout
        case "layout is empty": .autoRestoreDecisionEmptyLayout
        default: .autoRestoreDecisionError
        }
    }

    private func confirmPrompt(
        attemptID: Int,
        layoutID: String,
        expectedTopology: DisplayTopologyFingerprint,
        generation: Int,
        trigger: EnvironmentChangeReason
    ) {
        guard attemptState.transitionToAutomatic(attemptID) else { return }
        guard confirmationPreflight(
            expectedTopology: expectedTopology,
            generation: generation,
            trigger: trigger
        ) else {
            _ = attemptState.complete(attemptID)
            return
        }

        launchRestoreTask(
            attemptID: attemptID,
            layoutID: layoutID,
            preflight: { @MainActor [weak self] in
                guard let self,
                      self.attemptState.isPending(attemptID, kind: .automatic),
                      self.confirmationPreflight(
                        expectedTopology: expectedTopology,
                        generation: generation,
                        trigger: trigger
                      ),
                      self.attemptState.commit(attemptID)
                else {
                    return false
                }

                self.automaticRestoreHasCommitted = true
                return true
            }
        )
    }

    private func confirmationPreflight(
        expectedTopology: DisplayTopologyFingerprint,
        generation: Int,
        trigger: EnvironmentChangeReason
    ) -> Bool {
        guard isStarted,
              isSessionVisible,
              generation == triggerGeneration
        else {
            return false
        }

        guard currentTopology()?.matchesIdentity(of: expectedTopology) == true else {
            recordDecision(
                menuKey: .autoRestoreDecisionNoLayout,
                diagnosticCode: "do-nothing:topology-changed-before-confirmation",
                trigger: trigger
            )
            return false
        }

        return true
    }

    private func automaticRestorePreflight(
        attemptID: Int,
        layoutID: String,
        layoutName: String,
        shortcutDescription: String?,
        expectedTopology: DisplayTopologyFingerprint,
        generation: Int,
        triggerStartedAt: Date,
        trigger: EnvironmentChangeReason
    ) -> Bool {
        guard attemptState.isPending(attemptID, kind: .automatic),
              confirmationPreflight(
                expectedTopology: expectedTopology,
                generation: generation,
                trigger: trigger
              )
        else {
            return false
        }

        guard !userInteractedSinceTrigger(startedAt: triggerStartedAt) else {
            guard attemptState.downgradeToPrompt(attemptID) else { return false }
            showRestorePrompt(
                attemptID: attemptID,
                layoutID: layoutID,
                layoutName: layoutName,
                shortcutDescription: shortcutDescription,
                expectedTopology: expectedTopology,
                generation: generation,
                trigger: trigger
            )
            return false
        }

        guard attemptState.commit(attemptID) else { return false }
        automaticRestoreHasCommitted = true
        return true
    }

    private func showRestorePrompt(
        attemptID: Int,
        layoutID: String,
        layoutName: String,
        shortcutDescription: String?,
        expectedTopology: DisplayTopologyFingerprint,
        generation: Int,
        trigger: EnvironmentChangeReason
    ) {
        guard attemptState.isPending(attemptID, kind: .prompt) else { return }

        recordDecision(
            menuKey: .autoRestoreDecisionPromptFormat,
            menuArgument: layoutName,
            diagnosticCode: "prompt:\(layoutID)",
            trigger: trigger
        )
        RestorePromptWindow.show(
            layoutName: layoutName,
            shortcutDescription: shortcutDescription,
            duration: 12,
            onConfirm: { [weak self] in
                self?.confirmPrompt(
                    attemptID: attemptID,
                    layoutID: layoutID,
                    expectedTopology: expectedTopology,
                    generation: generation,
                    trigger: trigger
                )
            },
            onDismiss: { [weak self] in
                _ = self?.attemptState.complete(attemptID)
                AppLog.display.debug(
                    "Automatic restore prompt dismissed for layout \(layoutID, privacy: .public)"
                )
            },
            onSupersededByRestore: { [weak self] in
                _ = self?.attemptState.complete(attemptID)
                AppLog.display.debug(
                    "Automatic restore prompt confirmed by an existing restore action for layout \(layoutID, privacy: .public)"
                )
            }
        )
    }

    private func currentTopology() -> DisplayTopologyFingerprint? {
        DisplayManager.currentTopologyFingerprint()
    }

    private func userInteractedSinceTrigger(startedAt: Date) -> Bool {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]

        // Keep the explicit three-second safety threshold from the brief, but
        // also cover the entire settle interval so input immediately after a
        // trigger cannot age out before a slow dock becomes stable.
        let elapsedSinceTrigger = max(Date().timeIntervalSince(startedAt), 0)
        let interactionWindow = max(
            Self.recentInteractionThreshold,
            elapsedSinceTrigger
        )

        return eventTypes.contains { eventType in
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: eventType
            ) <= interactionWindow
        }
    }
}
