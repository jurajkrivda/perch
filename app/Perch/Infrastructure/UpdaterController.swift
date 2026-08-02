import AppKit
import Sparkle

/// Makes scheduled Sparkle alerts noticeable in this dockless menu-bar app.
/// Sparkle keeps this delegate weakly, so UpdaterController owns it strongly.
@MainActor
private final class UpdateReminderDelegate: NSObject, @MainActor SPUStandardUserDriverDelegate {
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if previousActivationPolicy == nil {
            previousActivationPolicy = NSApp.activationPolicy()
        }

        // Sparkle's alert otherwise appears behind other applications for an
        // LSUIElement app. Temporarily joining the Dock also keeps the update
        // window reachable from the app switcher throughout the session.
        NSApp.setActivationPolicy(.regular)

        if !state.userInitiated {
            NSApp.dockTile.badgeLabel = "1"
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NSApp.dockTile.badgeLabel = ""
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.dockTile.badgeLabel = ""

        if let previousActivationPolicy {
            NSApp.setActivationPolicy(previousActivationPolicy)
            self.previousActivationPolicy = nil
        }
    }
}

/// Thin wrapper around Sparkle's standard updater so UI code has one
/// main-actor surface for update checks and the auto-check preference.
/// Sparkle persists the preference itself (SUEnableAutomaticChecks in
/// user defaults), so this class holds no state of its own.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let updateReminderDelegate: UpdateReminderDelegate
    private let controller: SPUStandardUpdaterController

    private init() {
        let updateReminderDelegate = UpdateReminderDelegate()
        self.updateReminderDelegate = updateReminderDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: updateReminderDelegate
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
