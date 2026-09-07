import AppKit
import Carbon

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    let slotEngine: SlotEngine?
    private var menu: NSMenu?
    var slots = Slot.defaultSlots
    var settings = PerchSettings()
    var recoveryNotice: StoreRecoveryNotice?
    var lastRestoreResult: SlotOperationResult? { slotEngine?.restoreSession.result }
    var lastAutomaticDecision: (key: LocalizationKey, argument: String?)?
    var hotkeyRegistrationState = HotkeyRegistrationState()
    private var languageChangeObserver: NSObjectProtocol?
    private var restoreChangeObserver: NSObjectProtocol?

    private struct StatusItemPresentation {
        var title = "Perch"
        var symbolName = "rectangle.3.group"
    }
    private var statusItemPresentation = StatusItemPresentation()

    enum LayoutOperationKind {
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
        restoreChangeObserver = NotificationCenter.default.addObserver(
            forName: .perchRestoreDidChange, object: slotEngine?.restoreSession, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configureStatusItem()
                self?.rebuildMenu()
            }
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            AppLog.menu.error("Unable to configure menu bar button")
            return
        }

        let session = slotEngine?.restoreSession
        let running = session?.isRunning == true
        button.image = NSImage(
            systemSymbolName: running ? "arrow.triangle.2.circlepath" : statusItemPresentation.symbolName,
            accessibilityDescription: "Perch"
        )
        button.image?.isTemplate = true
        button.appearance = nil
        button.title = settings.showsMenuBarLabel ? " \(statusItemPresentation.title)" : ""
        if running, let session, !session.isStabilizing {
            button.title = " \(session.completedCount)/\(session.result?.total ?? 0)"
        }
        button.toolTip = running ? L10n.text(.restoreActivity) : "Perch"
        button.target = self
        button.action = #selector(showMenu)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func rebuildMenu() {
        let menu = NSMenu()

        addAccessibilityWarning(to: menu)
        addStoreRecoveryWarning(to: menu)
        addHotkeyRegistrationWarning(to: menu)
        addLayoutItems(to: menu)
        if lastRestoreResult != nil || lastAutomaticDecision != nil || slotEngine?.restoreSession.isRunning == true {
            menu.addItem(.separator())
        }
        addLastRestoreReport(to: menu)
        addLastAutomaticDecision(to: menu)

        menu.addItem(.separator())

        let createItem = NSMenuItem(
            title: "\(L10n.text(.captureCurrentLayout))…",
            action: #selector(createLayout),
            keyEquivalent: ""
        )
        createItem.target = self
        createItem.image = menuIcon("plus")
        createItem.isEnabled = slotEngine != nil && AccessibilityManager.isTrusted() && slotEngine?.restoreSession.isRunning != true
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

    @objc private func restartPerch() {
        do {
            try AccessibilityManager.relaunchCurrentApp()
        } catch {
            AppLog.app.error("Failed to relaunch Perch: \(error.localizedDescription, privacy: .private)")
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
                AppLog.menu.error("Accessibility permission reset failed: \(error.localizedDescription, privacy: .private)")
                ToastWindow.show(LocalizedErrorMessages.message(for: error))
            }
        }
    }

    @objc func saveLayout(_ sender: NSMenuItem) {
        guard let slotID = sender.representedObject as? String else {
            AppLog.menu.error("Save layout menu item missing layout ID")
            return
        }

        saveLayout(id: slotID)
    }

    @objc func restoreLayout(_ sender: NSMenuItem) {
        guard let slotID = sender.representedObject as? String else {
            AppLog.menu.error("Restore layout menu item missing layout ID")
            return
        }

        restoreLayout(id: slotID)
    }

    @objc private func createLayout() {
        guard let slotEngine,
              let name = promptForLayoutName(
                  title: L10n.text(.captureCurrentLayout),
                  defaultName: L10n.text(.newLayoutDefaultName)
              )
        else {
            return
        }

        Task { @MainActor in
            do {
                let layout = try await slotEngine.createLayoutFromCurrentWindows(name: name)
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
        if preflight == nil, let slotEngine { RestoreReportWindowController.shared.show(engine: slotEngine) }
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

    func reloadSlots() {
        guard let slotEngine else {
            slots = Slot.defaultSlots
            rebuildMenu()
            return
        }

        Task { @MainActor in
            do {
                let document = try await slotEngine.currentDocument()
                recoveryNotice = try await slotEngine.recoveryNotice()
                slots = document.slots
                settings = document.settings
                configureStatusItem()
            } catch {
                AppLog.persistence.error("Failed to reload slots: \(error.localizedDescription, privacy: .private)")
                slots = Slot.defaultSlots
            }

            rebuildMenu()
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

    func menuIcon(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
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
