import Foundation

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

    mutating func reconcileLayoutPreferences() {
        settings.preferredLayoutsByTopology = settings.preferredLayoutsByTopology.filter { identity, layoutID in
            slots.contains {
                $0.id == layoutID && !$0.windows.isEmpty && $0.capturedTopology?.identity == identity
            }
        }
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
