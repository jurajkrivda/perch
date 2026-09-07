import Foundation
import Observation

@MainActor
@Observable
final class SettingsModel {
    private struct PendingSetting<Value> {
        let revision: Int
        let value: Value
    }

    var document = SlotStoreDocument()
    var layoutNameDrafts: [String: String] = [:]
    var newLayoutName = ""
    var isAccessibilityTrusted = AccessibilityManager.isTrusted()
    var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    private var launchAtLoginRegistrationStatus = LaunchAtLogin.registrationStatus
    var launchAtLoginError: String?
    var automaticUpdateChecksEnabled = true
    var showsMenuBarLabel = true
    var opensMissingApplicationsOnRestore = false
    var autoRestoreMode: AutoRestoreMode = .prompt
    var autoRestoreSettleTimeout: TimeInterval = 10
    var errorMessage: String?
    var recoveryNotice: StoreRecoveryNotice?
    var recoveryErrorMessage: String?
    var isAcknowledgingRecovery = false
    var currentTopology = DisplayManager.currentTopologyFingerprint()
    var changingLayoutID: String?
    var accessibilityResetError: String?
    var hasRequestedAccessibilityPermission = AccessibilityManager.hasRequestedPermissionForCurrentApp()
    var localization = LocalizationManager.shared

    var slotEngine: SlotEngine?
    private var accessibilityRefreshTask: Task<Void, Never>?
    private var documentRefreshTask: Task<Void, Never>?
    private var documentMutationTail: Task<Void, Never>?
    private var settingsWriteTail: Task<Void, Never>?
    private var refreshState = SettingsRefreshState()
    private var mutationState = SettingsMutationState()
    private var documentMutationRevision = 0
    private var settingsRevision = 0
    private var pendingMenuBarLabel: PendingSetting<Bool>?
    private var pendingMissingApplications: PendingSetting<Bool>?
    private var pendingAutoRestoreMode: PendingSetting<AutoRestoreMode>?
    private var pendingAutoRestoreSettleTimeout: PendingSetting<TimeInterval>?

    init(slotEngine: SlotEngine? = nil) {
        self.slotEngine = slotEngine
    }

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
        LaunchAtLogin.statusDescription(for: launchAtLoginRegistrationStatus)
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
            let loadedRecoveryNotice = try await slotEngine.recoveryNotice()
            guard refreshState.shouldApply(generation: generation) else { return }
            let previousNames = Dictionary(uniqueKeysWithValues: document.slots.map { ($0.id, $0.name) })
            let previousDrafts = layoutNameDrafts

            document = loadedDocument
            currentTopology = DisplayManager.currentTopologyFingerprint()
            recoveryNotice = loadedRecoveryNotice
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
                _ = try await slotEngine.createLayoutFromCurrentWindows(name: name)
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

    func enqueueDocumentMutation(
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

    func acknowledgeRecoveryNotice() {
        guard let slotEngine, let recoveryNotice, !isAcknowledgingRecovery else { return }
        isAcknowledgingRecovery = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isAcknowledgingRecovery = false }
            do {
                try await slotEngine.acknowledgeRecoveryNotice(recoveryNotice)
                await refreshDocument()
                recoveryErrorMessage = nil
            } catch {
                recoveryErrorMessage = LocalizedErrorMessages.message(for: error)
            }
        }
    }

    func effectiveHotkeyDisplay(for layout: Slot) -> String {
        effectiveHotkey(for: layout)?.displayString ?? L10n.text(.noRestoreShortcut)
    }

    func updateMenuBarLabelVisibility(_ isVisible: Bool) {
        enqueueSetting(value: isVisible, currentValue: document.settings.showsMenuBarLabel,
                       pending: \.pendingMenuBarLabel) { $0.showsMenuBarLabel = isVisible }
    }

    func updateMissingApplicationsRestoreBehavior(_ shouldOpen: Bool) {
        enqueueSetting(value: shouldOpen, currentValue: document.settings.opensMissingApplicationsOnRestore,
                       pending: \.pendingMissingApplications) { $0.opensMissingApplicationsOnRestore = shouldOpen }
    }

    func updateAutoRestoreMode(_ mode: AutoRestoreMode) {
        enqueueSetting(value: mode, currentValue: document.settings.autoRestoreMode,
                       pending: \.pendingAutoRestoreMode) { $0.autoRestoreMode = mode }
    }

    func updateAutoRestoreSettleTimeout(_ timeout: TimeInterval) {
        guard timeout.isFinite else { return }
        let range = SlotStoreDocument.autoRestoreSettleTimeoutRange
        let value = min(max(timeout, range.lowerBound), range.upperBound)
        enqueueSetting(value: value, currentValue: document.settings.autoRestoreSettleTimeout,
                       pending: \.pendingAutoRestoreSettleTimeout) { $0.autoRestoreSettleTimeout = value }
    }

    /// Serialize writes and keep each control's latest optimistic value while
    /// earlier writes finish. A failed write must leave its error visible even
    /// when reloading the persisted document succeeds.
    private func enqueueSetting<Value: Equatable & Sendable>(
        value: Value,
        currentValue: Value,
        pending: ReferenceWritableKeyPath<SettingsModel, PendingSetting<Value>?>,
        update: @escaping @Sendable (inout PerchSettings) -> Void
    ) {
        guard let slotEngine,
              value != (self[keyPath: pending]?.value ?? currentValue) else { return }
        settingsRevision &+= 1
        let revision = settingsRevision
        self[keyPath: pending] = PendingSetting(revision: revision, value: value)
        applyDisplayedSettings()
        let previousWrite = settingsWriteTail
        settingsWriteTail = Task { @MainActor [weak self] in
            await previousWrite?.value
            guard let self else { return }
            defer {
                if settingsRevision == revision { settingsWriteTail = nil }
            }
            do {
                document.settings = try await slotEngine.updateSettings(update)
                refreshState.invalidateLoads()
                if self[keyPath: pending]?.revision == revision {
                    self[keyPath: pending] = nil
                }
                applyDisplayedSettings()
                errorMessage = nil
            } catch {
                let message = LocalizedErrorMessages.message(for: error)
                if self[keyPath: pending]?.revision == revision {
                    self[keyPath: pending] = nil
                }
                await refreshDocument()
                errorMessage = message
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
        // Pending approval and enabled both keep the toggle on, but the status
        // label must still refresh when macOS changes between those states.
        launchAtLoginRegistrationStatus = LaunchAtLogin.registrationStatus
        launchAtLoginEnabled = LaunchAtLogin.isRegistrationActive(launchAtLoginRegistrationStatus)
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
