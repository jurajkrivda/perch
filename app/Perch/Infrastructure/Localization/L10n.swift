import Foundation

@MainActor
enum L10n {
    static var manager: LocalizationManager {
        LocalizationManager.shared
    }

    static func text(_ key: LocalizationKey) -> String {
        manager.text(key)
    }

    static func format(_ key: LocalizationKey, _ arguments: CVarArg...) -> String {
        manager.format(key, arguments: arguments)
    }

    static func savedWindowCount(_ count: Int) -> String {
        manager.savedWindowCount(count)
    }

    static func restoreSummary(succeeded: Int, total: Int, openedAppCount: Int) -> String {
        manager.restoreSummary(succeeded: succeeded, total: total, openedAppCount: openedAppCount)
    }
}
