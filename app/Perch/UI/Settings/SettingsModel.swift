import Foundation
import Observation

@MainActor
@Observable
final class SettingsModel {
    private struct PendingBooleanSetting {
        let revision: Int
        let value: Bool
    }

    private struct PendingAutoRestoreModeSetting {
        let revision: Int
        let value: AutoRestoreMode
    }

    private struct PendingTimeIntervalSetting {
        let revision: Int
        let value: TimeInterval
    }

    var document = SlotStoreDocument()
    var layoutNameDrafts: [String: String] = [:]
    var newLayoutName = ""
    var isAccessibilityTrusted = AccessibilityManager.isTrusted()
    var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    var launchAtLoginError: String?
    var automaticUpdateChecksEnabled = true
    var showsMenuBarLabel = true
    var opensMissingApplicationsOnRestore = false
    var autoRestoreMode: AutoRestoreMode = .prompt
    var autoRestoreSettleTimeout: TimeInterval = 10
    var errorMessage: String?
    var accessibilityResetError: String?
    var hasRequestedAccessibilityPermission = AccessibilityManager.hasRequestedPermissionForCurrentApp()
    var localization = LocalizationManager.shared

    private var slotEngine: SlotEngine?
    private var accessibilityRefreshTask: Task<Void, Never>?
    private var documentRefreshTask: Task<Void, Never>?
    private var documentMutationTail: Task<Void, Never>?
    private var settingsWriteTail: Task<Void, Never>?
    private var refreshState = SettingsRefreshState()
    private var mutationState = SettingsMutationState()
    private var documentMutationRevision = 0
    private var settingsRevision = 0
    private var pendingMenuBarLabel: PendingBooleanSetting?
    private var pendingMissingApplications: PendingBooleanSetting?
    private var pendingAutoRestoreMode: PendingAutoRestoreModeSetting?
    private var pendingAutoRestoreSettleTimeout: PendingTimeIntervalSetting?

    var selectedLanguage: AppLanguage {
        get { localization.selectedLanguage }
        set { localization.selectedLanguage = newValue }
    }

    var languageOptions: [AppLanguage] {
        AppLanguage.allCases
    }

    var isCreatingLayout: Bool {
        mutationState.isCreatingLayout
    }

    /// Computed so the status text re-localizes whenever the view re-renders
    /// after a language change instead of caching one language's string.
    var launchAtLoginStatus: String {
        LaunchAtLogin.statusDescription
    }

    /// Must be called once before any CRUD method. Until it runs, `slotEngine` is nil and the CRUD methods intentionally no-op (mirrors the original SettingsView behavior).
    func bootstrap() async {
        initializeEngineIfNeeded()
        await refreshDocument()
        refreshLaunchAtLoginStatus()
        refreshAccessibilityStatus()
        refreshAutomaticUpdateChecks()
    }

    private func initializeEngineIfNeeded() {
        guard slotEngine == nil else { return }

        do {
            slotEngine = try SlotEngine.shared()
        } catch {
            errorMessage = LocalizedErrorMessages.message(for: error)
        }
    }

    func refreshDocument() async {
        guard let slotEngine else { return }
        let generation = refreshState.beginLoad()

        do {
            let loadedDocument = try await slotEngine.currentDocument()
            guard refreshState.shouldApply(generation: generation) else { return }
            let previousNames = Dictionary(uniqueKeysWithValues: document.slots.map { ($0.id, $0.name) })
            let previousDrafts = layoutNameDrafts

            document = loadedDocument
            applyDisplayedSettings()
            layoutNameDrafts = Dictionary(uniqueKeysWithValues: loadedDocument.slots.map { slot in
                let previousName = previousNames[slot.id]
                if let draft = previousDrafts[slot.id],
                   draft != previousName,
                   draft != slot.name {
                    return (slot.id, draft)
                }
                return (slot.id, slot.name)
            })
            errorMessage = nil
        } catch {
            guard refreshState.shouldApply(generation: generation) else { return }
            errorMessage = LocalizedErrorMessages.message(for: error)
        }
    }

    /// Coalesces document-change notifications while guaranteeing a second
    /// load when another change arrives during an in-flight load.
    func scheduleDocumentRefresh() {
        guard refreshState.requestScheduledRefresh() else { return }

        documentRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while true {
                refreshState.beginScheduledRefreshPass()
                await refreshDocument()
                guard refreshState.finishScheduledRefreshPass() else { break }
            }

            documentRefreshTask = nil
        }
    }

    func createLayout() {
        guard let slotEngine else { return }

        let name = newLayoutName
        guard mutationState.beginCreate() else { return }

        enqueueDocumentMutation(
            operation: {
                _ = try await slotEngine.createLayout(name: name)
            },
            completion: { [weak self] succeeded in
                guard let self else { return }
                if succeeded, newLayoutName == name {
                    newLayoutName = ""
                }
                mutationState.finishCreate()
            }
        )
    }

    func renameLayout(_ layout: Slot) {
        guard let slotEngine else { return }

        let name = layoutNameDrafts[layout.id] ?? layout.name
        guard name != layout.name else { return }
        guard let token = mutationState.beginRename(layoutID: layout.id, name: name) else { return }

        enqueueDocumentMutation(
            operation: {
                try await slotEngine.renameLayout(id: layout.id, name: name)
            },
            completion: { [weak self] _ in
                self?.mutationState.finishRename(token)
            }
        )
    }

    func deleteLayout(_ layout: Slot) {
        guard let slotEngine else { return }
        guard mutationState.beginDelete(layoutID: layout.id) else { return }

        enqueueDocumentMutation(
            operation: {
                try await slotEngine.deleteLayout(id: layout.id)
            },
            completion: { [weak self] _ in
                self?.mutationState.finishDelete(layoutID: layout.id)
            }
        )
    }

    func setRestoreHotkey(_ hotkey: HotkeyBinding?, for layout: Slot) {
        guard let slotEngine else { return }
        guard let token = mutationState.beginHotkey(layoutID: layout.id, hotkey: hotkey) else { return }

        enqueueDocumentMutation(
            operation: {
                try await slotEngine.setRestoreHotkey(layoutID: layout.id, hotkey: hotkey)
            },
            completion: { [weak self] _ in
                self?.mutationState.finishHotkey(token)
            }
        )
    }

    private func enqueueDocumentMutation(
        operation: @escaping @MainActor @Sendable () async throws -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        documentMutationRevision &+= 1
        let revision = documentMutationRevision
        let previousMutation = documentMutationTail

        documentMutationTail = Task { @MainActor [weak self] in
            await previousMutation?.value
            guard let self else { return }

            let succeeded: Bool
            do {
                try await operation()
                succeeded = true
                await refreshDocument()
            } catch {
                succeeded = false
                refreshState.invalidateLoads()
                errorMessage = LocalizedErrorMessages.message(for: error)
            }

            completion(succeeded)
            if documentMutationRevision == revision {
                documentMutationTail = nil
            }
        }
    }

    func effectiveHotkey(for layout: Slot) -> HotkeyBinding? {
        document.effectiveRestoreHotkey(for: layout.id)
    }

    func effectiveHotkeyDisplay(for layout: Slot) -> String {
        effectiveHotkey(for: layout)?.displayString ?? L10n.text(.noRestoreShortcut)
    }

    func updateMenuBarLabelVisibility(_ isVisible: Bool) {
        guard let slotEngine else { return }
        let desiredValue = pendingMenuBarLabel?.value ?? document.settings.showsMenuBarLabel
        guard isVisible != desiredValue else { return }

        settingsRevision += 1
        let revision = settingsRevision
        pendingMenuBarLabel = PendingBooleanSetting(revision: revision, value: isVisible)
        let previousWrite = settingsWriteTail
        settingsWriteTail = Task { @MainActor [weak self] in
            await previousWrite?.value
            guard let self else { return }

            do {
                let settings = try await slotEngine.updateSettings { settings in
                    settings.showsMenuBarLabel = isVisible
                }
                refreshState.invalidateLoads()
                document.settings = settings
                if pendingMenuBarLabel?.revision == revision {
                    pendingMenuBarLabel = nil
                }
                applyDisplayedSettings()
                if settingsRevision == revision {
                    settingsWriteTail = nil
                }
            } catch {
                errorMessage = LocalizedErrorMessages.message(for: error)
                if pendingMenuBarLabel?.revision == revision {
                    pendingMenuBarLabel = nil
                }
                await refreshDocument()
                if settingsRevision == revision {
                    settingsWriteTail = nil
                }
            }
        }
    }

    func updateMissingApplicationsRestoreBehavior(_ shouldOpenApplications: Bool) {
        guard let slotEngine else { return }
        let desiredValue = pendingMissingApplications?.value
            ?? document.settings.opensMissingApplicationsOnRestore
        guard shouldOpenApplications != desiredValue else { return }

        settingsRevision += 1
        let revision = settingsRevision
        pendingMissingApplications = PendingBooleanSetting(
            revision: revision,
            value: shouldOpenApplications
        )
        let previousWrite = settingsWriteTail
        settingsWriteTail = Task { @MainActor [weak self] in
            await previousWrite?.value
            guard let self else { return }

            do {
                let settings = try await slotEngine.updateSettings { settings in
                    settings.opensMissingApplicationsOnRestore = shouldOpenApplications
                }
                refreshState.invalidateLoads()
                document.settings = settings
                if pendingMissingApplications?.revision == revision {
                    pendingMissingApplications = nil
                }
                applyDisplayedSettings()
                if settingsRevision == revision {
                    settingsWriteTail = nil
                }
            } catch {
                errorMessage = LocalizedErrorMessages.message(for: error)
                if pendingMissingApplications?.revision == revision {
                    pendingMissingApplications = nil
                }
                await refreshDocument()
                if settingsRevision == revision {
                    settingsWriteTail = nil
                }
            }
        }
    }

    func updateAutoRestoreMode(_ mode: AutoRestoreMode) {
        guard let slotEngine else { return }
        let desiredValue = pendingAutoRestoreMode?.value ?? document.settings.autoRestoreMode
        guard mode != desiredValue else { return }

        settingsRevision += 1
        let revision = settingsRevision
        pendingAutoRestoreMode = PendingAutoRestoreModeSetting(revision: revision, value: mode)
        let previousWrite = settingsWriteTail
        settingsWriteTail = Task { @MainActor [weak self] in
            await previousWrite?.value
            guard let self else { return }

            do {
                let settings = try await slotEngine.updateSettings { settings in
                    settings.autoRestoreMode = mode
                }
                refreshState.invalidateLoads()
                document.settings = settings
                if pendingAutoRestoreMode?.revision == revision {
                    pendingAutoRestoreMode = nil
                }
                applyDisplayedSettings()
                if settingsRevision == revision {
                    settingsWriteTail = nil
                }
            } catch {
                errorMessage = LocalizedErrorMessages.message(for: error)
                if pendingAutoRestoreMode?.revision == revision {
                    pendingAutoRestoreMode = nil
                }
                await refreshDocument()
                if settingsRevision == revision {
                    settingsWriteTail = nil
                }
            }
        }
    }

    func updateAutoRestoreSettleTimeout(_ timeout: TimeInterval) {
        guard let slotEngine else { return }
        let clampedTimeout = min(
            max(timeout, SlotStoreDocument.autoRestoreSettleTimeoutRange.lowerBound),
            SlotStoreDocument.autoRestoreSettleTimeoutRange.upperBound
        )
        let desiredValue = pendingAutoRestoreSettleTimeout?.value
            ?? document.settings.autoRestoreSettleTimeout
        guard clampedTimeout != desiredValue else { return }

        settingsRevision += 1
        let revision = settingsRevision
        pendingAutoRestoreSettleTimeout = PendingTimeIntervalSetting(
            revision: revision,
            value: clampedTimeout
        )
        let previousWrite = settingsWriteTail
        settingsWriteTail = Task { @MainActor [weak self] in
            await previousWrite?.value
            guard let self else { return }

            do {
                let settings = try await slotEngine.updateSettings { settings in
                    settings.autoRestoreSettleTimeout = clampedTimeout
                }
                refreshState.invalidateLoads()
                document.settings = settings
                if pendingAutoRestoreSettleTimeout?.revision == revision {
                    pendingAutoRestoreSettleTimeout = nil
                }
                applyDisplayedSettings()
                if settingsRevision == revision {
                    settingsWriteTail = nil
                }
            } catch {
                errorMessage = LocalizedErrorMessages.message(for: error)
                if pendingAutoRestoreSettleTimeout?.revision == revision {
                    pendingAutoRestoreSettleTimeout = nil
                }
                await refreshDocument()
                if settingsRevision == revision {
                    settingsWriteTail = nil
                }
            }
        }
    }

    func updateLaunchAtLogin(_ isEnabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(isEnabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    func updateAutomaticUpdateChecks(_ isEnabled: Bool) {
        UpdaterController.shared.automaticallyChecksForUpdates = isEnabled
        refreshAutomaticUpdateChecks()
    }

    func refreshAutomaticUpdateChecks() {
        automaticUpdateChecksEnabled = UpdaterController.shared.automaticallyChecksForUpdates
    }

    func refreshAccessibilityStatus() {
        isAccessibilityTrusted = AccessibilityManager.isTrusted()
        hasRequestedAccessibilityPermission = AccessibilityManager.hasRequestedPermissionForCurrentApp()
    }

    func requestAccessibilityPermission() {
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = Task { @MainActor in
            isAccessibilityTrusted = await AccessibilityManager.requestPermissionAndWait()
            hasRequestedAccessibilityPermission = AccessibilityManager.hasRequestedPermissionForCurrentApp()
        }
    }

    func resetAccessibilityPermission() {
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = Task { @MainActor in
            do {
                try await AccessibilityManager.resetPermissionForCurrentApp()
                accessibilityResetError = nil
                refreshAccessibilityStatus()
                isAccessibilityTrusted = await AccessibilityManager.requestPermissionAndWait()
                refreshAccessibilityStatus()
            } catch {
                accessibilityResetError = error.localizedDescription
            }
        }
    }

    private func applyDisplayedSettings() {
        showsMenuBarLabel = pendingMenuBarLabel?.value ?? document.settings.showsMenuBarLabel
        opensMissingApplicationsOnRestore = pendingMissingApplications?.value
            ?? document.settings.opensMissingApplicationsOnRestore
        autoRestoreMode = pendingAutoRestoreMode?.value ?? document.settings.autoRestoreMode
        autoRestoreSettleTimeout = pendingAutoRestoreSettleTimeout?.value
            ?? document.settings.autoRestoreSettleTimeout
    }
}
