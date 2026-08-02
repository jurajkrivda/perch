import AppKit
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var slotEngine: SlotEngine?
    private var hotkeyManager: HotkeyManager?
    private var autoRestoreCoordinator: AutoRestoreCoordinator?
    private var terminationWaitTask: Task<Void, Never>?
    private var documentChangeObserver: NSObjectProtocol?
    private var languageChangeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceLock.acquire() else {
            AppLog.app.warning("Another Perch instance is already running; terminating duplicate launch")
            NSApp.terminate(nil)
            return
        }

        NSApp.appearance = nil
        protectMenuBarRuntime()
        AccessibilityManager.configureMessagingTimeout()
        Task {
            await DisplayStabilizer.shared.start()
        }
        AppLog.app.info("Perch launched")
        AccessibilityManager.logStatus(reason: "at launch")
        LegacyLicensingDataCleaner().runIfNeeded()
        // Instantiating the shared controller starts Sparkle's scheduled checks.
        _ = UpdaterController.shared

        do {
            let slotEngine = try SlotEngine.shared()
            self.slotEngine = slotEngine
            let menuBarController = MenuBarController(slotEngine: slotEngine)
            self.menuBarController = menuBarController
            observeDocumentChanges()
            registerHotkeys()
            let autoRestoreCoordinator = AutoRestoreCoordinator(
                slotEngine: slotEngine,
                menuBarController: menuBarController
            )
            self.autoRestoreCoordinator = autoRestoreCoordinator
            autoRestoreCoordinator.start()
        } catch {
            AppLog.app.error("Failed to initialize slot engine: \(error.localizedDescription, privacy: .public)")
            menuBarController = MenuBarController(slotEngine: nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let autoRestoreCoordinator,
              autoRestoreCoordinator.hasCommittedAutomaticRestoreInFlight
        else {
            return .terminateNow
        }

        guard terminationWaitTask == nil else {
            return .terminateLater
        }

        AppLog.app.info("Delaying termination until the committed automatic restore finishes")
        autoRestoreCoordinator.stop()
        terminationWaitTask = Task { @MainActor [weak self] in
            await autoRestoreCoordinator.waitForCommittedAutomaticRestoreIfNeeded()
            self?.terminationWaitTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.app.info("Perch terminated")
        autoRestoreCoordinator?.stop()
        hotkeyManager?.unregisterAll()
        SingleInstanceLock.release()
        if let documentChangeObserver {
            NotificationCenter.default.removeObserver(documentChangeObserver)
        }
        if let languageChangeObserver {
            NotificationCenter.default.removeObserver(languageChangeObserver)
        }
    }

    /// Belt-and-suspenders next to the Info.plist NSSupportsAutomaticTermination
    /// and NSSupportsSuddenTermination keys, both already false.
    private func protectMenuBarRuntime() {
        ProcessInfo.processInfo.disableAutomaticTermination("Perch runs as a menu bar utility with global shortcuts.")
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    private func observeDocumentChanges() {
        documentChangeObserver = NotificationCenter.default.addObserver(
            forName: .perchDocumentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.menuBarController?.refresh()
                self?.registerHotkeys()
            }
        }

        // Re-register on language changes so the hotkey descriptions shown in
        // the shortcut-failure submenu follow the selected language.
        languageChangeObserver = NotificationCenter.default.addObserver(
            forName: .perchLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerHotkeys()
            }
        }
    }

    private func registerHotkeys() {
        guard let slotEngine, let menuBarController else {
            return
        }

        Task { @MainActor in
            do {
                let document = try await slotEngine.currentDocument()
                let hotkeyManager = self.hotkeyManager ?? HotkeyManager()
                hotkeyManager.register(
                    document: document,
                    save: { [weak menuBarController] slotIndex in
                        menuBarController?.saveSlot(index: slotIndex)
                    },
                    restore: { [weak menuBarController] layoutID in
                        menuBarController?.restoreLayout(id: layoutID)
                    }
                )
                menuBarController.updateHotkeyRegistrationState(
                    hotkeyManager.registrationState
                )
                self.hotkeyManager = hotkeyManager
            } catch {
                AppLog.hotkeys.error("Failed to register hotkeys: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
