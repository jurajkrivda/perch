import Foundation

extension RestoreWindowOutcome {
    var labelKey: LocalizationKey {
        switch self {
        case .restored: .menuOutcomeRestored
        case .launchedAndRestored: .menuOutcomeOpenedAndRestored
        case .appNotInstalled: .menuOutcomeNotInstalled
        case .launchFailed: .menuOutcomeLaunchFailed
        case .appNotRunning: .menuOutcomeClosed
        case .windowNotFound: .menuOutcomeWindowNotFound
        case .ambiguousWindowMatch: .menuOutcomeAmbiguousWindows
        case .frameWriteFailed: .menuOutcomeMoveFailed
        case .skipped: .menuOutcomeSkipped
        case .pending: .outcomePending
        case .cancelled: .outcomeCancelled
        }
    }

    var symbolName: String {
        switch self {
        case .restored: "checkmark.circle"
        case .launchedAndRestored: "arrow.up.forward.app"
        case .appNotInstalled: "questionmark.app"
        case .launchFailed: "exclamationmark.triangle"
        case .appNotRunning: "app"
        case .windowNotFound: "rectangle.dashed"
        case .ambiguousWindowMatch: "questionmark.square.dashed"
        case .frameWriteFailed: "rectangle.badge.exclamationmark"
        case .skipped: "minus.circle"
        case .pending: "clock"
        case .cancelled: "stop.circle"
        }
    }
}
