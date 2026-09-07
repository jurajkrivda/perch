import Foundation

extension SlotEngine {
    func restore(slotID: String, preflight: RestorePreflight? = nil) async throws -> SlotOperationResult {
        try await managedRestore {
            try await self.restoreSavedLayout(slotID: slotID, preflight: preflight)
        }
    }

    func retryLastRestore(windowIDs: Set<String>? = nil, openApplications: Bool = false) async throws -> SlotOperationResult {
        guard restoreSession.canRetry, let slot = restoreSession.layout,
              let result = restoreSession.result else { throw SlotEngineError.layoutChangedSinceRestore }
        let failedIDs = Set(result.details.filter { !$0.isSuccess }.map(\.id))
        let retryIDs = windowIDs.map { $0.intersection(failedIDs) } ?? failedIDs
        guard !retryIDs.isEmpty else { return result }
        return try await managedRestore {
            try await self.restoreSavedLayout(
                slotID: slot.id, expectedSlot: slot, retryIDs: retryIDs, openApplications: openApplications
            )
        }
    }

    func cancelRestore() {
        restoreSession.cancelling()
        activeRestoreTask?.cancel()
    }

    private func managedRestore(
        _ operation: @escaping @MainActor @Sendable () async throws -> SlotOperationResult
    ) async throws -> SlotOperationResult {
        try await performExclusiveWindowOperation {
            try Task.checkCancellation()
            restoreSession.prepare()
            let task = Task { try await operation() }
            activeRestoreTask = task
            defer { activeRestoreTask = nil }
            return try await withTaskCancellationHandler {
                do { return try await task.value }
                catch {
                    if restoreSession.isRunning { restoreSession.endPreparation(error: error) }
                    throw error
                }
            } onCancel: {
                task.cancel()
            }
        }
    }

    private func restoreSavedLayout(
        slotID: String, preflight: RestorePreflight? = nil,
        expectedSlot: Slot? = nil, retryIDs: Set<String>? = nil,
        openApplications: Bool = false
    ) async throws -> SlotOperationResult {
        var document = try await store.load()
        guard accessibilityTrusted() else { throw WindowMoverError.accessibilityPermissionMissing }
        await DisplayStabilizer.shared.waitForStable(timeout: document.settings.stabilizationTimeout)
        // Read again for every entry point, including a retry from an old report.
        document = try await store.load()
        try validateRestorePreflight(preflight, document: document)
        let slot = document.slots[try Self.index(of: slotID, in: document)]
        if let expectedSlot {
            guard expectedSlot.windows == slot.windows, expectedSlot.capturedTopology == slot.capturedTopology else {
                throw SlotEngineError.layoutChangedSinceRestore
            }
            guard restoreSession.topology == capturedTopologyProvider() else {
                throw SlotEngineError.displayConfigurationChanged
            }
        }
        var settings = document.settings
        if openApplications { settings.opensMissingApplicationsOnRestore = true }
        let previousResult = restoreSession.result
        let previousReservations = restoreSession.reservations
        restoreSession.begin(slot: slot, topology: capturedTopologyProvider(), retryIDs: retryIDs)
        do {
            for group in LayoutWindowRestorer.snapshotGroupsPreservingOrder(slot.windows) {
                try Task.checkCancellation()
                if let retryIDs, !group.snapshots.contains(where: { retryIDs.contains($0.id) }) { continue }
                restoreSession.working(on: group.bundleIdentifier)
                let preserved: [WindowBatchMoveResult] = group.snapshots.compactMap { snapshot in
                    guard let retryIDs, !retryIDs.contains(snapshot.id),
                          previousResult?.details.first(where: { $0.id == snapshot.id })?.isSuccess == true else { return nil }
                    return WindowBatchMoveResult(
                        snapshotID: snapshot.id, restoredFrame: snapshot.frame.cgRect,
                        matchReason: nil, error: nil, reservation: previousReservations[snapshot.id]
                    )
                }
                // Include successful siblings only as reservations. Other failed
                // siblings are not part of a single-window retry.
                let attempted = group.snapshots.filter { snapshot in
                    retryIDs?.contains(snapshot.id) != false || preserved.contains(where: { $0.snapshotID == snapshot.id })
                }
                let session = restoreSession
                let reports = try await restorer.restore(
                    snapshots: attempted, settings: settings, displays: displayProvider(),
                    preservedResults: preserved,
                    observer: { event in await session.receive(event) }
                )
                restoreSession.update(reports)
            }
            let result = restoreSession.finish()
            AppLog.windows.info("Restored \(result.succeeded) of \(result.total) windows from slot \(slot.id, privacy: .public)")
            return result
        } catch {
            _ = restoreSession.finish(error: error)
            throw error
        }
    }

    func undoLastRestore() async throws -> SlotOperationResult {
        guard restoreSession.canUndo, let layout = restoreSession.layout else { throw SlotEngineError.nothingToUndo }
        let moves = restoreSession.undoMoves
        return try await managedRestore {
            guard self.accessibilityTrusted() else { throw WindowMoverError.accessibilityPermissionMissing }
            guard let originalTopology = self.restoreSession.topology,
                  originalTopology == self.capturedTopologyProvider() else {
                throw SlotEngineError.undoDisplayConfigurationChanged
            }
            let undoSlot = Slot(id: layout.id, name: layout.name, windows: moves.map(\.snapshot))
            self.restoreSession.begin(slot: undoSlot, topology: originalTopology, undo: true)
            do {
                for group in LayoutWindowRestorer.snapshotGroupsPreservingOrder(undoSlot.windows) {
                    try Task.checkCancellation()
                    guard originalTopology == self.capturedTopologyProvider() else {
                        throw SlotEngineError.undoDisplayConfigurationChanged
                    }
                    self.restoreSession.working(on: group.bundleIdentifier)
                    let requests = moves.filter { $0.snapshot.bundleIdentifier == group.bundleIdentifier }.map {
                        WindowBatchMoveRequest(snapshot: $0.snapshot, frame: $0.frame, attempts: 3, reservation: $0.reservation)
                    }
                    let session = self.restoreSession
                    do {
                        let results = try await self.windowMover.move(
                            requests: requests, bundleIdentifier: group.bundleIdentifier,
                            strictness: .strict, observer: { event in await session.receive(event) }
                        )
                        session.update(RestoreReportBuilder.reports(
                            for: group.snapshots, moveResults: results, didLaunchApplication: false
                        ))
                    } catch is CancellationError { throw CancellationError() }
                    catch WindowMoverError.accessibilityPermissionMissing { throw WindowMoverError.accessibilityPermissionMissing }
                    catch {
                        session.update(group.snapshots.map { RestoreReportBuilder.reportForRestoreFailure(snapshot: $0, error: error) })
                    }
                }
                return self.restoreSession.finish()
            } catch {
                _ = self.restoreSession.finish(error: error)
                throw error
            }
        }
    }
}
