import Foundation

/// Restores one application's saved windows, preserving reservations through
/// startup retries and display remapping. Owned by SlotEngine's exclusive operation.
@MainActor
struct LayoutWindowRestorer {
    let windowMover: any WindowMoving
    let applicationLauncher: any ApplicationLaunching
    let displayProvider: @MainActor () -> [DisplayInfo]
    let launchRetryTimeout: TimeInterval
    let launchRetryIntervalNanoseconds: UInt64

    func restore(
        snapshots: [WindowSnapshot],
        settings: PerchSettings,
        displays: [DisplayInfo]
    ) async throws -> [RestoreWindowReport] {
        guard let bundleIdentifier = snapshots.first?.bundleIdentifier else {
            return []
        }

        let requests = moveRequests(for: snapshots, settings: settings, displays: displays)

        do {
            var results = try await windowMover.move(
                requests: requests,
                bundleIdentifier: bundleIdentifier,
                strictness: settings.matchStrictness
            )

            if resultsContainRetryableLaunchMiss(results) {
                // At login or wake an app may already be running while its
                // windows are still being recreated. Retry those misses just
                // as we do for applications launched by Perch.
                results = try await retryRestoreAfterLaunch(
                    snapshots: snapshots, bundleIdentifier: bundleIdentifier,
                    settings: settings, initialResults: results,
                    initialTopology: DisplayTopologyFingerprint(displays: displays)
                )
            }

            return RestoreReportBuilder.reports(
                for: snapshots,
                moveResults: results,
                didLaunchApplication: false
            )
        } catch WindowMoverError.accessibilityPermissionMissing {
            throw WindowMoverError.accessibilityPermissionMissing
        } catch WindowMoverError.appNotRunning {
            guard settings.opensMissingApplicationsOnRestore else {
                return RestoreReportBuilder.reportsForClosedApplication(snapshots)
            }

            return try await launchAndRestore(
                snapshots: snapshots,
                settings: settings
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return snapshots.map {
                RestoreReportBuilder.reportForRestoreFailure(snapshot: $0, error: error)
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

        let launchResult = try await applicationLauncher.launchApplication(bundleIdentifier: bundleIdentifier)

        switch launchResult {
        case .launched, .alreadyRunning:
            let results = try await retryRestoreAfterLaunch(
                snapshots: snapshots,
                bundleIdentifier: bundleIdentifier,
                settings: settings
            )

            return RestoreReportBuilder.reports(
                for: snapshots,
                moveResults: results,
                didLaunchApplication: launchResult == .launched
            )

        case .notInstalled:
            return snapshots.map { snapshot in
                RestoreReportBuilder.report(
                    for: snapshot,
                    outcome: .appNotInstalled,
                    didLaunchApplication: false,
                    matchReason: nil,
                    message: L10n.text(.applicationNotInstalled)
                )
            }

        case let .failed(message):
            return snapshots.map { snapshot in
                RestoreReportBuilder.report(
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
        settings: PerchSettings,
        initialResults: [WindowBatchMoveResult] = [],
        initialTopology: DisplayTopologyFingerprint? = nil
    ) async throws -> [WindowBatchMoveResult] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(launchRetryTimeout))
        var successfulSnapshotIDs = Set(initialResults.filter(\.isSuccess).map(\.snapshotID))
        var reservationsBySnapshotID = Dictionary(
            initialResults.compactMap { result in
                result.reservation.map { (result.snapshotID, $0) }
            }, uniquingKeysWith: { first, _ in first }
        )
        var previousDisplayTopology = initialTopology
        var hasPendingTopologyRemap = false
        var usedFinalTopologyRemap = false
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
        for result in initialResults {
            latestResultsBySnapshotID[result.snapshotID] = result
        }

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

            if ContinuousClock.now >= deadline {
                // A continuously renegotiating dock must not extend the retry
                // deadline forever, including while Perch is quitting.
                guard hasPendingTopologyRemap, !usedFinalTopologyRemap else {
                    if hasPendingTopologyRemap {
                        // The last positions were verified against a topology
                        // that has already changed again. Do not report success.
                        for snapshot in snapshots {
                            latestResultsBySnapshotID[snapshot.id] = WindowBatchMoveResult(
                                snapshotID: snapshot.id, restoredFrame: nil,
                                matchReason: nil, error: .frameWriteFailed,
                                reservation: reservationsBySnapshotID[snapshot.id]
                            )
                        }
                    }
                    return snapshots.compactMap { latestResultsBySnapshotID[$0.id] }
                }
                usedFinalTopologyRemap = true
            }

            try await Task.sleep(nanoseconds: launchRetryIntervalNanoseconds)
        }
    }

    static func snapshotGroupsPreservingOrder(_ snapshots: [WindowSnapshot]) -> [(bundleIdentifier: String, snapshots: [WindowSnapshot])] {
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
                frame: WindowGeometry.targetFrame(for: snapshot, displays: displays),
                attempts: settings.retryAttempts
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

}
