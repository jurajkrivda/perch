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

struct Slot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var lastSaved: Date?
    var restoreHotkey: HotkeyBinding?
    /// Distinguishes an intentional lack of a shortcut from `nil` meaning
    /// "use the positional default". Needed when index changes cross the first
    /// nine layouts, where positional defaults stop existing.
    var restoreHotkeyDisabled: Bool
    var windows: [WindowSnapshot]
    /// Display arrangement present when this layout was last saved.
    /// `nil` for layouts saved before schema v3.
    var capturedTopology: DisplayTopologyFingerprint?

    init(
        id: String,
        name: String,
        lastSaved: Date? = nil,
        restoreHotkey: HotkeyBinding? = nil,
        restoreHotkeyDisabled: Bool = false,
        windows: [WindowSnapshot] = [],
        capturedTopology: DisplayTopologyFingerprint? = nil
    ) {
        self.id = id
        self.name = name
        self.lastSaved = lastSaved
        self.restoreHotkey = restoreHotkey
        self.restoreHotkeyDisabled = restoreHotkeyDisabled
        self.windows = windows
        self.capturedTopology = capturedTopology
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lastSaved = try container.decodeIfPresent(Date.self, forKey: .lastSaved)
        restoreHotkey = try container.decodeIfPresent(HotkeyBinding.self, forKey: .restoreHotkey)
        restoreHotkeyDisabled = try container.decodeIfPresent(Bool.self, forKey: .restoreHotkeyDisabled) ?? false
        windows = try container.decode([WindowSnapshot].self, forKey: .windows)
        capturedTopology = try container.decodeIfPresent(
            DisplayTopologyFingerprint.self,
            forKey: .capturedTopology
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case lastSaved
        case restoreHotkey
        case restoreHotkeyDisabled
        case windows
        case capturedTopology
    }

    static let defaultSlots: [Slot] = [
        Slot(id: "work", name: "Work", restoreHotkey: HotkeyBinding.defaultRestore(for: 0)),
        Slot(id: "focus", name: "Focus", restoreHotkey: HotkeyBinding.defaultRestore(for: 1)),
        Slot(id: "meeting", name: "Meeting", restoreHotkey: HotkeyBinding.defaultRestore(for: 2))
    ]
}

enum MatchStrictness: String, Codable, CaseIterable, Sendable {
    case strict
    case fuzzy
    case loose
}

enum AutoRestoreMode: String, Codable, CaseIterable, Sendable {
    case off
    case prompt
    case automatic

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = AutoRestoreMode(rawValue: rawValue) ?? .prompt
    }
}

struct PerchSettings: Codable, Equatable, Sendable {
    var stabilizationTimeout: TimeInterval
    var retryAttempts: Int
    var matchStrictness: MatchStrictness
    var showsMenuBarLabel: Bool
    var opensMissingApplicationsOnRestore: Bool
    var autoRestoreMode: AutoRestoreMode
    var autoRestoreSettleTimeout: TimeInterval
    /// Positional save shortcuts disabled during legacy migration because an
    /// explicit restore shortcut already owns the same binding.
    var disabledDefaultSaveHotkeys: [HotkeyBinding]

    init(
        stabilizationTimeout: TimeInterval = 2.5,
        retryAttempts: Int = 3,
        matchStrictness: MatchStrictness = .fuzzy,
        showsMenuBarLabel: Bool = true,
        opensMissingApplicationsOnRestore: Bool = false,
        autoRestoreMode: AutoRestoreMode = .prompt,
        autoRestoreSettleTimeout: TimeInterval = 10,
        disabledDefaultSaveHotkeys: [HotkeyBinding] = []
    ) {
        self.stabilizationTimeout = stabilizationTimeout
        self.retryAttempts = retryAttempts
        self.matchStrictness = matchStrictness
        self.showsMenuBarLabel = showsMenuBarLabel
        self.opensMissingApplicationsOnRestore = opensMissingApplicationsOnRestore
        self.autoRestoreMode = autoRestoreMode
        self.autoRestoreSettleTimeout = autoRestoreSettleTimeout
        self.disabledDefaultSaveHotkeys = disabledDefaultSaveHotkeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stabilizationTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .stabilizationTimeout) ?? 2.5
        retryAttempts = try container.decodeIfPresent(Int.self, forKey: .retryAttempts) ?? 3
        matchStrictness = try container.decodeIfPresent(MatchStrictness.self, forKey: .matchStrictness) ?? .fuzzy
        showsMenuBarLabel = try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarLabel) ?? true
        opensMissingApplicationsOnRestore = try container.decodeIfPresent(
            Bool.self,
            forKey: .opensMissingApplicationsOnRestore
        ) ?? false
        autoRestoreMode = try container.decodeIfPresent(
            AutoRestoreMode.self,
            forKey: .autoRestoreMode
        ) ?? .prompt
        autoRestoreSettleTimeout = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .autoRestoreSettleTimeout
        ) ?? 10
        disabledDefaultSaveHotkeys = try container.decodeIfPresent(
            [HotkeyBinding].self,
            forKey: .disabledDefaultSaveHotkeys
        ) ?? []
    }
}

struct SlotStoreDocument: Codable, Equatable, Sendable {
    static let currentVersion = 3
    static let retryAttemptsRange = 1...10
    static let stabilizationTimeoutRange: ClosedRange<TimeInterval> = 0...30
    static let autoRestoreSettleTimeoutRange: ClosedRange<TimeInterval> = 0...60

    enum ValidationError: LocalizedError, Equatable, Sendable {
        case invalidVersion(Int)
        case duplicateLayoutID(String)
        case emptyLayoutID
        case emptyLayoutName(String)
        case duplicateWindowID(layoutID: String, windowID: String)
        case emptyWindowID(layoutID: String)
        case emptyBundleIdentifier(layoutID: String, windowID: String)
        case invalidWindowFrame(layoutID: String, windowID: String)
        case invalidDisplayLocalFrame(layoutID: String, windowID: String)
        case retryAttemptsOutOfRange(Int)
        case stabilizationTimeoutOutOfRange(TimeInterval)
        case autoRestoreSettleTimeoutOutOfRange(TimeInterval)
        case disabledRestoreHotkeyHasBinding(String)
        case duplicateDisabledSaveHotkey
        case invalidDisabledSaveHotkey(HotkeyBinding)
        case hotkeyConflict(HotkeyConflict)

        var errorDescription: String? {
            switch self {
            case let .invalidVersion(version):
                "Invalid layout store schema version: \(version)."
            case let .duplicateLayoutID(layoutID):
                "Duplicate layout identifier: \(layoutID)."
            case .emptyLayoutID:
                "Layout identifiers cannot be empty."
            case let .emptyLayoutName(layoutID):
                "Layout \(layoutID) has an empty name."
            case let .duplicateWindowID(layoutID, windowID):
                "Layout \(layoutID) contains duplicate window identifier \(windowID)."
            case let .emptyWindowID(layoutID):
                "Layout \(layoutID) contains an empty window identifier."
            case let .emptyBundleIdentifier(layoutID, windowID):
                "Window \(windowID) in layout \(layoutID) has an empty bundle identifier."
            case let .invalidWindowFrame(layoutID, windowID):
                "Window \(windowID) in layout \(layoutID) has an invalid frame."
            case let .invalidDisplayLocalFrame(layoutID, windowID):
                "Window \(windowID) in layout \(layoutID) has an invalid display-local frame."
            case let .retryAttemptsOutOfRange(attempts):
                "Window retry attempts must be between \(SlotStoreDocument.retryAttemptsRange.lowerBound) and \(SlotStoreDocument.retryAttemptsRange.upperBound), got \(attempts)."
            case let .stabilizationTimeoutOutOfRange(timeout):
                "Display stabilization timeout must be between \(SlotStoreDocument.stabilizationTimeoutRange.lowerBound) and \(SlotStoreDocument.stabilizationTimeoutRange.upperBound) seconds, got \(timeout)."
            case let .autoRestoreSettleTimeoutOutOfRange(timeout):
                "Automatic restore settle timeout must be between \(SlotStoreDocument.autoRestoreSettleTimeoutRange.lowerBound) and \(SlotStoreDocument.autoRestoreSettleTimeoutRange.upperBound) seconds, got \(timeout)."
            case let .disabledRestoreHotkeyHasBinding(layoutID):
                "Layout \(layoutID) cannot have both a disabled and configured restore shortcut."
            case .duplicateDisabledSaveHotkey:
                "The layout store contains a duplicate disabled save shortcut."
            case let .invalidDisabledSaveHotkey(hotkey):
                "The layout store disables an unknown save shortcut: \(hotkey.displayString)."
            case .hotkeyConflict:
                "The layout store contains conflicting keyboard shortcuts."
            }
        }
    }

    var version: Int
    var slots: [Slot]
    var settings: PerchSettings

    init(
        version: Int = Self.currentVersion,
        slots: [Slot] = Slot.defaultSlots,
        settings: PerchSettings = PerchSettings()
    ) {
        self.version = version
        self.slots = slots
        self.settings = settings
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw ValidationError.invalidVersion(version)
        }

        guard Self.retryAttemptsRange.contains(settings.retryAttempts) else {
            throw ValidationError.retryAttemptsOutOfRange(settings.retryAttempts)
        }

        guard settings.stabilizationTimeout.isFinite,
              Self.stabilizationTimeoutRange.contains(settings.stabilizationTimeout)
        else {
            throw ValidationError.stabilizationTimeoutOutOfRange(settings.stabilizationTimeout)
        }

        guard settings.autoRestoreSettleTimeout.isFinite,
              Self.autoRestoreSettleTimeoutRange.contains(settings.autoRestoreSettleTimeout)
        else {
            throw ValidationError.autoRestoreSettleTimeoutOutOfRange(
                settings.autoRestoreSettleTimeout
            )
        }

        let disabledSaveHotkeys = Set(settings.disabledDefaultSaveHotkeys)
        guard disabledSaveHotkeys.count == settings.disabledDefaultSaveHotkeys.count else {
            throw ValidationError.duplicateDisabledSaveHotkey
        }
        let supportedSaveHotkeys = Set((0..<9).compactMap(HotkeyBinding.defaultSave(for:)))
        if let invalidHotkey = disabledSaveHotkeys.first(where: { !supportedSaveHotkeys.contains($0) }) {
            throw ValidationError.invalidDisabledSaveHotkey(invalidHotkey)
        }

        var layoutIDs = Set<String>()
        for slot in slots {
            guard !slot.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyLayoutID
            }
            guard layoutIDs.insert(slot.id).inserted else {
                throw ValidationError.duplicateLayoutID(slot.id)
            }
            guard !slot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyLayoutName(slot.id)
            }
            guard !slot.restoreHotkeyDisabled || slot.restoreHotkey == nil else {
                throw ValidationError.disabledRestoreHotkeyHasBinding(slot.id)
            }

            var windowIDs = Set<String>()
            for window in slot.windows {
                guard !window.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.emptyWindowID(layoutID: slot.id)
                }
                guard windowIDs.insert(window.id).inserted else {
                    throw ValidationError.duplicateWindowID(layoutID: slot.id, windowID: window.id)
                }
                guard !window.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.emptyBundleIdentifier(layoutID: slot.id, windowID: window.id)
                }
                guard Self.isValidWindowFrame(window.frame) else {
                    throw ValidationError.invalidWindowFrame(layoutID: slot.id, windowID: window.id)
                }
                if let displayLocalFrame = window.displayLocalFrame,
                   !Self.isValidWindowFrame(displayLocalFrame) {
                    throw ValidationError.invalidDisplayLocalFrame(layoutID: slot.id, windowID: window.id)
                }
            }
        }

        if let conflict = firstHotkeyConflict() {
            throw ValidationError.hotkeyConflict(conflict)
        }
    }

    /// Persists currently effective positional defaults before inserting or
    /// removing layouts, so the remaining layouts keep the shortcuts users saw.
    mutating func materializeEffectiveRestoreHotkeys() {
        for index in slots.indices where slots[index].restoreHotkey == nil && !slots[index].restoreHotkeyDisabled {
            if let effectiveHotkey = HotkeyBinding.defaultRestore(for: index) {
                slots[index].restoreHotkey = effectiveHotkey
            } else {
                slots[index].restoreHotkeyDisabled = true
            }
        }
    }

    /// Version 1 could create a positional shortcut after a custom restore
    /// shortcut had already claimed that binding. Explicit bindings win;
    /// only the colliding positional default is disconnected.
    mutating func migrateLegacyHotkeyDefaults() {
        let explicitRestoreHotkeys = Set(slots.compactMap(\.restoreHotkey))
        var occupiedRestoreHotkeys = explicitRestoreHotkeys
        var disabledSaveHotkeys = Set(settings.disabledDefaultSaveHotkeys)

        for index in slots.indices {
            if let saveHotkey = HotkeyBinding.defaultSave(for: index),
               explicitRestoreHotkeys.contains(saveHotkey) {
                disabledSaveHotkeys.insert(saveHotkey)
            }
        }

        for index in slots.indices where slots[index].restoreHotkey == nil {
            guard let positionalHotkey = HotkeyBinding.defaultRestore(for: index) else {
                slots[index].restoreHotkeyDisabled = true
                continue
            }

            if occupiedRestoreHotkeys.contains(positionalHotkey) {
                slots[index].restoreHotkeyDisabled = true
            } else {
                slots[index].restoreHotkey = positionalHotkey
                occupiedRestoreHotkeys.insert(positionalHotkey)
            }
        }

        settings.disabledDefaultSaveHotkeys = disabledSaveHotkeys.sorted(by: Self.hotkeySortOrder)
    }

    mutating func reconcileDisabledDefaultSaveHotkeys() {
        let effectiveRestoreHotkeys = Set(slots.indices.compactMap(effectiveRestoreHotkey(at:)))
        settings.disabledDefaultSaveHotkeys = settings.disabledDefaultSaveHotkeys
            .filter(effectiveRestoreHotkeys.contains)
            .sorted(by: Self.hotkeySortOrder)
    }

    func firstHotkeyConflict() -> HotkeyConflict? {
        for slot in slots {
            guard let effectiveHotkey = effectiveRestoreHotkey(for: slot.id) else {
                continue
            }
            if let conflict = hotkeyConflict(for: effectiveHotkey, layoutID: slot.id) {
                return conflict
            }
        }

        return nil
    }

    func hotkeyConflict(for proposedHotkey: HotkeyBinding?, layoutID: String) -> HotkeyConflict? {
        guard
            let layoutIndex = slots.firstIndex(where: { $0.id == layoutID }),
            let effectiveHotkey = proposedHotkey ?? HotkeyBinding.defaultRestore(for: layoutIndex)
        else {
            return nil
        }

        for (index, slot) in slots.enumerated() {
            if effectiveSaveHotkey(at: index) == effectiveHotkey {
                return HotkeyConflict(action: .save, layoutID: slot.id, layoutName: slot.name)
            }

            guard slot.id != layoutID else {
                continue
            }

            if effectiveRestoreHotkey(at: index) == effectiveHotkey {
                return HotkeyConflict(action: .restore, layoutID: slot.id, layoutName: slot.name)
            }
        }

        return nil
    }

    func effectiveRestoreHotkey(for layoutID: String) -> HotkeyBinding? {
        guard let index = slots.firstIndex(where: { $0.id == layoutID }) else {
            return nil
        }

        return effectiveRestoreHotkey(at: index)
    }

    func effectiveRestoreHotkey(at index: Int) -> HotkeyBinding? {
        guard slots.indices.contains(index), !slots[index].restoreHotkeyDisabled else {
            return nil
        }

        return slots[index].restoreHotkey ?? HotkeyBinding.defaultRestore(for: index)
    }

    func effectiveSaveHotkey(at index: Int) -> HotkeyBinding? {
        guard let hotkey = HotkeyBinding.defaultSave(for: index),
              !settings.disabledDefaultSaveHotkeys.contains(hotkey)
        else {
            return nil
        }

        return hotkey
    }

    private static func isValidWindowFrame(_ frame: CodableRect) -> Bool {
        frame.x.isFinite &&
            frame.y.isFinite &&
            frame.width.isFinite &&
            frame.height.isFinite &&
            frame.width > 0 &&
            frame.height > 0
    }

    private static func hotkeySortOrder(_ lhs: HotkeyBinding, _ rhs: HotkeyBinding) -> Bool {
        lhs.keyCode == rhs.keyCode
            ? lhs.modifiers < rhs.modifiers
            : lhs.keyCode < rhs.keyCode
    }
}
