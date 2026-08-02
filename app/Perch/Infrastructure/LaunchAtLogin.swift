import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        isRegistrationActive(SMAppService.mainApp.status)
    }

    @MainActor
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return L10n.text(.launchStatusEnabled)
        case .notRegistered:
            return L10n.text(.launchStatusDisabled)
        case .requiresApproval:
            return L10n.text(.launchStatusRequiresApproval)
        case .notFound:
            return L10n.text(.launchStatusUnavailable)
        @unknown default:
            return L10n.text(.launchStatusUnknown)
        }
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            guard !isRegistrationActive(SMAppService.mainApp.status) else { return }
            try SMAppService.mainApp.register()
        } else {
            guard isRegistrationActive(SMAppService.mainApp.status) else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// A pending registration is still an active user choice. Treating it as
    /// off makes the toggle unable to cancel the request before approval.
    static func isRegistrationActive(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        case .notRegistered, .notFound:
            false
        @unknown default:
            false
        }
    }
}
