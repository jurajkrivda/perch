import Foundation

extension SettingsModel {
    var automaticLayout: Slot? {
        guard let currentTopology else { return nil }
        return AutoRestorePolicy.selectedLayout(
            slots: document.slots, topology: currentTopology,
            preferences: document.settings.preferredLayoutsByTopology
        )
    }

    var currentPreferredLayoutID: String {
        guard let currentTopology else { return "" }
        guard let id = document.settings.preferredLayoutsByTopology[currentTopology.identity],
              document.slots.contains(where: {
                  $0.id == id && !$0.windows.isEmpty && $0.capturedTopology?.matchesIdentity(of: currentTopology) == true
              }) else { return "" }
        return id
    }

    func setPreferredLayout(_ layoutID: String?, topology: DisplayTopologyFingerprint? = nil) {
        guard let slotEngine, let topology = topology ?? currentTopology else { return }
        enqueueDocumentMutation(operation: {
            try await slotEngine.setPreferredLayout(layoutID, for: topology)
        }, completion: { _ in })
    }

    func saveCurrentWindows(to layout: Slot) {
        guard let slotEngine, changingLayoutID == nil else { return }
        changingLayoutID = layout.id
        enqueueDocumentMutation(operation: {
            _ = try await slotEngine.save(slotID: layout.id)
        }, completion: { [weak self] _ in self?.changingLayoutID = nil })
    }

    func restoreLayout(_ layout: Slot) {
        guard let slotEngine else { return }
        RestorePromptWindow.dismissCurrentForRestore()
        RestoreReportWindowController.shared.show(engine: slotEngine)
        Task { @MainActor in
            do { _ = try await slotEngine.restore(slotID: layout.id) }
            catch is CancellationError { }
            catch { errorMessage = LocalizedErrorMessages.message(for: error) }
        }
    }
}
