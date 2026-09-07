import Foundation

struct SlotOperationResult: Equatable, Sendable {
    let slotID: String
    let slotName: String
    let succeeded: Int
    let total: Int
    let details: [RestoreWindowReport]

    init(
        slotID: String,
        slotName: String,
        succeeded: Int,
        total: Int,
        details: [RestoreWindowReport] = []
    ) {
        self.slotID = slotID
        self.slotName = slotName
        self.succeeded = succeeded
        self.total = total
        self.details = details
    }

    var skipped: Int {
        max(total - succeeded, 0)
    }

    var openedAppCount: Int {
        Set(details.compactMap { $0.didLaunchApplication ? $0.bundleIdentifier : nil }).count
    }

    /// Isolated to the main actor so it can render in the current UI language;
    /// skipped windows are implied by the succeeded/total pair and detailed in
    /// the restore report rows.
    @MainActor
    var restoreSummary: String {
        guard total > 0 else {
            return L10n.text(.noWindowsSaved)
        }

        return L10n.restoreSummary(
            succeeded: succeeded,
            total: total,
            openedAppCount: openedAppCount
        )
    }
}

enum RestoreWindowOutcome: Equatable, Sendable {
    case restored
    case launchedAndRestored
    case appNotInstalled
    case launchFailed
    case appNotRunning
    case windowNotFound
    case ambiguousWindowMatch
    case frameWriteFailed
    case skipped

    var isSuccess: Bool {
        switch self {
        case .restored, .launchedAndRestored:
            true
        case .appNotInstalled,
             .launchFailed,
             .appNotRunning,
             .windowNotFound,
             .ambiguousWindowMatch,
             .frameWriteFailed,
             .skipped:
            false
        }
    }
}

struct RestoreWindowReport: Equatable, Identifiable, Sendable {
    let id: String
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let outcome: RestoreWindowOutcome
    let didLaunchApplication: Bool
    let matchReason: WindowMoveMatchReason?
    let message: String?

    var isSuccess: Bool {
        outcome.isSuccess
    }
}
