import AppKit

extension MenuBarController {
    func addLastRestoreReport(to menu: NSMenu) {
        guard let session = slotEngine?.restoreSession,
              session.result != nil || session.isRunning else { return }
        let item = NSMenuItem(title: L10n.text(.restoreActivity), action: #selector(showRestoreReport), keyEquivalent: "")
        item.target = self
        item.image = menuIcon("list.bullet.rectangle")
        menu.addItem(item)
        if session.isRunning {
            let stop = NSMenuItem(title: L10n.text(.stopRestore), action: #selector(stopRestore), keyEquivalent: "")
            stop.target = self
            stop.image = menuIcon("stop.circle")
            stop.isEnabled = !session.isCancelling
            menu.addItem(stop)
        } else if session.canUndo {
            let undo = NSMenuItem(title: L10n.text(.undoLastRestore), action: #selector(undoRestore), keyEquivalent: "")
            undo.target = self
            undo.image = menuIcon("arrow.uturn.backward")
            menu.addItem(undo)
        }
    }

    @objc func showRestoreReport() {
        guard let slotEngine else { return }
        RestoreReportWindowController.shared.show(engine: slotEngine)
    }

    @objc private func stopRestore() { slotEngine?.cancelRestore() }

    @objc private func undoRestore() {
        guard let slotEngine else { return }
        showRestoreReport()
        Task { @MainActor in
            await performLayoutOperation(kind: .restore) { try await slotEngine.undoLastRestore() }
        }
    }

    func addLastAutomaticDecision(to menu: NSMenu) {
        guard let lastAutomaticDecision else { return }

        let summary = if let argument = lastAutomaticDecision.argument {
            L10n.format(lastAutomaticDecision.key, argument)
        } else {
            L10n.text(lastAutomaticDecision.key)
        }
        let title = L10n.format(.lastAutomaticDecisionFormat, summary)
        let item = NSMenuItem(
            title: truncatedMenuText(title, limit: 46),
            action: nil,
            keyEquivalent: ""
        )
        item.toolTip = title
        item.image = menuIcon("display.2")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func truncatedMenuText(_ text: String, limit: Int = 46) -> String {
        text.count > limit ? "\(text.prefix(max(limit - 1, 0)))…" : text
    }
}
