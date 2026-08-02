// Small value types keep Settings' async scheduling policy deterministic and
// independently testable without coupling model tests to SwiftUI/AppKit.
struct SettingsRefreshState: Equatable, Sendable {
    private(set) var latestGeneration = 0
    private(set) var hasScheduledRefresh = false
    private(set) var isScheduledRefreshLoading = false
    private(set) var needsFollowUpRefresh = false

    mutating func beginLoad() -> Int {
        latestGeneration &+= 1
        return latestGeneration
    }

    func shouldApply(generation: Int) -> Bool {
        generation == latestGeneration
    }

    mutating func invalidateLoads() {
        latestGeneration &+= 1
    }

    mutating func requestScheduledRefresh() -> Bool {
        guard !hasScheduledRefresh else {
            if isScheduledRefreshLoading {
                needsFollowUpRefresh = true
            }
            return false
        }

        hasScheduledRefresh = true
        return true
    }

    mutating func beginScheduledRefreshPass() {
        precondition(hasScheduledRefresh)
        precondition(!isScheduledRefreshLoading)
        isScheduledRefreshLoading = true
    }

    mutating func finishScheduledRefreshPass() -> Bool {
        precondition(hasScheduledRefresh)
        precondition(isScheduledRefreshLoading)
        isScheduledRefreshLoading = false

        if needsFollowUpRefresh {
            needsFollowUpRefresh = false
            return true
        }

        hasScheduledRefresh = false
        return false
    }
}

struct SettingsMutationState: Equatable, Sendable {
    struct RenameToken: Equatable, Sendable {
        fileprivate let layoutID: String
        fileprivate let name: String
        fileprivate let revision: Int
    }

    struct HotkeyToken: Equatable, Sendable {
        fileprivate let layoutID: String
        fileprivate let hotkey: HotkeyBinding?
        fileprivate let revision: Int
    }

    private(set) var isCreatingLayout = false
    private var latestRenameByLayoutID: [String: RenameToken] = [:]
    private var latestHotkeyByLayoutID: [String: HotkeyToken] = [:]
    private var deletingLayoutIDs: Set<String> = []
    private var revision = 0

    mutating func beginCreate() -> Bool {
        guard !isCreatingLayout else { return false }
        isCreatingLayout = true
        return true
    }

    mutating func finishCreate() {
        isCreatingLayout = false
    }

    mutating func beginRename(layoutID: String, name: String) -> RenameToken? {
        guard !deletingLayoutIDs.contains(layoutID) else { return nil }
        guard latestRenameByLayoutID[layoutID]?.name != name else { return nil }

        revision &+= 1
        let token = RenameToken(layoutID: layoutID, name: name, revision: revision)
        latestRenameByLayoutID[layoutID] = token
        return token
    }

    mutating func finishRename(_ token: RenameToken) {
        guard latestRenameByLayoutID[token.layoutID]?.revision == token.revision else { return }
        latestRenameByLayoutID[token.layoutID] = nil
    }

    mutating func beginDelete(layoutID: String) -> Bool {
        deletingLayoutIDs.insert(layoutID).inserted
    }

    mutating func finishDelete(layoutID: String) {
        deletingLayoutIDs.remove(layoutID)
    }

    mutating func beginHotkey(
        layoutID: String,
        hotkey: HotkeyBinding?
    ) -> HotkeyToken? {
        guard !deletingLayoutIDs.contains(layoutID) else { return nil }
        if let pending = latestHotkeyByLayoutID[layoutID], pending.hotkey == hotkey {
            return nil
        }

        revision &+= 1
        let token = HotkeyToken(layoutID: layoutID, hotkey: hotkey, revision: revision)
        latestHotkeyByLayoutID[layoutID] = token
        return token
    }

    mutating func finishHotkey(_ token: HotkeyToken) {
        guard latestHotkeyByLayoutID[token.layoutID]?.revision == token.revision else { return }
        latestHotkeyByLayoutID[token.layoutID] = nil
    }
}
