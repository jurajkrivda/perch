import AppKit
import CoreGraphics
import Foundation

extension Notification.Name {
    static let perchDocumentDidChange = Notification.Name("PerchDocumentDidChange")
}

@MainActor
final class SlotEngine {
    let store: SlotStore
    let restorer: LayoutWindowRestorer
    let windowMover: any WindowMoving
    let snapshotter: any WindowSnapshotting
    let accessibilityTrusted: @MainActor () -> Bool
    let displayProvider: @MainActor () -> [DisplayInfo]
    let capturedTopologyProvider: @MainActor () -> DisplayTopologyFingerprint?
    let restoreSession = RestoreSession()
    var activeRestoreTask: Task<SlotOperationResult, Error>?
    private var isPerformingWindowOperation = false

    init(
        store: SlotStore,
        snapshotter: any WindowSnapshotting = WindowSnapshotter(),
        windowMover: any WindowMoving = WindowMover(),
        applicationLauncher: any ApplicationLaunching = WorkspaceApplicationLauncher(),
        accessibilityTrusted: @escaping @MainActor () -> Bool = { AccessibilityManager.isTrusted() },
        displayProvider: @escaping @MainActor () -> [DisplayInfo] = { DisplayManager.currentDisplays() },
        capturedTopologyProvider: @escaping @MainActor () -> DisplayTopologyFingerprint? = {
            DisplayManager.currentTopologyFingerprint()
        },
        launchRetryTimeout: TimeInterval = 8,
        launchRetryIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        self.restorer = LayoutWindowRestorer(
            windowMover: windowMover, applicationLauncher: applicationLauncher,
            displayProvider: displayProvider, launchRetryTimeout: launchRetryTimeout,
            launchRetryIntervalNanoseconds: launchRetryIntervalNanoseconds
        )
        self.store = store
        self.windowMover = windowMover
        self.snapshotter = snapshotter
        self.accessibilityTrusted = accessibilityTrusted
        self.displayProvider = displayProvider
        self.capturedTopologyProvider = capturedTopologyProvider
    }

    static func live() throws -> SlotEngine {
        try SlotEngine(store: SlotStore())
    }

    private static var sharedEngine: SlotEngine?

    static func shared() throws -> SlotEngine {
        if let sharedEngine {
            return sharedEngine
        }

        let engine = try SlotEngine.live()
        sharedEngine = engine
        return engine
    }

    func createLayout(name: String) async throws -> Slot {
        let slot: Slot
        do {
            slot = try await store.createLayout(name: validatedLayoutName(name))
        } catch SlotStoreDocument.ValidationError.hotkeyConflict(let conflict) {
            throw SlotEngineError.hotkeyConflict(conflict)
        }
        notifyDocumentDidChange()

        AppLog.persistence.info("Created layout \(slot.id, privacy: .public)")

        return slot
    }

    func renameLayout(id: String, name: String) async throws {
        try await store.renameLayout(id: id, name: validatedLayoutName(name))
        notifyDocumentDidChange()

        AppLog.persistence.info("Renamed layout \(id, privacy: .public)")
    }

    func deleteLayout(id: String) async throws {
        try await store.deleteLayout(id: id)
        notifyDocumentDidChange()

        AppLog.persistence.info("Deleted layout \(id, privacy: .public)")
    }

    func setRestoreHotkey(layoutID: String, hotkey: HotkeyBinding?) async throws {
        try await store.update { document in
            let slotIndex = try Self.index(of: layoutID, in: document)

            if let conflict = document.hotkeyConflict(for: hotkey, layoutID: layoutID) {
                throw SlotEngineError.hotkeyConflict(conflict)
            }

            document.slots[slotIndex].restoreHotkey = hotkey
            document.slots[slotIndex].restoreHotkeyDisabled = false
        }
        notifyDocumentDidChange()

        AppLog.hotkeys.info("Updated restore hotkey for layout \(layoutID, privacy: .public)")
    }

    func updateSettings(_ update: @Sendable (inout PerchSettings) -> Void) async throws -> PerchSettings {
        let document = try await store.update { document in
            update(&document.settings)
        }
        notifyDocumentDidChange()

        return document.settings
    }

    func save(slotIndex: Int) async throws -> SlotOperationResult {
        let document = try await store.load()
        let slotID = try slotID(for: slotIndex, in: document)
        return try await save(slotID: slotID)
    }

    func save(slotID: String) async throws -> SlotOperationResult {
        try await performExclusiveWindowOperation {
            let capture = try await captureLayoutWindows()
            let snapshots = capture.windows
            let capturedTopology = capture.topology
            let savedAt = Date()

            let document = try await store.update { document in
                let slotIndex = try Self.index(of: slotID, in: document)
                document.slots[slotIndex].windows = snapshots
                document.slots[slotIndex].lastSaved = savedAt
                document.slots[slotIndex].capturedTopology = capturedTopology
            }
            notifyDocumentDidChange()

            guard let slot = document.slots.first(where: { $0.id == slotID }) else {
                throw SlotEngineError.slotNotFound(slotID)
            }

            AppLog.persistence.info("Saved \(snapshots.count) windows to slot \(slot.id, privacy: .public)")

            return SlotOperationResult(
                slotID: slot.id,
                slotName: slot.name,
                succeeded: snapshots.count,
                total: snapshots.count
            )
        }
    }

    func currentDocument() async throws -> SlotStoreDocument {
        try await store.load()
    }

    func recoveryNotice() async throws -> StoreRecoveryNotice? {
        try await store.recoveryNotice()
    }

    func acknowledgeRecoveryNotice(_ notice: StoreRecoveryNotice) async throws {
        try await store.acknowledgeRecoveryNotice(notice)
        notifyDocumentDidChange()
    }

    /// Serializes window-touching operations: overlapping saves/restores would move
    /// the same windows twice and interleave their reports, so later requests are
    /// rejected instead of queued (hotkey auto-repeat would otherwise pile up).
    func performExclusiveWindowOperation<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard !isPerformingWindowOperation else {
            throw SlotEngineError.operationInProgress
        }

        isPerformingWindowOperation = true
        defer { isPerformingWindowOperation = false }

        return try await operation()
    }

    private func slotID(for slotIndex: Int, in document: SlotStoreDocument) throws -> String {
        guard document.slots.indices.contains(slotIndex) else {
            throw SlotEngineError.slotNotFound(String(slotIndex))
        }

        return document.slots[slotIndex].id
    }

    nonisolated static func index(of slotID: String, in document: SlotStoreDocument) throws -> Int {
        guard let index = document.slots.firstIndex(where: { $0.id == slotID }) else {
            throw SlotEngineError.slotNotFound(slotID)
        }

        return index
    }

    func validatedLayoutName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            throw SlotEngineError.invalidLayoutName
        }

        return trimmedName
    }

    func notifyDocumentDidChange() {
        NotificationCenter.default.post(name: .perchDocumentDidChange, object: self)
    }

    func validateRestorePreflight(_ preflight: RestorePreflight?, document: SlotStoreDocument) throws {
        try Task.checkCancellation()
        guard preflight?(document) ?? true else {
            throw SlotEngineError.restorePreflightRejected
        }
    }

}
