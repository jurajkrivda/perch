import Foundation

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
    /// Explicit choices keyed by display identity, independent of save order.
    var preferredLayoutsByTopology: [String: String]
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
        disabledDefaultSaveHotkeys: [HotkeyBinding] = [],
        preferredLayoutsByTopology: [String: String] = [:]
    ) {
        self.stabilizationTimeout = stabilizationTimeout
        self.retryAttempts = retryAttempts
        self.matchStrictness = matchStrictness
        self.showsMenuBarLabel = showsMenuBarLabel
        self.opensMissingApplicationsOnRestore = opensMissingApplicationsOnRestore
        self.autoRestoreMode = autoRestoreMode
        self.autoRestoreSettleTimeout = autoRestoreSettleTimeout
        self.disabledDefaultSaveHotkeys = disabledDefaultSaveHotkeys
        self.preferredLayoutsByTopology = preferredLayoutsByTopology
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredLayoutsByTopology = try container.decodeIfPresent(
            [String: String].self, forKey: .preferredLayoutsByTopology
        ) ?? [:]
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
