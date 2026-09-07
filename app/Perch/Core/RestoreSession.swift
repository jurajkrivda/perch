import Foundation
import Observation

extension Notification.Name {
    static let perchRestoreDidChange = Notification.Name("PerchRestoreDidChange")
}

struct UndoWindowMove: Sendable {
    let snapshot: WindowSnapshot
    let frame: CGRect
    let reservation: WindowCandidateReservation
}

/// One in-memory restore, shared by manual and automatic entry points. Window
/// identities and original frames never go into the persistent layout file.
@MainActor
@Observable
final class RestoreSession {
    private(set) var layout: Slot?
    private(set) var result: SlotOperationResult?
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var isUndo = false
    private(set) var isStabilizing = false
    private(set) var currentApplication: String?
    private(set) var errorMessage: String?
    private(set) var undoMoves: [UndoWindowMove] = []
    private(set) var topology: DisplayTopologyFingerprint?
    private(set) var reservations: [String: WindowCandidateReservation] = [:]
    private var reports: [String: RestoreWindowReport] = [:]
    private var activeIDs = Set<String>()

    var canUndo: Bool { !isRunning && !undoMoves.isEmpty }
    var canRetry: Bool {
        !isRunning && !isUndo && result?.details.contains(where: { !$0.isSuccess }) == true
    }
    var completedCount: Int {
        reports.values.filter { $0.outcome != .pending }.count
    }

    func prepare() {
        isRunning = true
        isCancelling = false
        isStabilizing = true
        errorMessage = nil
        publish()
    }

    func endPreparation(error: Error) {
        isRunning = false
        isStabilizing = false
        if !(error is CancellationError),
           case SlotEngineError.restorePreflightRejected = error {
            // Coordinator re-evaluation is intentionally silent.
        } else if !(error is CancellationError) {
            errorMessage = LocalizedErrorMessages.message(for: error)
        }
        publish()
    }

    func begin(
        slot: Slot, topology: DisplayTopologyFingerprint?,
        retryIDs: Set<String>? = nil, undo: Bool = false
    ) {
        if retryIDs == nil {
            reports = [:]
            reservations = [:]
            if !undo {
                undoMoves = []
                self.topology = topology
            }
        }
        layout = slot
        activeIDs = retryIDs ?? Set(slot.windows.map(\.id))
        for snapshot in slot.windows where activeIDs.contains(snapshot.id) {
            reports[snapshot.id] = RestoreReportBuilder.report(
                for: snapshot, outcome: .pending, didLaunchApplication: false,
                matchReason: nil, message: nil
            )
        }
        isRunning = true
        isCancelling = false
        isStabilizing = true
        isUndo = undo
        errorMessage = nil
        currentApplication = nil
        publish()
    }

    func working(on bundleIdentifier: String) {
        isStabilizing = false
        currentApplication = RestoreReportBuilder.applicationDisplayName(for: bundleIdentifier)
        publish()
    }

    func receive(_ event: WindowMoveEvent) {
        guard let layout else { return }
        switch event {
        case let .willMove(snapshotID, frame, reservation):
            guard !isUndo, activeIDs.contains(snapshotID),
                  !undoMoves.contains(where: { $0.reservation == reservation }),
                  var snapshot = layout.windows.first(where: { $0.id == snapshotID }) else { return }
            snapshot.id = UUID().uuidString
            undoMoves.append(UndoWindowMove(snapshot: snapshot, frame: frame, reservation: reservation))
        case let .completed(moveResult):
            guard activeIDs.contains(moveResult.snapshotID),
                  let snapshot = layout.windows.first(where: { $0.id == moveResult.snapshotID }) else { return }
            if let reservation = moveResult.reservation {
                reservations[snapshot.id] = reservation
            }
            if isUndo && moveResult.isSuccess {
                undoMoves.removeAll { $0.snapshot.id == snapshot.id }
            }
            // Retry misses are provisional while the restorer is still polling.
            // Completed groups below replace them with the final outcome.
            if moveResult.isSuccess {
                update(RestoreReportBuilder.reports(
                    for: [snapshot], moveResults: [moveResult], didLaunchApplication: false
                ))
            }
        }
    }

    func update(_ completedReports: [RestoreWindowReport]) {
        for report in completedReports where activeIDs.contains(report.id) {
            reports[report.id] = report
        }
        publish()
    }

    func cancelling() {
        guard isRunning else { return }
        isCancelling = true
        publish()
    }

    func finish(error: Error? = nil) -> SlotOperationResult {
        if let error, !(error is CancellationError) {
            errorMessage = LocalizedErrorMessages.message(for: error)
        }
        if let layout {
            for snapshot in layout.windows where reports[snapshot.id]?.outcome == .pending {
                reports[snapshot.id] = RestoreReportBuilder.report(
                    for: snapshot, outcome: error is CancellationError ? .cancelled : .skipped,
                    didLaunchApplication: false, matchReason: nil, message: errorMessage
                )
            }
        }
        isRunning = false
        isStabilizing = false
        currentApplication = nil
        publish()
        return result ?? SlotOperationResult(slotID: "", slotName: "", succeeded: 0, total: 0)
    }

    func didRepair(slot: Slot, windowID: String) {
        guard !isRunning, !isUndo, let previous = layout, previous.id == slot.id,
              previous.windows.filter({ $0.id != windowID }) == slot.windows.filter({ $0.id != windowID }),
              previous.capturedTopology == slot.capturedTopology else { return }
        layout = slot
        reservations[windowID] = nil
        if let snapshot = slot.windows.first(where: { $0.id == windowID }) {
            reports[windowID] = RestoreReportBuilder.report(
                for: snapshot, outcome: .skipped, didLaunchApplication: false,
                matchReason: nil, message: L10n.text(.windowReassigned)
            )
        }
        publish()
    }

    private func publish() {
        if let layout {
            let details = layout.windows.compactMap { reports[$0.id] }
            result = SlotOperationResult(
                slotID: layout.id, slotName: layout.name,
                succeeded: details.filter(\.isSuccess).count,
                total: layout.windows.count, details: details
            )
        }
        NotificationCenter.default.post(name: .perchRestoreDidChange, object: self)
    }
}
