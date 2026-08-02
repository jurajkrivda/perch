import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var languageChangeObserver: NSObjectProtocol?

    private init() {
        languageChangeObserver = NotificationCenter.default.addObserver(
            forName: .perchLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window?.title = L10n.text(.settingsWindowTitle)
            }
        }
    }

    func show() {
        let settingsWindow = window ?? makeWindow()
        settingsWindow.title = L10n.text(.settingsWindowTitle)
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.text(.settingsWindowTitle)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // Establish the first-launch frame before enabling autosave. Setting the
        // name restores a saved frame immediately; sizing/centering afterwards
        // would overwrite the restoration on every launch.
        window.setContentSize(NSSize(width: 560, height: 560))
        window.center()
        window.setFrameAutosaveName("PerchSettingsWindow")

        self.window = window
        return window
    }
}
