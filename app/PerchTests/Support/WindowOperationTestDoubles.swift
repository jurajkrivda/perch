import Foundation


struct SuccessfulWindowSnapshotter: WindowSnapshotting {
    let snapshots: [WindowSnapshot]

    func captureCurrentWindows() async throws -> [WindowSnapshot] {
        snapshots
    }
}

struct IncompleteWindowSnapshotter: WindowSnapshotting {
    let processIdentifier: Int32

    func captureCurrentWindows() async throws -> [WindowSnapshot] {
        throw WindowSnapshotterError.incompleteAccessibilityRead(
            processIdentifier: processIdentifier
        )
    }
}

@MainActor
final class FakeWindowMover: WindowMoving {
    enum Outcome {
        case success
        case appNotRunning
        case windowNotFound
        case frameWriteFailed
    }

    private var outcomes: [Outcome]
    private(set) var moveCount = 0
    private(set) var movedSnapshotIDs: [String] = []
    private(set) var movedFramesBySnapshotID: [String: [CGRect]] = [:]
    private var reservationsBySnapshotID: [String: WindowCandidateReservation] = [:]

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int,
        strictness: MatchStrictness
    ) throws -> CGRect {
        moveCount += 1
        movedSnapshotIDs.append(snapshot.id)
        movedFramesBySnapshotID[snapshot.id, default: []].append(frame)

        guard !outcomes.isEmpty else {
            return frame
        }

        switch outcomes.removeFirst() {
        case .success:
            return frame
        case .appNotRunning:
            throw WindowMoverError.appNotRunning(bundleIdentifier: snapshot.bundleIdentifier)
        case .windowNotFound:
            throw WindowMoverError.windowNotFound(
                bundleIdentifier: snapshot.bundleIdentifier,
                title: snapshot.windowTitle
            )
        case .frameWriteFailed:
            throw WindowMoverError.frameWriteFailed
        }
    }

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) throws -> [WindowBatchMoveResult] {
        var results: [WindowBatchMoveResult] = []

        for request in requests {
            if !request.shouldMove {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: request.frame,
                    matchReason: .titleMatch,
                    error: nil,
                    reservation: request.reservation ?? reservationsBySnapshotID[request.snapshot.id]
                ))
                continue
            }

            do {
                let restoredFrame = try move(
                    snapshot: request.snapshot,
                    to: request.frame,
                    attempts: request.attempts,
                    strictness: strictness
                )
                let reservation = request.reservation
                    ?? reservationsBySnapshotID[request.snapshot.id]
                    ?? WindowCandidateReservation(
                        processIdentifier: request.snapshot.processIdentifier,
                        processLaunchDate: request.snapshot.capturedAt.addingTimeInterval(-60),
                        cgWindowID: nil,
                        axElementHash: UInt(bitPattern: request.snapshot.id.hashValue)
                    )
                reservationsBySnapshotID[request.snapshot.id] = reservation
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: restoredFrame,
                    matchReason: .titleMatch,
                    error: nil,
                    reservation: reservation
                ))
            } catch WindowMoverError.appNotRunning where results.isEmpty {
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

@MainActor
final class TitleChangingReservationMover: WindowMoving {
    private let processLaunchDate = Date(timeIntervalSince1970: 1_779_190_300)
    private let axElementHash: UInt = 77
    private var batchCallCount = 0
    private(set) var movedSnapshotIDs: [String] = []

    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int,
        strictness: MatchStrictness
    ) throws -> CGRect {
        movedSnapshotIDs.append(snapshot.id)
        return frame
    }

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) throws -> [WindowBatchMoveResult] {
        batchCallCount += 1
        if batchCallCount == 1 {
            throw WindowMoverError.appNotRunning(bundleIdentifier: bundleIdentifier)
        }

        let liveTitle = batchCallCount == 2
            ? "First Saved Window"
            : "Second Saved Window"
        let candidate = WindowMoveCandidate(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 1234,
            processLaunchDate: processLaunchDate,
            cgWindowID: nil,
            accessibilityIdentifier: nil,
            title: liveTitle,
            normalizedTitle: WindowTitleSimilarity.normalize(liveTitle),
            role: "AXWindow",
            isMinimized: false,
            isFullscreen: false,
            frame: requests.first?.frame,
            axElementHash: axElementHash
        )
        let matchRequests = requests.map { request in
            WindowMatcher.WindowMatchRequest(
                title: request.snapshot.windowTitle,
                processIdentifier: request.snapshot.processIdentifier,
                capturedAt: request.snapshot.capturedAt,
                cgWindowID: request.snapshot.cgWindowID,
                accessibilityIdentifier: request.snapshot.accessibilityIdentifier,
                frame: request.frame,
                reservation: request.reservation,
                rejectsConflictingAccessibilityIdentifier: false
            )
        }
        let selections = WindowMatcher.bestWindowSelections(
            in: [candidate],
            matching: matchRequests,
            strictness: strictness
        )
        let usedCandidateIndices = Set(selections.values.map(\.index))

        return requests.enumerated().map { index, request in
            guard let selection = selections[index] else {
                return WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: WindowMover.unresolvedSelectionError(
                        bundleIdentifier: bundleIdentifier,
                        title: request.snapshot.windowTitle,
                        candidateCount: 1,
                        usedCandidateIndices: usedCandidateIndices
                    )
                )
            }

            if request.shouldMove {
                movedSnapshotIDs.append(request.snapshot.id)
            }

            return WindowBatchMoveResult(
                snapshotID: request.snapshot.id,
                restoredFrame: request.frame,
                matchReason: selection.reason,
                error: nil,
                reservation: WindowCandidateReservation(
                    processIdentifier: candidate.processIdentifier,
                    processLaunchDate: candidate.processLaunchDate,
                    cgWindowID: candidate.cgWindowID,
                    axElementHash: candidate.axElementHash
                )
            )
        }
    }
}

struct DuplicateResultWindowMover: WindowMoving {
    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int,
        strictness: MatchStrictness
    ) throws -> CGRect {
        frame
    }

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) throws -> [WindowBatchMoveResult] {
        guard let request = requests.first else {
            return []
        }

        return [
            WindowBatchMoveResult(
                snapshotID: request.snapshot.id,
                restoredFrame: request.frame,
                matchReason: .titleMatch,
                error: nil
            ),
            WindowBatchMoveResult(
                snapshotID: request.snapshot.id,
                restoredFrame: nil,
                matchReason: nil,
                error: .frameWriteFailed
            )
        ]
    }
}

@MainActor
final class FakeApplicationLauncher: ApplicationLaunching {
    private let results: [String: ApplicationLaunchResult]
    private(set) var launchedBundles: [String] = []

    init(results: [String: ApplicationLaunchResult]) {
        self.results = results
    }

    func launchApplication(bundleIdentifier: String) async -> ApplicationLaunchResult {
        launchedBundles.append(bundleIdentifier)
        return results[bundleIdentifier] ?? .notInstalled
    }
}
