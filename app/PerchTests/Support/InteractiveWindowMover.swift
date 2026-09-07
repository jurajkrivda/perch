import Foundation

/// In-memory windows with real one-to-one matching. Tests can change titles,
/// replace processes, and suspend writes without touching the user's desktop.
@MainActor
final class InteractiveWindowMover: WindowMoving {
    var candidates: [WindowMoveCandidate]
    var pauseAfterFirstMove = false
    var pauseDuringFirstWrite = false
    var failWrites = false
    private(set) var movedWindowHashes: [UInt] = []
    private(set) var receivedBatches: [[WindowBatchMoveRequest]] = []

    init(snapshots: [WindowSnapshot]) {
        candidates = snapshots.enumerated().map { offset, snapshot in
            Self.candidate(snapshot: snapshot, hash: UInt(offset + 1))
        }
    }

    static func candidate(snapshot: WindowSnapshot, hash: UInt) -> WindowMoveCandidate {
        WindowMoveCandidate(
            bundleIdentifier: snapshot.bundleIdentifier,
            processIdentifier: snapshot.processIdentifier,
            processLaunchDate: snapshot.capturedAt.addingTimeInterval(-60),
            cgWindowID: snapshot.cgWindowID,
            accessibilityIdentifier: snapshot.accessibilityIdentifier,
            title: snapshot.windowTitle,
            normalizedTitle: WindowTitleSimilarity.normalize(snapshot.windowTitle),
            role: "AXWindow", isMinimized: false, isFullscreen: false,
            frame: CGRect(x: 10 + Int(hash), y: 20, width: 600, height: 400), axElementHash: hash
        )
    }

    func move(snapshot: WindowSnapshot, to frame: CGRect, attempts: Int, strictness: MatchStrictness) async throws -> CGRect {
        fatalError("Restore and undo must use the batch interface")
    }

    func move(
        requests: [WindowBatchMoveRequest], bundleIdentifier: String, strictness: MatchStrictness
    ) async throws -> [WindowBatchMoveResult] {
        try await move(requests: requests, bundleIdentifier: bundleIdentifier, strictness: strictness, observer: { _ in })
    }

    func move(
        requests: [WindowBatchMoveRequest], bundleIdentifier: String,
        strictness: MatchStrictness, observer: @escaping WindowMoveObserver
    ) async throws -> [WindowBatchMoveResult] {
        receivedBatches.append(requests)
        let live = candidates.filter { $0.bundleIdentifier == bundleIdentifier }
        let selections = WindowMatcher.bestWindowSelections(
            in: live,
            matching: requests.map {
                WindowMatcher.WindowMatchRequest(
                    title: $0.snapshot.windowTitle, processIdentifier: $0.snapshot.processIdentifier,
                    capturedAt: $0.snapshot.capturedAt, cgWindowID: $0.snapshot.cgWindowID,
                    accessibilityIdentifier: $0.snapshot.accessibilityIdentifier,
                    frame: $0.frame, reservation: $0.reservation
                )
            }, strictness: strictness
        )
        var results: [WindowBatchMoveResult] = []
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            guard let selection = selections[index] else {
                let result = WindowBatchMoveResult(
                    snapshotID: request.snapshot.id, restoredFrame: nil, matchReason: nil,
                    error: .windowNotFound(bundleIdentifier: bundleIdentifier, title: request.snapshot.windowTitle)
                )
                results.append(result)
                await observer(.completed(result))
                continue
            }
            let candidate = live[selection.index]
            let reservation = WindowMatcher.reservation(for: candidate)
            if request.shouldMove {
                await observer(.willMove(snapshotID: request.snapshot.id, frame: candidate.frame!, reservation: reservation))
                try Task.checkCancellation()
                movedWindowHashes.append(candidate.axElementHash)
                let candidateIndex = candidates.firstIndex { $0.axElementHash == candidate.axElementHash }!
                candidates[candidateIndex].frame = request.frame
                if pauseDuringFirstWrite && movedWindowHashes.count == 1 {
                    try await Task.sleep(for: .seconds(20))
                }
            }
            let result = WindowBatchMoveResult(
                snapshotID: request.snapshot.id, restoredFrame: failWrites ? nil : request.frame,
                matchReason: selection.reason, error: failWrites ? .frameWriteFailed : nil,
                reservation: reservation
            )
            results.append(result)
            await observer(.completed(result))
            if pauseAfterFirstMove && movedWindowHashes.count == 1 {
                try await Task.sleep(for: .seconds(20))
            }
        }
        return results
    }
}
