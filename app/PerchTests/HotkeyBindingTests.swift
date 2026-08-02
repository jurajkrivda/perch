import Carbon
import XCTest

final class HotkeyBindingTests: XCTestCase {
    func testKeyDisplayNameCoversFunctionKeys() {
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_F1)), "F1")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_F12)), "F12")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_F20)), "F20")
    }

    func testKeyDisplayNameCoversNavigationKeys() {
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_UpArrow)), "Up Arrow")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_DownArrow)), "Down Arrow")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_LeftArrow)), "Left Arrow")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_RightArrow)), "Right Arrow")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_Home)), "Home")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_End)), "End")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_PageUp)), "Page Up")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_PageDown)), "Page Down")
    }

    func testKeyDisplayNameCoversEditingKeys() {
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_Return)), "Return")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_Tab)), "Tab")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_Escape)), "Escape")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_Delete)), "Delete")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_ForwardDelete)), "Forward Delete")
    }

    func testKeyDisplayNameCoversPunctuationKeys() {
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_ANSI_Comma)), ",")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_ANSI_Period)), ".")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_ANSI_Slash)), "/")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_ANSI_Semicolon)), ";")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_ANSI_Minus)), "-")
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: UInt32(kVK_ANSI_Equal)), "=")
    }

    func testKeyDisplayNameFallsBackForUnknownCodes() {
        XCTAssertEqual(HotkeyBinding.keyDisplayName(for: 9999), "Key 9999")
    }
}
