import Foundation

enum SlotEngineError: LocalizedError {
    case slotNotFound(String)
    case invalidLayoutName
    case operationInProgress
    case restorePreflightRejected
    case displayConfigurationChanged
    case hotkeyConflict(HotkeyConflict)
    case noWindowsToCapture
    case layoutChangedSinceRestore
    case repairWindowUnavailable
    case nothingToUndo
    case undoDisplayConfigurationChanged
    case windowAlreadyAssigned

    var errorDescription: String? {
        switch self {
        case .windowAlreadyAssigned:
            "This window is already assigned to another position in this layout."
        case .noWindowsToCapture:
            "No movable windows are open. Open the windows you want to save and try again."
        case .layoutChangedSinceRestore:
            "This layout has changed. Restore its current version before retrying individual windows."
        case .repairWindowUnavailable:
            "The selected window is no longer available. Refresh the open windows and choose again."
        case .nothingToUndo:
            "There are no window moves to undo."
        case .undoDisplayConfigurationChanged:
            "Reconnect the same displays before undoing these window moves."
        case let .slotNotFound(slotID):
            "Slot not found: \(slotID)"
        case .invalidLayoutName:
            "Layout name cannot be empty."
        case .operationInProgress:
            "Another save or restore is already running."
        case .restorePreflightRejected:
            "The display environment changed before automatic restore could begin."
        case .displayConfigurationChanged:
            "Displays changed while saving. Wait for them to settle and save the layout again."
        case let .hotkeyConflict(conflict):
            switch conflict.action {
            case .save:
                "Shortcut is already used to save \(conflict.layoutName)."
            case .restore:
                "Shortcut is already used to restore \(conflict.layoutName)."
            }
        }
    }
}
