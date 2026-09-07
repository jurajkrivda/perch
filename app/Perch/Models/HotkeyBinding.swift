import Carbon
import Foundation

struct HotkeyBinding: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static func defaultRestore(for index: Int) -> HotkeyBinding? {
        guard let keyCode = digitKeyCode(for: index) else {
            return nil
        }

        return HotkeyBinding(keyCode: keyCode, modifiers: UInt32(cmdKey | optionKey))
    }

    static func defaultSave(for index: Int) -> HotkeyBinding? {
        guard let keyCode = digitKeyCode(for: index) else {
            return nil
        }

        return HotkeyBinding(keyCode: keyCode, modifiers: UInt32(cmdKey | optionKey | shiftKey))
    }

    var displayString: String {
        "\(modifierDisplayString)\(keyDisplayString)"
    }

    private var modifierDisplayString: String {
        var symbols = ""

        if modifiers & UInt32(controlKey) != 0 {
            symbols += "^"
        }
        if modifiers & UInt32(optionKey) != 0 {
            symbols += "Option-"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            symbols += "Shift-"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            symbols += "Command-"
        }

        return symbols
    }

    private var keyDisplayString: String {
        Self.keyDisplayName(for: keyCode)
    }

    private static func digitKeyCode(for index: Int) -> UInt32? {
        let keyCodes = [
            UInt32(kVK_ANSI_1),
            UInt32(kVK_ANSI_2),
            UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4),
            UInt32(kVK_ANSI_5),
            UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7),
            UInt32(kVK_ANSI_8),
            UInt32(kVK_ANSI_9)
        ]

        guard keyCodes.indices.contains(index) else {
            return nil
        }

        return keyCodes[index]
    }

    static func keyDisplayName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_Space: "Space"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_F13: "F13"
        case kVK_F14: "F14"
        case kVK_F15: "F15"
        case kVK_F16: "F16"
        case kVK_F17: "F17"
        case kVK_F18: "F18"
        case kVK_F19: "F19"
        case kVK_F20: "F20"
        case kVK_UpArrow: "Up Arrow"
        case kVK_DownArrow: "Down Arrow"
        case kVK_LeftArrow: "Left Arrow"
        case kVK_RightArrow: "Right Arrow"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "Page Up"
        case kVK_PageDown: "Page Down"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Escape: "Escape"
        case kVK_Delete: "Delete"
        case kVK_ForwardDelete: "Forward Delete"
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Slash: "/"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Minus: "-"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_Grave: "`"
        default: "Key \(keyCode)"
        }
    }
}

struct HotkeyConflict: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case save
        case restore
    }

    let action: Action
    let layoutID: String
    let layoutName: String
}
