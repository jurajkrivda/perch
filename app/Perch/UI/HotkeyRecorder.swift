import AppKit
import Carbon
import SwiftUI

struct HotkeyRecorder: NSViewRepresentable {
    var onRecord: (HotkeyBinding) -> Void
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onCancel = onCancel
        nsView.refreshLocalization()
    }

    final class RecorderView: NSView {
        private enum DisplayState {
            case prompt
            case requiresModifier
            case recorded(String)
        }

        var onRecord: ((HotkeyBinding) -> Void)?
        var onCancel: (() -> Void)?

        private let textField = NSTextField(labelWithString: L10n.text(.hotkeyRecordPrompt))
        private var displayState = DisplayState.prompt

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if Int(event.keyCode) == kVK_Escape {
                onCancel?()
                return
            }

            let commandLikeModifiers = event.modifierFlags.intersection([.command, .option, .control])
            if Int(event.keyCode) == kVK_Tab, commandLikeModifiers.isEmpty {
                if event.modifierFlags.contains(.shift) {
                    window?.selectPreviousKeyView(self)
                } else {
                    window?.selectNextKeyView(self)
                }
                return
            }

            let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)

            guard carbonModifiers != 0 else {
                displayState = .requiresModifier
                updateDisplayedValue(L10n.text(.hotkeyRequiresModifier), announce: true)
                return
            }

            let hotkey = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
            displayState = .recorded(hotkey.displayString)
            updateDisplayedValue(hotkey.displayString, announce: true)
            onRecord?(hotkey)
        }

        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
            updateFocusAppearance(isFocused: becameFirstResponder)
            return becameFirstResponder
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                updateFocusAppearance(isFocused: false)
            }
            return resigned
        }

        override func accessibilityPerformPress() -> Bool {
            window?.makeFirstResponder(self)
            return true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        private func setup() {
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            updateFocusAppearance()

            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(L10n.text(.recordRestoreShortcutHelp))
            setAccessibilityHelp(L10n.text(.hotkeyRecordPrompt))
            setAccessibilityValue(textField.stringValue)

            textField.alignment = .center
            textField.setAccessibilityElement(false)
            textField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textField)

            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 34),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
                textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                textField.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        func refreshLocalization() {
            setAccessibilityLabel(L10n.text(.recordRestoreShortcutHelp))
            setAccessibilityHelp(L10n.text(.hotkeyRecordPrompt))
            switch displayState {
            case .prompt:
                updateDisplayedValue(L10n.text(.hotkeyRecordPrompt), announce: false)
            case .requiresModifier:
                updateDisplayedValue(L10n.text(.hotkeyRequiresModifier), announce: false)
            case let .recorded(displayString):
                updateDisplayedValue(displayString, announce: false)
            }
        }

        private func updateDisplayedValue(_ value: String, announce: Bool) {
            guard textField.stringValue != value else {
                return
            }

            textField.stringValue = value
            setAccessibilityValue(value)
            NSAccessibility.post(element: self, notification: .valueChanged)

            if announce {
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: value,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue
                    ]
                )
            }
        }

        private func updateFocusAppearance(isFocused: Bool? = nil) {
            let isFocused = isFocused ?? (window?.firstResponder === self)
            layer?.borderWidth = isFocused ? 2 : 1
            layer?.borderColor = (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }

        private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var modifiers: UInt32 = 0

            if flags.contains(.command) {
                modifiers |= UInt32(cmdKey)
            }
            if flags.contains(.option) {
                modifiers |= UInt32(optionKey)
            }
            if flags.contains(.shift) {
                modifiers |= UInt32(shiftKey)
            }
            if flags.contains(.control) {
                modifiers |= UInt32(controlKey)
            }

            return modifiers
        }
    }
}
