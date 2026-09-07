import AppKit

extension MenuBarController {
    func addStoreRecoveryWarning(to menu: NSMenu) {
        guard recoveryNotice != nil else { return }
        let item = NSMenuItem(
            title: L10n.text(.storeRecoveryTitle) + "…",
            action: #selector(openSettings), keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        menu.addItem(item)
        menu.addItem(.separator())
    }
}
