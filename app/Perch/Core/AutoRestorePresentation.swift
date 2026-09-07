import Foundation

/// The coordinator uses the same restore operation as the menu and hotkeys.
/// Keeping presentation at this interface lets tests exercise the real event
/// pipeline without creating panels, moving windows, or registering hotkeys.
@MainActor
protocol AutoRestorePresenting: AnyObject {
    func restoreLayout(id: String, preflight: RestorePreflight?) -> Task<Void, Never>
    func registeredRestoreShortcutDescription(for layoutID: String, in document: SlotStoreDocument) -> String?
    func updateLastAutomaticDecision(key: LocalizationKey, argument: String?)
    func showRestorePrompt(_ prompt: AutoRestorePrompt) -> Bool
    func invalidateRestorePrompt()
}

struct AutoRestorePrompt {
    let layoutName: String
    let shortcutDescription: String?
    let onConfirm: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void
    let onSupersededByRestore: @MainActor () -> Void
}

@MainActor
enum AutoRestoreDiagnostics {
    private(set) static var lastDecision = "not started"

    static func record(decision: String, trigger: EnvironmentChangeReason) {
        lastDecision = "\(decision); trigger=\(trigger.rawValue)"
        AppLog.display.info("Automatic restore decision: \(decision, privacy: .public); trigger=\(trigger.rawValue, privacy: .public)")
    }
}
