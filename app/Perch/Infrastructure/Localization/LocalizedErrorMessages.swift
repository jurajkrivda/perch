import Foundation

/// Maps user-facing errors to localized messages at the point where they are
/// shown. `LocalizedError.errorDescription` is a nonisolated protocol
/// requirement and cannot read the main-actor language state, so error
/// descriptions stay English for logs and this mapping localizes the UI.
@MainActor
enum LocalizedErrorMessages {
    static func message(for error: Error) -> String {
        switch error {
        case SlotEngineError.noWindowsToCapture: L10n.text(.noWindowsToCapture)
        case SlotEngineError.layoutChangedSinceRestore: L10n.text(.layoutChangedSinceRestore)
        case SlotEngineError.repairWindowUnavailable: L10n.text(.repairWindowUnavailable)
        case SlotEngineError.nothingToUndo: L10n.text(.nothingToUndo)
        case SlotEngineError.undoDisplayConfigurationChanged: L10n.text(.undoDisplayConfigurationChanged)
        case SlotEngineError.windowAlreadyAssigned: L10n.text(.windowAlreadyAssigned)
        case SlotEngineError.displayConfigurationChanged:
            L10n.text(.displaysChangedDuringSave)
        case SlotEngineError.invalidLayoutName:
            L10n.text(.layoutNameCannotBeEmpty)
        case SlotEngineError.operationInProgress:
            L10n.text(.operationAlreadyRunning)
        case let SlotEngineError.slotNotFound(slotID):
            L10n.format(.slotNotFoundFormat, slotID)
        case let SlotEngineError.hotkeyConflict(conflict):
            switch conflict.action {
            case .save:
                L10n.format(.shortcutAlreadyUsedSaveFormat, conflict.layoutName)
            case .restore:
                L10n.format(.shortcutAlreadyUsedRestoreFormat, conflict.layoutName)
            }
        case let SlotStore.StoreError.layoutNotFound(layoutID):
            L10n.format(.layoutNotFoundFormat, layoutID)
        case WindowMoverError.accessibilityPermissionMissing,
             WindowSnapshotterError.accessibilityPermissionMissing:
            L10n.text(.accessibilityBannerRequiredMessage)
        default:
            error.localizedDescription
        }
    }
}
