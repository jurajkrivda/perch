import Foundation

/// Prompt presentation and commit handling for the coordinator.
extension AutoRestoreCoordinator {
    func apply(
        _ decision: AutoRestoreDecision,
        pendingAttempt: AutoRestoreAttemptState.PendingAttempt?,
        document: SlotStoreDocument,
        currentTopology: DisplayTopologyFingerprint,
        generation: Int,
        trigger: EnvironmentChangeReason
    ) -> Bool {
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
            return true

        case let .prompt(layoutID, layoutName):
            guard let pendingAttempt else { return true }
            let shortcut = menuBarController.registeredRestoreShortcutDescription(
                for: layoutID,
                in: document
            )
            return showRestorePrompt(
                attemptID: pendingAttempt.id,
                layoutID: layoutID,
                layoutName: layoutName,
                shortcutDescription: shortcut,
                expectedTopology: currentTopology,
                generation: generation,
                trigger: trigger
            )

        case let .restore(layoutID, layoutName):
            guard let pendingAttempt else { return true }
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
                preflight: { @MainActor [weak self] document in
                    self?.automaticRestorePreflight(
                        document: document,
                        attemptID: pendingAttempt.id,
                        layoutID: layoutID,
                        layoutName: layoutName,
                        shortcutDescription: shortcut,
                        expectedTopology: currentTopology,
                        generation: generation,
                        trigger: trigger
                    ) ?? false
                }
            )
            return true
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
            let generation = attemptState.pendingAttempt?.generation
            if attemptState.invalidatePending(attemptID), let generation {
                decisionContextState.finish(generation: generation)
            }
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
            decisionContextState.finish(generation: generation)
            return
        }

        launchRestoreTask(
            attemptID: attemptID,
            layoutID: layoutID,
            preflight: { @MainActor [weak self] document in
                guard let self,
                      document.settings.autoRestoreMode != .off,
                      document.slots.contains(where: {
                          $0.id == layoutID && !$0.windows.isEmpty &&
                              $0.capturedTopology?.matchesIdentity(of: expectedTopology) == true
                      }),
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

                self.decisionContextState.finish(generation: generation)
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
        document: SlotStoreDocument,
        attemptID: Int,
        layoutID: String,
        layoutName: String,
        shortcutDescription: String?,
        expectedTopology: DisplayTopologyFingerprint,
        generation: Int,
        trigger: EnvironmentChangeReason
    ) -> Bool {
        guard document.settings.autoRestoreMode != .off,
              document.slots.contains(where: {
                  $0.id == layoutID && !$0.windows.isEmpty &&
                      $0.capturedTopology?.matchesIdentity(of: expectedTopology) == true
              }),
              attemptState.isPending(attemptID, kind: .automatic),
              confirmationPreflight(
                expectedTopology: expectedTopology,
                generation: generation,
                trigger: trigger
              )
        else {
            return false
        }

        guard document.settings.autoRestoreMode == .automatic else {
            guard attemptState.downgradeToPrompt(attemptID) else { return false }
            _ = showRestorePrompt(
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
        decisionContextState.finish(generation: generation)
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
    ) -> Bool {
        guard attemptState.isPending(attemptID, kind: .prompt) else { return true }

        let didPresent = menuBarController.showRestorePrompt(AutoRestorePrompt(
            layoutName: layoutName,
            shortcutDescription: shortcutDescription,
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
                guard let self else { return }
                if self.attemptState.complete(attemptID) {
                    self.decisionContextState.finish(generation: generation)
                }
                AppLog.display.debug(
                    "Automatic restore prompt dismissed for layout \(layoutID, privacy: .public)"
                )
            },
            onSupersededByRestore: { [weak self] in
                guard let self else { return }
                if self.attemptState.complete(attemptID) {
                    self.decisionContextState.finish(generation: generation)
                }
                AppLog.display.debug(
                    "Automatic restore prompt confirmed by an existing restore action for layout \(layoutID, privacy: .public)"
                )
            }
        ))

        guard didPresent else {
            _ = attemptState.invalidatePending(attemptID)
            AppLog.display.warning(
                "Automatic restore prompt deferred because no visible screen is available"
            )
            handleIncompleteTopology(
                reason: trigger,
                generation: generation
            )
            return false
        }

        recordDecision(
            menuKey: .autoRestoreDecisionPromptFormat,
            menuArgument: layoutName,
            diagnosticCode: "prompt:\(layoutID)",
            trigger: trigger
        )
        return true
    }

}
