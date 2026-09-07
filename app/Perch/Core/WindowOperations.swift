import Foundation

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

typealias RestorePreflight = @MainActor @Sendable (SlotStoreDocument) -> Bool
