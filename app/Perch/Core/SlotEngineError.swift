import Foundation

enum SlotEngineError: LocalizedError {
    case slotNotFound(String)
    case invalidLayoutName
    case operationInProgress
    case restorePreflightRejected
    case displayConfigurationChanged
    case hotkeyConflict(HotkeyConflict)

    var errorDescription: String? {
        switch self {
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
