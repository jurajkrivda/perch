import AppKit
import Carbon

extension MenuBarController {
    func addLayoutItems(to menu: NSMenu) {
        menu.addItem(.sectionHeader(title: L10n.text(.layoutsSectionTitle)))

        guard !slots.isEmpty else {
            let emptyItem = NSMenuItem(title: L10n.text(.noLayoutsYet), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        let canUseEngine = slotEngine != nil
        let canSave = canUseEngine && AccessibilityManager.isTrusted()
        let document = SlotStoreDocument(slots: slots, settings: settings)

        for index in slots.indices {
            let slot = slots[index]
            let hasWindows = !slot.windows.isEmpty
            let restoreHotkey = document.effectiveRestoreHotkey(at: index)
            let saveHotkey = document.effectiveSaveHotkey(at: index)
            let restoreKeyEquivalent = menuKeyEquivalentIfAvailable(for: restoreHotkey)
            let saveKeyEquivalent = menuKeyEquivalentIfAvailable(for: saveHotkey)

            if hasWindows {
                let restoreItem = NSMenuItem(
                    title: slot.name,
                    action: #selector(restoreLayout(_:)),
                    keyEquivalent: restoreKeyEquivalent
                )
                restoreItem.keyEquivalentModifierMask = restoreHotkey.map(menuModifierFlags(for:)) ?? []
                restoreItem.target = self
                restoreItem.representedObject = slot.id
                restoreItem.image = menuIcon("rectangle.on.rectangle")
                restoreItem.isEnabled = canUseEngine
                if let restoreHotkey, isHotkeyUnavailable(restoreHotkey) {
                    restoreItem.toolTip = unavailableHotkeyTooltip(for: restoreHotkey)
                }
                menu.addItem(restoreItem)
            } else {
                let emptyItem = NSMenuItem(title: slot.name, action: nil, keyEquivalent: "")
                emptyItem.image = menuIcon("rectangle.badge.plus")
                emptyItem.isEnabled = false
                emptyItem.toolTip = L10n.text(.noWindowsSavedYet)
                menu.addItem(emptyItem)
            }

            let saveTitle = hasWindows
                ? L10n.format(.updateLayoutWindowsFormat, slot.name)
                : L10n.format(.saveCurrentWindowsFormat, slot.name)
            let saveItem = NSMenuItem(
                title: saveTitle,
                action: #selector(saveLayout(_:)),
                keyEquivalent: saveKeyEquivalent
            )
            // For layout index >= 9 there is no default save hotkey, so key/mask fall back to empty.
            saveItem.keyEquivalentModifierMask = saveHotkey.map(menuModifierFlags(for:)) ?? []
            saveItem.target = self
            saveItem.representedObject = slot.id
            saveItem.image = menuIcon(hasWindows ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
            saveItem.isEnabled = canSave
            saveItem.indentationLevel = 1
            if let saveHotkey, isHotkeyUnavailable(saveHotkey) {
                saveItem.toolTip = unavailableHotkeyTooltip(for: saveHotkey)
            }
            menu.addItem(saveItem)
        }
    }

    func addHotkeyRegistrationWarning(to menu: NSMenu) {
        let hotkeyRegistrationFailures = hotkeyRegistrationState.failures
        guard !hotkeyRegistrationFailures.isEmpty else {
            return
        }

        let warningItem = NSMenuItem(title: L10n.text(.someShortcutsUnavailable), action: nil, keyEquivalent: "")
        warningItem.image = menuIcon("exclamationmark.triangle.fill")

        let submenu = NSMenu()

        for failure in hotkeyRegistrationFailures {
            let item = NSMenuItem(
                title: "\(failure.displayString): \(failure.description)",
                action: nil,
                keyEquivalent: ""
            )
            item.toolTip = L10n.format(.shortcutRejectedTooltipFormat, failure.status)
            item.isEnabled = false
            submenu.addItem(item)
        }

        warningItem.submenu = submenu
        menu.addItem(warningItem)
        menu.addItem(.separator())
    }

    private func menuKeyEquivalent(for hotkey: HotkeyBinding) -> String {
        switch Int(hotkey.keyCode) {
        case kVK_Space:
            return " "
        default:
            let displayName = HotkeyBinding.keyDisplayName(for: hotkey.keyCode)
            return displayName.count == 1 ? displayName.lowercased() : ""
        }
    }

    private func menuKeyEquivalentIfAvailable(for hotkey: HotkeyBinding?) -> String {
        guard let hotkey, !isHotkeyUnavailable(hotkey) else {
            return ""
        }

        return menuKeyEquivalent(for: hotkey)
    }

    private func menuModifierFlags(for hotkey: HotkeyBinding) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []

        if hotkey.modifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
        }
        if hotkey.modifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
        }
        if hotkey.modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
        }
        if hotkey.modifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
        }

        return flags
    }

    private func isHotkeyUnavailable(_ hotkey: HotkeyBinding) -> Bool {
        !hotkeyRegistrationState.isRegistered(hotkey)
    }

    private func unavailableHotkeyTooltip(for hotkey: HotkeyBinding) -> String {
        L10n.format(.shortcutUnavailableTooltipFormat, hotkey.displayString)
    }}
