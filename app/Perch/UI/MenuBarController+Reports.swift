import AppKit

extension MenuBarController {
    func addLastRestoreReport(to menu: NSMenu) {
        guard let lastRestoreResult else {
            return
        }

        let reportItem = NSMenuItem(title: L10n.text(.lastRestoreReport), action: nil, keyEquivalent: "")
        reportItem.image = menuIcon("list.bullet.rectangle")

        let submenu = NSMenu()

        let summaryItem = NSMenuItem(
            title: truncatedMenuText(lastRestoreResult.restoreSummary),
            action: nil,
            keyEquivalent: ""
        )
        summaryItem.toolTip = lastRestoreResult.restoreSummary
        summaryItem.isEnabled = false
        submenu.addItem(summaryItem)

        let reportRows = lastRestoreResult.details.filter { !$0.isSuccess || $0.didLaunchApplication || $0.matchReason != nil }
        if reportRows.isEmpty {
            let allRestoredItem = NSMenuItem(title: L10n.text(.allWindowsRestored), action: nil, keyEquivalent: "")
            allRestoredItem.image = menuIcon("checkmark.circle")
            allRestoredItem.isEnabled = false
            submenu.addItem(allRestoredItem)
        } else {
            submenu.addItem(.separator())
            for report in reportRows {
                let item = NSMenuItem(
                    title: truncatedMenuText(menuTitle(for: report)),
                    action: nil,
                    keyEquivalent: ""
                )
                item.toolTip = menuTooltip(for: report)
                item.image = menuIcon(menuIconName(for: report.outcome))
                item.isEnabled = false
                submenu.addItem(item)
            }
        }

        reportItem.submenu = submenu
        menu.addItem(reportItem)
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

    private func menuTitle(for report: RestoreWindowReport) -> String {
        let outcomeKey: LocalizationKey = switch report.outcome {
        case .restored: .menuOutcomeRestored
        case .launchedAndRestored: .menuOutcomeOpenedAndRestored
        case .appNotInstalled: .menuOutcomeNotInstalled
        case .launchFailed: .menuOutcomeLaunchFailed
        case .appNotRunning: .menuOutcomeClosed
        case .windowNotFound: .menuOutcomeWindowNotFound
        case .ambiguousWindowMatch: .menuOutcomeAmbiguousWindows
        case .frameWriteFailed: .menuOutcomeMoveFailed
        case .skipped: .menuOutcomeSkipped
        }

        return "\(report.appName): \(L10n.text(outcomeKey))"
    }

    private func menuTooltip(for report: RestoreWindowReport) -> String {
        var lines = [
            "\(L10n.text(.appLabel)): \(report.appName)",
            "\(L10n.text(.bundleIDLabel)): \(report.bundleIdentifier)",
            "\(L10n.text(.windowLabel)): \(report.windowTitle)"
        ]

        if report.didLaunchApplication {
            lines.append(L10n.text(.openedDuringRestore))
        }

        if let matchReason = report.matchReason {
            lines.append("\(L10n.text(.matchedByLabel)): \(matchReason.userDescription)")
        }

        if let message = report.message, !message.isEmpty {
            lines.append("\(L10n.text(.reasonLabel)): \(message)")
        }

        return lines.joined(separator: "\n")
    }

    private func menuIconName(for outcome: RestoreWindowOutcome) -> String {
        switch outcome {
        case .restored:
            "checkmark.circle"
        case .launchedAndRestored:
            "arrow.up.forward.app"
        case .appNotInstalled:
            "questionmark.app"
        case .launchFailed:
            "exclamationmark.triangle"
        case .appNotRunning:
            "app"
        case .windowNotFound:
            "rectangle.dashed"
        case .ambiguousWindowMatch:
            "questionmark.square.dashed"
        case .frameWriteFailed:
            "rectangle.badge.exclamationmark"
        case .skipped:
            "minus.circle"
        }
    }

    private func truncatedMenuText(_ text: String, limit: Int = 30) -> String {
        guard text.count > limit else {
            return text
        }

        return "\(text.prefix(max(limit - 1, 0)))…"
    }

}
