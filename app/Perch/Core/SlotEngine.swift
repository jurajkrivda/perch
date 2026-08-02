import AppKit
import CoreGraphics
import Foundation

extension Notification.Name {
    static let perchDocumentDidChange = Notification.Name("PerchDocumentDidChange")
}

struct SlotOperationResult: Equatable, Sendable {
    let slotID: String
    let slotName: String
    let succeeded: Int
    let total: Int
    let details: [RestoreWindowReport]

    init(
        slotID: String,
        slotName: String,
        succeeded: Int,
        total: Int,
        details: [RestoreWindowReport] = []
    ) {
        self.slotID = slotID
        self.slotName = slotName
        self.succeeded = succeeded
        self.total = total
        self.details = details
    }

    var skipped: Int {
        max(total - succeeded, 0)
    }

    var openedAppCount: Int {
        Set(details.compactMap { $0.didLaunchApplication ? $0.bundleIdentifier : nil }).count
    }

    /// Isolated to the main actor so it can render in the current UI language;
    /// skipped windows are implied by the succeeded/total pair and detailed in
    /// the restore report rows.
    @MainActor
    var restoreSummary: String {
        guard total > 0 else {
            return L10n.text(.noWindowsSaved)
        }

        return L10n.restoreSummary(
            succeeded: succeeded,
            total: total,
            openedAppCount: openedAppCount
        )
    }
}

enum RestoreWindowOutcome: Equatable, Sendable {
    case restored
    case launchedAndRestored
    case appNotInstalled
    case launchFailed
    case appNotRunning
    case windowNotFound
    case ambiguousWindowMatch
    case frameWriteFailed
    case skipped

    var isSuccess: Bool {
        switch self {
        case .restored, .launchedAndRestored:
            true
        case .appNotInstalled,
             .launchFailed,
             .appNotRunning,
             .windowNotFound,
             .ambiguousWindowMatch,
             .frameWriteFailed,
             .skipped:
            false
        }
    }
}

struct RestoreWindowReport: Equatable, Identifiable, Sendable {
    let id: String
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let outcome: RestoreWindowOutcome
    let didLaunchApplication: Bool
    let matchReason: WindowMoveMatchReason?
    let message: String?

    var isSuccess: Bool {
        outcome.isSuccess
    }
}

enum ApplicationLaunchResult: Equatable, Sendable {
    case launched
    case alreadyRunning
    case notInstalled
    case failed(String)
}

@MainActor
protocol ApplicationLaunching {
    func launchApplication(bundleIdentifier: String) async -> ApplicationLaunchResult
}

protocol WindowSnapshotting: Sendable {
    func captureCurrentWindows() async throws -> [WindowSnapshot]
}

extension WindowSnapshotter: WindowSnapshotting {}

protocol WindowMoving: Sendable {
    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int,
        strictness: MatchStrictness
    ) async throws -> CGRect

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) async throws -> [WindowBatchMoveResult]
}

extension WindowMoving {
    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) async throws -> [WindowBatchMoveResult] {
        try Task.checkCancellation()
        var results: [WindowBatchMoveResult] = []
        results.reserveCapacity(requests.count)

        for request in requests {
            try Task.checkCancellation()
            do {
                let restoredFrame: CGRect
                if request.shouldMove {
                    restoredFrame = try await move(
                        snapshot: request.snapshot,
                        to: request.frame,
                        attempts: request.attempts,
                        strictness: strictness
                    )
                } else {
                    restoredFrame = request.frame
                }
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: restoredFrame,
                    matchReason: nil,
                    error: nil,
                    reservation: request.reservation
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch WindowMoverError.accessibilityPermissionMissing {
                throw WindowMoverError.accessibilityPermissionMissing
            } catch WindowMoverError.appNotRunning {
                throw WindowMoverError.appNotRunning(bundleIdentifier: bundleIdentifier)
            } catch let error as WindowMoverError {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: error
                ))
            } catch {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: .frameWriteFailed
                ))
            }
        }

        return results
    }
}

extension WindowMover: WindowMoving {}

typealias RestorePreflight = @MainActor @Sendable () -> Bool

struct WorkspaceApplicationLauncher: ApplicationLaunching {
    func launchApplication(bundleIdentifier: String) async -> ApplicationLaunchResult {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            return .alreadyRunning
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return .notInstalled
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        // Resolved before the continuation: the completion handler runs off the
        // main actor and cannot read the localization state.
        let missingApplicationMessage = L10n.text(.launchDidNotReturnApp)

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(returning: .failed(error.localizedDescription))
                } else if application != nil {
                    continuation.resume(returning: .launched)
                } else {
                    continuation.resume(returning: .failed(missingApplicationMessage))
                }
            }
        }
    }
}

enum SlotEngineError: LocalizedError {
    case slotNotFound(String)
    case invalidLayoutName
    case operationInProgress
    case restorePreflightRejected
    case hotkeyConflict(HotkeyConflict)

    var errorDescription: String? {
        switch self {
        case let .slotNotFound(slotID):
            "Slot not found: \(slotID)"
        case .invalidLayoutName:
            "Layout name cannot be empty."
        case .operationInProgress:
            "Another save or restore is already running."
        case .restorePreflightRejected:
            "The display environment changed before automatic restore could begin."
        case let .hotkeyConflict(conflict):
            switch conflict.action {
            case .save:
                "Shortcut is already used to save \(conflict.layoutName)."
            case .restore:
                "Shortcut is already used to restore \(conflict.layoutName)."
            }
        }
    }
}

@MainActor
final class SlotEngine {
    private let store: SlotStore
    private let snapshotter: any WindowSnapshotting
    private let windowMover: any WindowMoving
    private let applicationLauncher: any ApplicationLaunching
    private let accessibilityTrusted: @MainActor () -> Bool
    private let displayProvider: @MainActor () -> [DisplayInfo]
    private let capturedTopologyProvider: @MainActor () -> DisplayTopologyFingerprint?
    private let launchRetryTimeout: TimeInterval
    private let launchRetryIntervalNanoseconds: UInt64
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
        self.store = store
        self.snapshotter = snapshotter
        self.windowMover = windowMover
        self.applicationLauncher = applicationLauncher
        self.accessibilityTrusted = accessibilityTrusted
        self.displayProvider = displayProvider
        self.capturedTopologyProvider = capturedTopologyProvider
        self.launchRetryTimeout = launchRetryTimeout
        self.launchRetryIntervalNanoseconds = launchRetryIntervalNanoseconds
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
            let snapshots = try await snapshotter.captureCurrentWindows()
            let capturedTopology = capturedTopologyProvider()
            if capturedTopology == nil {
                AppLog.display.warning(
                    "Saved layout without automatic topology matching because the display identity is incomplete"
                )
            }
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

    func restore(
        slotID: String,
        preflight: RestorePreflight? = nil
    ) async throws -> SlotOperationResult {
        try await performExclusiveWindowOperation {
            try Task.checkCancellation()
            let document = try await store.load()
            try Task.checkCancellation()
            let slotIndex = try Self.index(of: slotID, in: document)
            let slot = document.slots[slotIndex]

            guard accessibilityTrusted() else {
                throw WindowMoverError.accessibilityPermissionMissing
            }

            await DisplayStabilizer.shared.waitForStable(
                timeout: document.settings.stabilizationTimeout
            )
            try validateRestorePreflight(preflight)

            var reportsBySnapshotID: [String: RestoreWindowReport] = [:]

            for group in snapshotGroupsPreservingOrder(slot.windows) {
                let reports = try await restore(
                    snapshots: group.snapshots,
                    settings: document.settings,
                    displays: displayProvider()
                )
                for report in reports {
                    reportsBySnapshotID[report.id] = report
                }
            }

            let reports = slot.windows.compactMap { reportsBySnapshotID[$0.id] }
            let restored = reports.filter(\.isSuccess).count

            AppLog.windows.info("Restored \(restored) of \(slot.windows.count) windows from slot \(slot.id, privacy: .public)")

            return SlotOperationResult(
                slotID: slot.id,
                slotName: slot.name,
                succeeded: restored,
                total: slot.windows.count,
                details: reports
            )
        }
    }

    func currentDocument() async throws -> SlotStoreDocument {
        try await store.load()
    }

    /// Serializes window-touching operations: overlapping saves/restores would move
    /// the same windows twice and interleave their reports, so later requests are
    /// rejected instead of queued (hotkey auto-repeat would otherwise pile up).
    private func performExclusiveWindowOperation<T: Sendable>(
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

    private nonisolated static func index(of slotID: String, in document: SlotStoreDocument) throws -> Int {
        guard let index = document.slots.firstIndex(where: { $0.id == slotID }) else {
            throw SlotEngineError.slotNotFound(slotID)
        }

        return index
    }

    private func validatedLayoutName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            throw SlotEngineError.invalidLayoutName
        }

        return trimmedName
    }

    private func notifyDocumentDidChange() {
        NotificationCenter.default.post(name: .perchDocumentDidChange, object: self)
    }

    private func restore(
        snapshots: [WindowSnapshot],
        settings: PerchSettings,
        displays: [DisplayInfo]
    ) async throws -> [RestoreWindowReport] {
        guard let bundleIdentifier = snapshots.first?.bundleIdentifier else {
            return []
        }

        let requests = moveRequests(for: snapshots, settings: settings, displays: displays)

        do {
            let results = try await windowMover.move(
                requests: requests,
                bundleIdentifier: bundleIdentifier,
                strictness: settings.matchStrictness
            )

            return reports(
                for: snapshots,
                moveResults: results,
                didLaunchApplication: false
            )
        } catch WindowMoverError.accessibilityPermissionMissing {
            throw WindowMoverError.accessibilityPermissionMissing
        } catch WindowMoverError.appNotRunning {
            guard settings.opensMissingApplicationsOnRestore else {
                return reportsForClosedApplication(snapshots)
            }

            return try await launchAndRestore(
                snapshots: snapshots,
                settings: settings
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return snapshots.map {
                reportForRestoreFailure(snapshot: $0, error: error)
            }
        }
    }

    private func launchAndRestore(
        snapshots: [WindowSnapshot],
        settings: PerchSettings
    ) async throws -> [RestoreWindowReport] {
        guard let bundleIdentifier = snapshots.first?.bundleIdentifier else {
            return []
        }

        let launchResult = await applicationLauncher.launchApplication(bundleIdentifier: bundleIdentifier)

        switch launchResult {
        case .launched, .alreadyRunning:
            let results = try await retryRestoreAfterLaunch(
                snapshots: snapshots,
                bundleIdentifier: bundleIdentifier,
                settings: settings
            )

            return reports(
                for: snapshots,
                moveResults: results,
                didLaunchApplication: launchResult == .launched
            )

        case .notInstalled:
            return snapshots.map { snapshot in
                report(
                    for: snapshot,
                    outcome: .appNotInstalled,
                    didLaunchApplication: false,
                    matchReason: nil,
                    message: L10n.text(.applicationNotInstalled)
                )
            }

        case let .failed(message):
            return snapshots.map { snapshot in
                report(
                    for: snapshot,
                    outcome: .launchFailed,
                    didLaunchApplication: false,
                    matchReason: nil,
                    message: message
                )
            }
        }
    }

    private func retryRestoreAfterLaunch(
        snapshots: [WindowSnapshot],
        bundleIdentifier: String,
        settings: PerchSettings
    ) async throws -> [WindowBatchMoveResult] {
        let deadline = Date().addingTimeInterval(launchRetryTimeout)
        var successfulSnapshotIDs = Set<String>()
        var reservationsBySnapshotID: [String: WindowCandidateReservation] = [:]
        var previousDisplayTopology: DisplayTopologyFingerprint?
        var hasPendingTopologyRemap = false
        var latestResultsBySnapshotID = Dictionary(snapshots.map { snapshot in
            (snapshot.id, WindowBatchMoveResult(
                snapshotID: snapshot.id,
                restoredFrame: nil,
                matchReason: nil,
                error: .windowNotFound(
                    bundleIdentifier: snapshot.bundleIdentifier,
                    title: snapshot.windowTitle
                )
            ))
        }, uniquingKeysWith: { first, _ in first })

        while true {
            // Re-read the display topology on every launch retry. App startup can
            // overlap docking or login display restoration, and target frames
            // derived before launch may already be stale when the window appears.
            let displays = displayProvider()
            let displayTopology = DisplayTopologyFingerprint(displays: displays)
            if let previousDisplayTopology, previousDisplayTopology != displayTopology {
                // A window that was correct for the previous topology is no
                // longer a completed restore. Keep its exact live reservation,
                // but remap every snapshot once for this new topology.
                successfulSnapshotIDs.removeAll()
                for snapshot in snapshots {
                    latestResultsBySnapshotID[snapshot.id] = WindowBatchMoveResult(
                        snapshotID: snapshot.id,
                        restoredFrame: nil,
                        matchReason: nil,
                        error: .windowNotFound(
                            bundleIdentifier: snapshot.bundleIdentifier,
                            title: snapshot.windowTitle
                        ),
                        reservation: reservationsBySnapshotID[snapshot.id]
                    )
                }
                hasPendingTopologyRemap = false
            }
            previousDisplayTopology = displayTopology

            var requests = moveRequests(
                for: snapshots,
                settings: settings,
                displays: displays
            )
            for index in requests.indices {
                let snapshotID = requests[index].snapshot.id
                requests[index].reservation = reservationsBySnapshotID[snapshotID]
                requests[index].shouldMove = !successfulSnapshotIDs.contains(snapshotID)
            }

            do {
                let results = try await windowMover.move(
                    requests: requests,
                    bundleIdentifier: bundleIdentifier,
                    strictness: settings.matchStrictness
                )
                for result in results {
                    // A completed window remains successful even if a later
                    // reservation-only pass cannot rediscover it transiently.
                    if successfulSnapshotIDs.contains(result.snapshotID), !result.isSuccess {
                        continue
                    }

                    latestResultsBySnapshotID[result.snapshotID] = result
                    if result.isSuccess {
                        successfulSnapshotIDs.insert(result.snapshotID)
                        if let reservation = result.reservation {
                            reservationsBySnapshotID[result.snapshotID] = reservation
                        }
                    }
                }

                let latestResults = snapshots.compactMap { latestResultsBySnapshotID[$0.id] }
                if !resultsContainRetryableLaunchMiss(latestResults) {
                    // The topology can change while AX is moving the final
                    // window. Confirm it again before declaring completion so
                    // that generation receives one reserved remap as well.
                    let confirmedTopology = DisplayTopologyFingerprint(
                        displays: displayProvider()
                    )
                    if confirmedTopology == displayTopology {
                        return latestResults
                    }
                    hasPendingTopologyRemap = true
                }
            } catch WindowMoverError.accessibilityPermissionMissing {
                throw WindowMoverError.accessibilityPermissionMissing
            } catch WindowMoverError.appNotRunning {
                for snapshot in snapshots where !successfulSnapshotIDs.contains(snapshot.id) {
                    latestResultsBySnapshotID[snapshot.id] = WindowBatchMoveResult(
                        snapshotID: snapshot.id,
                        restoredFrame: nil,
                        matchReason: nil,
                        error: .windowNotFound(
                            bundleIdentifier: snapshot.bundleIdentifier,
                            title: snapshot.windowTitle
                        )
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                for snapshot in snapshots where !successfulSnapshotIDs.contains(snapshot.id) {
                    latestResultsBySnapshotID[snapshot.id] = WindowBatchMoveResult(
                        snapshotID: snapshot.id,
                        restoredFrame: nil,
                        matchReason: nil,
                        error: .frameWriteFailed
                    )
                }

                return snapshots.compactMap { latestResultsBySnapshotID[$0.id] }
            }

            guard Date() < deadline || hasPendingTopologyRemap else {
                return snapshots.compactMap { latestResultsBySnapshotID[$0.id] }
            }

            try await Task.sleep(nanoseconds: launchRetryIntervalNanoseconds)
        }
    }

    private func validateRestorePreflight(_ preflight: RestorePreflight?) throws {
        try Task.checkCancellation()
        guard preflight?() ?? true else {
            throw SlotEngineError.restorePreflightRejected
        }
    }

    private func reportForRestoreFailure(
        snapshot: WindowSnapshot,
        error: Error,
        didLaunchApplication: Bool = false,
        matchReason: WindowMoveMatchReason? = nil
    ) -> RestoreWindowReport {
        let outcome: RestoreWindowOutcome

        switch error {
        case WindowMoverError.windowNotFound:
            outcome = .windowNotFound
        case WindowMoverError.ambiguousWindowMatch:
            outcome = .ambiguousWindowMatch
        case WindowMoverError.appNotRunning:
            outcome = .appNotRunning
        case WindowMoverError.frameWriteFailed, WindowMoverError.frameReadFailed, WindowMoverError.invalidFrame:
            outcome = .frameWriteFailed
        default:
            outcome = .skipped
        }

        AppLog.windows.warning(
            "Skipping restore for \(snapshot.bundleIdentifier, privacy: .public): \(self.restoreLogDescription(for: error), privacy: .public)"
        )

        return report(
            for: snapshot,
            outcome: outcome,
            didLaunchApplication: didLaunchApplication,
            matchReason: matchReason,
            message: LocalizedErrorMessages.message(for: error)
        )
    }

    private func reportsForClosedApplication(_ snapshots: [WindowSnapshot]) -> [RestoreWindowReport] {
        snapshots.map { snapshot in
            AppLog.windows.info(
                "Skipping restore for \(snapshot.bundleIdentifier, privacy: .public): app closed; auto-open disabled"
            )

            return report(
                for: snapshot,
                outcome: .appNotRunning,
                didLaunchApplication: false,
                matchReason: nil,
                message: L10n.text(.applicationClosed)
            )
        }
    }

    private func report(
        for snapshot: WindowSnapshot,
        outcome: RestoreWindowOutcome,
        didLaunchApplication: Bool,
        matchReason: WindowMoveMatchReason?,
        message: String?
    ) -> RestoreWindowReport {
        RestoreWindowReport(
            id: snapshot.id,
            bundleIdentifier: snapshot.bundleIdentifier,
            appName: applicationDisplayName(for: snapshot.bundleIdentifier),
            windowTitle: snapshot.windowTitle,
            outcome: outcome,
            didLaunchApplication: didLaunchApplication,
            matchReason: matchReason,
            message: message
        )
    }

    private func restoreLogDescription(for error: Error) -> String {
        switch error {
        case WindowMoverError.windowNotFound:
            "window not found"
        case WindowMoverError.ambiguousWindowMatch:
            "ambiguous window match"
        case WindowMoverError.frameWriteFailed:
            "frame write failed"
        case WindowMoverError.frameReadFailed:
            "frame read failed"
        case WindowMoverError.invalidFrame:
            "invalid frame"
        case WindowMoverError.appNotRunning:
            "app not running"
        case WindowMoverError.accessibilityPermissionMissing:
            "accessibility permission missing"
        default:
            "restore failed"
        }
    }

    private func applicationDisplayName(for bundleIdentifier: String) -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }

        if let bundle = Bundle(url: appURL) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !displayName.isEmpty {
                return displayName
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }

        return appURL.deletingPathExtension().lastPathComponent
    }

    private func snapshotGroupsPreservingOrder(_ snapshots: [WindowSnapshot]) -> [(bundleIdentifier: String, snapshots: [WindowSnapshot])] {
        var order: [String] = []
        var groups: [String: [WindowSnapshot]] = [:]

        for snapshot in snapshots {
            if groups[snapshot.bundleIdentifier] == nil {
                order.append(snapshot.bundleIdentifier)
                groups[snapshot.bundleIdentifier] = []
            }
            groups[snapshot.bundleIdentifier]?.append(snapshot)
        }

        return order.compactMap { bundleIdentifier in
            guard let snapshots = groups[bundleIdentifier] else {
                return nil
            }

            return (bundleIdentifier, snapshots)
        }
    }

    private func moveRequests(
        for snapshots: [WindowSnapshot],
        settings: PerchSettings,
        displays: [DisplayInfo]
    ) -> [WindowBatchMoveRequest] {
        snapshots.map { snapshot in
            WindowBatchMoveRequest(
                snapshot: snapshot,
                frame: Self.targetFrame(for: snapshot, displays: displays),
                attempts: settings.retryAttempts
            )
        }
    }

    private func reports(
        for snapshots: [WindowSnapshot],
        moveResults: [WindowBatchMoveResult],
        didLaunchApplication: Bool
    ) -> [RestoreWindowReport] {
        let resultsBySnapshotID = Dictionary(
            moveResults.map { ($0.snapshotID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return snapshots.map { snapshot in
            guard let result = resultsBySnapshotID[snapshot.id] else {
                return reportForRestoreFailure(
                    snapshot: snapshot,
                    error: WindowMoverError.windowNotFound(
                        bundleIdentifier: snapshot.bundleIdentifier,
                        title: snapshot.windowTitle
                    ),
                    didLaunchApplication: didLaunchApplication
                )
            }

            if let error = result.error {
                return reportForRestoreFailure(
                    snapshot: snapshot,
                    error: error,
                    didLaunchApplication: didLaunchApplication,
                    matchReason: result.matchReason
                )
            }

            return report(
                for: snapshot,
                outcome: didLaunchApplication ? .launchedAndRestored : .restored,
                didLaunchApplication: didLaunchApplication,
                matchReason: result.matchReason,
                message: nil
            )
        }
    }

    private func resultsContainRetryableLaunchMiss(_ results: [WindowBatchMoveResult]) -> Bool {
        results.contains { result in
            switch result.error {
            case .some(.windowNotFound), .some(.ambiguousWindowMatch):
                return true
            default:
                return false
            }
        }
    }

    nonisolated static func targetFrame(for snapshot: WindowSnapshot, displays: [DisplayInfo]) -> CGRect {
        let savedFrame = snapshot.frame.cgRect

        guard let displayLocalFrame = snapshot.displayLocalFrame?.cgRect else {
            return rescuedFrame(savedFrame, on: DisplayManager.display(containing: savedFrame, in: displays))
        }

        let display = snapshot.displayUUID.flatMap { DisplayManager.display(withUUID: $0, in: displays) }
            ?? DisplayManager.display(containing: savedFrame, in: displays)

        guard let display else {
            return savedFrame
        }

        let globalFrame = displayLocalFrame.offsetBy(
            dx: display.bounds.origin.x,
            dy: display.bounds.origin.y
        )

        return rescuedFrame(globalFrame, on: display)
    }

    /// Restores faithfully whenever the frame is at least partially visible on its display;
    /// clamps into the display only when the window would otherwise be completely offscreen.
    private nonisolated static func rescuedFrame(_ frame: CGRect, on display: DisplayInfo?) -> CGRect {
        guard let display, !display.bounds.isEmpty else {
            return frame
        }

        guard !display.bounds.intersects(frame) else {
            return frame
        }

        return frame.clamped(to: display.bounds)
    }
}
