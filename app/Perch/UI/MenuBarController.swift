import AppKit
import Carbon

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let slotEngine: SlotEngine?
    private var menu: NSMenu?
    private var slots = Slot.defaultSlots
    private var settings = PerchSettings()
    private var lastRestoreResult: SlotOperationResult?
    private var lastAutomaticDecision: (key: LocalizationKey, argument: String?)?
    private var hotkeyRegistrationState = HotkeyRegistrationState()
    private var languageChangeObserver: NSObjectProtocol?

    private struct StatusItemPresentation {
        var title = "Perch"
        var symbolName = "rectangle.3.group"
    }
    private var statusItemPresentation = StatusItemPresentation()

    private enum LayoutOperationKind {
        case save
        case restore
    }

    init(slotEngine: SlotEngine?) {
        self.slotEngine = slotEngine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        rebuildMenu()
        reloadSlots()

        // The controller lives for the whole app lifetime, so the observer is
        // never removed.
        languageChangeObserver = NotificationCenter.default.addObserver(
            forName: .perchLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
            }
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            AppLog.menu.error("Unable to configure menu bar button")
            return
        }

        button.image = NSImage(
            systemSymbolName: statusItemPresentation.symbolName,
            accessibilityDescription: "Perch"
        )
        button.image?.isTemplate = true
        button.appearance = nil
        button.title = settings.showsMenuBarLabel ? " \(statusItemPresentation.title)" : ""
        button.target = self
        button.action = #selector(showMenu)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        addAccessibilityWarning(to: menu)
        addHotkeyRegistrationWarning(to: menu)
        addLayoutItems(to: menu)
        if lastRestoreResult != nil || lastAutomaticDecision != nil {
            menu.addItem(.separator())
        }
        addLastRestoreReport(to: menu)
        addLastAutomaticDecision(to: menu)

        menu.addItem(.separator())

        let createItem = NSMenuItem(
            title: "\(L10n.text(.createLayout))…",
            action: #selector(createLayout),
            keyEquivalent: ""
        )
        createItem.target = self
        createItem.image = menuIcon("plus")
        createItem.isEnabled = slotEngine != nil
        menu.addItem(createItem)

        let updateItem = NSMenuItem(
            title: L10n.text(.checkForUpdatesMenuItem),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.image = menuIcon("arrow.down.circle")
        updateItem.isEnabled = UpdaterController.shared.canCheckForUpdates
        menu.addItem(updateItem)

        let settingsItem = NSMenuItem(
            title: L10n.text(.settingsMenuItem),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.image = menuIcon("gearshape")
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.text(.quitPerch),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
    }

    private func addLayoutItems(to menu: NSMenu) {
        menu.addItem(.sectionHeader(title: L10n.text(.layoutsSectionTitle)))

        guard !slots.isEmpty else {
            let emptyItem = NSMenuItem(title: L10n.text(.noLayoutsYet), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        let canUseEngine = slotEngine != nil
        let canSave = canUseEngine && AccessibilityManager.isTrusted()
        let document = SlotStoreDocument(slots: slots, settings: settings)

        for index in slots.indices {
            let slot = slots[index]
            let hasWindows = !slot.windows.isEmpty
            let restoreHotkey = document.effectiveRestoreHotkey(at: index)
            let saveHotkey = document.effectiveSaveHotkey(at: index)
            let restoreKeyEquivalent = menuKeyEquivalentIfAvailable(for: restoreHotkey)
            let saveKeyEquivalent = menuKeyEquivalentIfAvailable(for: saveHotkey)

            if hasWindows {
                let restoreItem = NSMenuItem(
                    title: slot.name,
                    action: #selector(restoreLayout(_:)),
                    keyEquivalent: restoreKeyEquivalent
                )
                restoreItem.keyEquivalentModifierMask = restoreHotkey.map(menuModifierFlags(for:)) ?? []
                restoreItem.target = self
                restoreItem.representedObject = slot.id
                restoreItem.image = menuIcon("rectangle.on.rectangle")
                restoreItem.isEnabled = canUseEngine
                if let restoreHotkey, isHotkeyUnavailable(restoreHotkey) {
                    restoreItem.toolTip = unavailableHotkeyTooltip(for: restoreHotkey)
                }
                menu.addItem(restoreItem)
            } else {
                let emptyItem = NSMenuItem(title: slot.name, action: nil, keyEquivalent: "")
                emptyItem.image = menuIcon("rectangle.badge.plus")
                emptyItem.isEnabled = false
                emptyItem.toolTip = L10n.text(.noWindowsSavedYet)
                menu.addItem(emptyItem)
            }

            let saveTitle = hasWindows
                ? L10n.format(.updateLayoutWindowsFormat, slot.name)
                : L10n.format(.saveCurrentWindowsFormat, slot.name)
            let saveItem = NSMenuItem(
                title: saveTitle,
                action: #selector(saveLayout(_:)),
                keyEquivalent: saveKeyEquivalent
            )
            // For layout index >= 9 there is no default save hotkey, so key/mask fall back to empty.
            saveItem.keyEquivalentModifierMask = saveHotkey.map(menuModifierFlags(for:)) ?? []
            saveItem.target = self
            saveItem.representedObject = slot.id
            saveItem.image = menuIcon(hasWindows ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
            saveItem.isEnabled = canSave
            saveItem.indentationLevel = 1
            if let saveHotkey, isHotkeyUnavailable(saveHotkey) {
                saveItem.toolTip = unavailableHotkeyTooltip(for: saveHotkey)
            }
            menu.addItem(saveItem)
        }
    }

    private func addHotkeyRegistrationWarning(to menu: NSMenu) {
        let hotkeyRegistrationFailures = hotkeyRegistrationState.failures
        guard !hotkeyRegistrationFailures.isEmpty else {
            return
        }

        let warningItem = NSMenuItem(title: L10n.text(.someShortcutsUnavailable), action: nil, keyEquivalent: "")
        warningItem.image = menuIcon("exclamationmark.triangle.fill")

        let submenu = NSMenu()

        for failure in hotkeyRegistrationFailures {
            let item = NSMenuItem(
                title: "\(failure.displayString): \(failure.description)",
                action: nil,
                keyEquivalent: ""
            )
            item.toolTip = L10n.format(.shortcutRejectedTooltipFormat, failure.status)
            item.isEnabled = false
            submenu.addItem(item)
        }

        warningItem.submenu = submenu
        menu.addItem(warningItem)
        menu.addItem(.separator())
    }

    private func addAccessibilityWarning(to menu: NSMenu) {
        let permissionState = AccessibilityManager.permissionState()
        guard permissionState != .trusted else { return }

        let requestItem = NSMenuItem(
            title: accessibilityMenuTitle(for: permissionState),
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        )
        requestItem.target = self
        requestItem.image = menuIcon("exclamationmark.triangle.fill")
        menu.addItem(requestItem)

        if permissionState == .pending {
            let restartItem = NSMenuItem(
                title: L10n.text(.restartPerch),
                action: #selector(restartPerch),
                keyEquivalent: ""
            )
            restartItem.target = self
            restartItem.image = menuIcon("arrow.clockwise")
            menu.addItem(restartItem)

            let resetItem = NSMenuItem(
                title: L10n.text(.resetAccessibilityPermission),
                action: #selector(resetAccessibilityPermission),
                keyEquivalent: ""
            )
            resetItem.target = self
            resetItem.image = menuIcon("arrow.counterclockwise")
            menu.addItem(resetItem)
        }

        menu.addItem(.separator())
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    private func addLastRestoreReport(to menu: NSMenu) {
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

    private func addLastAutomaticDecision(to menu: NSMenu) {
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

    @objc private func restartPerch() {
        do {
            try AccessibilityManager.relaunchCurrentApp()
        } catch {
            AppLog.app.error("Failed to relaunch Perch: \(error.localizedDescription, privacy: .public)")
            ToastWindow.show(LocalizedErrorMessages.message(for: error))
        }
    }

    @objc private func requestAccessibilityPermission() {
        Task { @MainActor in
            let isTrusted = await AccessibilityManager.requestPermissionAndWait()
            AppLog.menu.info("Accessibility permission request finished; trusted=\(isTrusted)")
            if isTrusted {
                ToastWindow.show(L10n.text(.accessibilityGranted))
            }
            rebuildMenu()
        }
    }

    @objc private func resetAccessibilityPermission() {
        Task { @MainActor in
            do {
                try await AccessibilityManager.resetPermissionForCurrentApp()
                rebuildMenu()
                let isTrusted = await AccessibilityManager.requestPermissionAndWait()
                rebuildMenu()
                ToastWindow.show(
                    isTrusted
                    ? L10n.text(.accessibilityGranted)
                    : L10n.text(.accessibilityPermissionResetEnable)
                )
            } catch {
                AppLog.menu.error("Accessibility permission reset failed: \(error.localizedDescription, privacy: .public)")
                ToastWindow.show(LocalizedErrorMessages.message(for: error))
            }
        }
    }

    @objc private func saveLayout(_ sender: NSMenuItem) {
        guard let slotID = sender.representedObject as? String else {
            AppLog.menu.error("Save layout menu item missing layout ID")
            return
        }

        saveLayout(id: slotID)
    }

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let slotID = sender.representedObject as? String else {
            AppLog.menu.error("Restore layout menu item missing layout ID")
            return
        }

        restoreLayout(id: slotID)
    }

    @objc private func createLayout() {
        guard let slotEngine,
              let name = promptForLayoutName(
                  title: L10n.text(.createLayout),
                  defaultName: L10n.text(.newLayoutDefaultName)
              )
        else {
            return
        }

        Task { @MainActor in
            do {
                let layout = try await slotEngine.createLayout(name: name)
                ToastWindow.show(L10n.format(.createdLayoutFormat, layout.name))
                reloadSlots()
            } catch {
                ToastWindow.show(LocalizedErrorMessages.message(for: error))
            }
        }
    }

    func saveSlot(index slotIndex: Int) {
        Task { @MainActor in
            await performLayoutOperation(kind: .save) {
                try await self.slotEngine?.save(slotIndex: slotIndex)
            }
        }
    }

    private func saveLayout(id slotID: String) {
        Task { @MainActor in
            await performLayoutOperation(kind: .save) {
                try await self.slotEngine?.save(slotID: slotID)
            }
        }
    }

    @discardableResult
    func restoreLayout(
        id slotID: String,
        preflight: RestorePreflight? = nil
    ) -> Task<Void, Never> {
        // A global restore shortcut is also a confirmation of an open restore
        // suggestion, so no separate hotkey path is needed.
        RestorePromptWindow.dismissCurrentForRestore()
        return Task { @MainActor in
            guard !Task.isCancelled else { return }
            await performLayoutOperation(kind: .restore) {
                try await self.slotEngine?.restore(
                    slotID: slotID,
                    preflight: preflight
                )
            }
        }
    }

    @objc private func showMenu() {
        guard let button = statusItem.button else {
            AppLog.menu.error("Unable to show menu because status item button is missing")
            return
        }

        AppLog.menu.info("Showing status menu")
        rebuildMenu()

        statusItem.menu = menu
        defer { statusItem.menu = nil }
        button.performClick(nil)
    }

    @objc func openSettings() {
        AppLog.menu.info("Opening settings")
        SettingsWindowController.shared.show()
    }

    func refresh() {
        lastRestoreResult = nil
        reloadSlots()
    }

    func updateHotkeyRegistrationState(_ state: HotkeyRegistrationState) {
        hotkeyRegistrationState = state
        rebuildMenu()
    }

    /// Returns a hint only when the configured restore shortcut has an active
    /// Carbon registration. Automatic restore prompts use this instead of
    /// displaying a shortcut that the system rejected.
    func registeredRestoreShortcutDescription(
        for layoutID: String,
        in document: SlotStoreDocument
    ) -> String? {
        hotkeyRegistrationState.registeredRestoreDisplayString(
            for: layoutID,
            configuredBinding: document.effectiveRestoreHotkey(for: layoutID)
        )
    }

    func updateLastAutomaticDecision(key: LocalizationKey, argument: String? = nil) {
        lastAutomaticDecision = (key, argument)
        rebuildMenu()
    }

    @objc private func quit() {
        AppLog.menu.info("Quit selected")
        NSApp.terminate(nil)
    }

    private func reloadSlots() {
        guard let slotEngine else {
            slots = Slot.defaultSlots
            rebuildMenu()
            return
        }

        Task { @MainActor in
            do {
                let document = try await slotEngine.currentDocument()
                slots = document.slots
                settings = document.settings
                configureStatusItem()
            } catch {
                AppLog.persistence.error("Failed to reload slots: \(error.localizedDescription, privacy: .public)")
                slots = Slot.defaultSlots
            }

            rebuildMenu()
        }
    }

    private func performLayoutOperation(
        kind: LayoutOperationKind,
        _ operation: @escaping @MainActor () async throws -> SlotOperationResult?
    ) async {
        do {
            guard let result = try await operation() else {
                AppLog.menu.error("Layout operation unavailable because SlotEngine is missing")
                return
            }

            AppLog.menu.info("Layout operation finished for \(result.slotName, privacy: .private): \(result.succeeded)/\(result.total)")
            switch kind {
            case .save:
                lastRestoreResult = nil
            case .restore:
                lastRestoreResult = result
            }
            showToast(for: result, kind: kind)
            reloadSlots()
        } catch SlotEngineError.operationInProgress {
            AppLog.menu.info("Ignored layout operation because another one is still running")
        } catch SlotEngineError.restorePreflightRejected {
            AppLog.menu.info("Cancelled automatic restore because its preflight was rejected")
        } catch is CancellationError {
            AppLog.menu.info("Layout operation cancelled; some windows may already have moved")
        } catch {
            // The description can carry user content (saved window titles), so it stays private.
            AppLog.menu.error("Layout operation failed: \(error.localizedDescription, privacy: .private)")
            if isAccessibilityPermissionError(error) {
                await handleAccessibilityPermissionFailure()
            } else {
                ToastWindow.show(LocalizedErrorMessages.message(for: error))
            }
        }
    }

    private func handleAccessibilityPermissionFailure() async {
        switch AccessibilityManager.permissionState() {
        case .trusted:
            rebuildMenu()
            ToastWindow.show(L10n.text(.accessibilityGranted))
        case .pending:
            AccessibilityManager.logStatus(reason: "operation failed while pending")
            rebuildMenu()
            ToastWindow.show(L10n.text(.accessibilityPermissionPending))
        case .notRequested:
            let isTrusted = await AccessibilityManager.requestPermissionAndWait()
            rebuildMenu()
            ToastWindow.show(
                isTrusted
                ? L10n.text(.accessibilityGranted)
                : L10n.text(.accessibilityBannerRequiredMessage)
            )
        }
    }

    private func accessibilityMenuTitle(for permissionState: AccessibilityManager.PermissionState) -> String {
        switch permissionState {
        case .trusted:
            return ""
        case .notRequested:
            return L10n.text(.grantAccessibilityPermission)
        case .pending:
            return L10n.text(.grantAccessibilityPermissionPending)
        }
    }

    private func showToast(for result: SlotOperationResult, kind: LayoutOperationKind) {
        switch kind {
        case .save:
            ToastWindow.showSavedWindowCount(result.succeeded)
        case .restore:
            ToastWindow.show(result.restoreSummary, symbolName: restoreToastSymbol(for: result))
        }
    }

    private func restoreToastSymbol(for result: SlotOperationResult) -> String {
        result.skipped == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
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

    private func isAccessibilityPermissionError(_ error: Error) -> Bool {
        switch error {
        case WindowSnapshotterError.accessibilityPermissionMissing,
             WindowMoverError.accessibilityPermissionMissing:
            true
        default:
            false
        }
    }

    private func promptForLayoutName(title: String, defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = L10n.text(.chooseLayoutName)
        alert.addButton(withTitle: L10n.text(.saveButton))
        alert.addButton(withTitle: L10n.text(.cancelButton))

        let textField = NSTextField(string: defaultName)
        textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }

        let trimmedName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    private func menuIcon(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func menuKeyEquivalent(for hotkey: HotkeyBinding) -> String {
        switch Int(hotkey.keyCode) {
        case kVK_Space:
            return " "
        default:
            let displayName = HotkeyBinding.keyDisplayName(for: hotkey.keyCode)
            return displayName.count == 1 ? displayName.lowercased() : ""
        }
    }

    private func menuKeyEquivalentIfAvailable(for hotkey: HotkeyBinding?) -> String {
        guard let hotkey, !isHotkeyUnavailable(hotkey) else {
            return ""
        }

        return menuKeyEquivalent(for: hotkey)
    }

    private func menuModifierFlags(for hotkey: HotkeyBinding) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []

        if hotkey.modifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
        }
        if hotkey.modifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
        }
        if hotkey.modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
        }
        if hotkey.modifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
        }

        return flags
    }

    private func isHotkeyUnavailable(_ hotkey: HotkeyBinding) -> Bool {
        !hotkeyRegistrationState.isRegistered(hotkey)
    }

    private func unavailableHotkeyTooltip(for hotkey: HotkeyBinding) -> String {
        L10n.format(.shortcutUnavailableTooltipFormat, hotkey.displayString)
    }
}

extension MenuBarController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return UpdaterController.shared.canCheckForUpdates
        }
        // Preserve the enabled state the menu builder set; other items keep
        // their existing manual gating.
        return menuItem.isEnabled
    }
}
