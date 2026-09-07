import Foundation

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
