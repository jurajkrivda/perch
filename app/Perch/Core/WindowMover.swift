@preconcurrency import ApplicationServices
@preconcurrency import AppKit
import CoreGraphics
import Foundation

enum WindowMoverError: LocalizedError, Equatable, Sendable {
    case accessibilityPermissionMissing
    case appNotRunning(bundleIdentifier: String)
    case windowNotFound(bundleIdentifier: String, title: String)
    case ambiguousWindowMatch(bundleIdentifier: String, title: String)
    case invalidFrame(CGRect)
    case frameReadFailed
    case frameWriteFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "Accessibility permission is required to move windows."
        case let .appNotRunning(bundleIdentifier):
            "No running application was found for \(bundleIdentifier)."
        case let .windowNotFound(bundleIdentifier, title):
            "No movable window was found for \(bundleIdentifier) with title \(title)."
        case let .ambiguousWindowMatch(bundleIdentifier, title):
            "Multiple windows were available for \(bundleIdentifier), but Perch could not safely choose one for \(title)."
        case let .invalidFrame(frame):
            "Invalid target frame: \(frame)."
        case .frameReadFailed:
            "Unable to read the current window frame."
        case .frameWriteFailed:
            "Unable to set and verify the window frame."
        }
    }
}

enum WindowMoveMatchReason: Equatable, Sendable {
    case cgWindowID
    case accessibilityIdentifier
    case titleMatch
    case singleCandidateFallback

    @MainActor
    var userDescription: String {
        switch self {
        case .cgWindowID:
            L10n.text(.matchReasonSameLiveWindow)
        case .accessibilityIdentifier:
            L10n.text(.matchReasonSavedWindowIdentity)
        case .titleMatch:
            L10n.text(.matchReasonWindowTitle)
        case .singleCandidateFallback:
            L10n.text(.matchReasonOnlyOpenWindow)
        }
    }
}

struct WindowMoveRequest: Sendable {
    var bundleIdentifier: String
    var windowTitle: String
    var processIdentifier: Int32?
    var cgWindowID: UInt32?
    var accessibilityIdentifier: String?
    var capturedAt: Date?
    var frame: CGRect
    var attempts: Int

    init(
        bundleIdentifier: String,
        windowTitle: String,
        processIdentifier: Int32? = nil,
        cgWindowID: UInt32? = nil,
        accessibilityIdentifier: String? = nil,
        capturedAt: Date? = nil,
        frame: CGRect,
        attempts: Int = 3
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.processIdentifier = processIdentifier
        self.cgWindowID = cgWindowID
        self.accessibilityIdentifier = accessibilityIdentifier
        self.capturedAt = capturedAt
        self.frame = frame
        self.attempts = attempts
    }
}

struct WindowBatchMoveRequest: Sendable {
    var snapshot: WindowSnapshot
    var frame: CGRect
    var attempts: Int
    /// Identity of the exact live window selected by an earlier batch. It is
    /// independent of mutable title/AX metadata and prevents another saved
    /// snapshot from claiming the same physical window on a later retry.
    var reservation: WindowCandidateReservation?
    /// Keeps an already-restored window in later launch-retry batches so the
    /// one-to-one matcher reserves it without moving it again.
    var shouldMove: Bool

    init(
        snapshot: WindowSnapshot,
        frame: CGRect,
        attempts: Int,
        reservation: WindowCandidateReservation? = nil,
        shouldMove: Bool = true
    ) {
        self.snapshot = snapshot
        self.frame = frame
        self.attempts = attempts
        self.reservation = reservation
        self.shouldMove = shouldMove
    }
}

struct WindowCandidateReservation: Equatable, Hashable, Sendable {
    var processIdentifier: Int32
    var processLaunchDate: Date?
    var cgWindowID: UInt32?
    var axElementHash: UInt
}

struct WindowBatchMoveResult: Equatable, Sendable {
    var snapshotID: String
    var restoredFrame: CGRect?
    var matchReason: WindowMoveMatchReason?
    var error: WindowMoverError?
    var reservation: WindowCandidateReservation? = nil

    var isSuccess: Bool {
        error == nil
    }
}

struct WindowMoveCandidate: Equatable, Sendable {
    var bundleIdentifier: String
    var processIdentifier: Int32
    var processLaunchDate: Date?
    var cgWindowID: UInt32?
    var accessibilityIdentifier: String?
    var title: String
    var normalizedTitle: String
    var role: String
    var isMinimized: Bool
    var isFullscreen: Bool
    var frame: CGRect?
    var axElementHash: UInt = 0
}

/// Serializes blocking Accessibility calls away from the main actor. AX objects
/// remain private to this actor; only Sendable values cross its boundary.
actor WindowMover {
    private struct AXWindow {
        var element: AXUIElement
        var candidate: WindowMoveCandidate
    }

    private struct CGWindowMetadata {
        var windowID: UInt32
        var title: String
        var frame: CGRect
    }

    private enum AXAttributeReadResult {
        case values([Any])
        case cannotComplete
        case failed
    }

    struct WindowMatchRequest: Equatable, Sendable {
        var title: String
        var processIdentifier: Int32?
        var capturedAt: Date?
        var cgWindowID: UInt32?
        var accessibilityIdentifier: String?
        var frame: CGRect?
        var reservation: WindowCandidateReservation?
        var rejectsConflictingAccessibilityIdentifier: Bool

        init(
            title: String,
            processIdentifier: Int32? = nil,
            capturedAt: Date? = nil,
            cgWindowID: UInt32? = nil,
            accessibilityIdentifier: String? = nil,
            frame: CGRect? = nil,
            reservation: WindowCandidateReservation? = nil,
            rejectsConflictingAccessibilityIdentifier: Bool = true
        ) {
            self.title = title
            self.processIdentifier = processIdentifier
            self.capturedAt = capturedAt
            self.cgWindowID = cgWindowID
            self.accessibilityIdentifier = accessibilityIdentifier
            self.frame = frame
            self.reservation = reservation
            self.rejectsConflictingAccessibilityIdentifier = rejectsConflictingAccessibilityIdentifier
        }
    }

    struct WindowSelection: Equatable, Sendable {
        var index: Int
        var reason: WindowMoveMatchReason
    }

    private static let minimumTitleScore = 0.34
    private static let decisiveTitleScoreGap = 0.12
    private static let decisiveFrameDistanceGap: CGFloat = 48
    private static let frameTolerance: CGFloat = 2

    @discardableResult
    func setFrame(_ request: WindowMoveRequest, strictness: MatchStrictness = .fuzzy) async throws -> CGRect {
        guard request.frame.isValidWindowFrame else {
            throw WindowMoverError.invalidFrame(request.frame)
        }

        guard let window = try bestLiveWindow(
            bundleIdentifier: request.bundleIdentifier,
            request: WindowMatchRequest(
                title: request.windowTitle,
                processIdentifier: request.processIdentifier,
                capturedAt: request.capturedAt,
                cgWindowID: request.cgWindowID,
                accessibilityIdentifier: request.accessibilityIdentifier,
                frame: request.frame
            ),
            strictness: strictness
        ) else {
            throw WindowMoverError.windowNotFound(
                bundleIdentifier: request.bundleIdentifier,
                title: request.windowTitle
            )
        }

        return try await moveWindow(
            window,
            to: request.frame,
            attempts: request.attempts,
            bundleIdentifier: request.bundleIdentifier
        )
    }

    @discardableResult
    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int = 3,
        strictness: MatchStrictness
    ) async throws -> CGRect {
        try await setFrame(
            WindowMoveRequest(
                bundleIdentifier: snapshot.bundleIdentifier,
                windowTitle: snapshot.windowTitle,
                processIdentifier: snapshot.processIdentifier,
                cgWindowID: snapshot.cgWindowID,
                accessibilityIdentifier: snapshot.accessibilityIdentifier,
                capturedAt: snapshot.capturedAt,
                frame: frame,
                attempts: attempts
            ),
            strictness: strictness
        )
    }

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) async throws -> [WindowBatchMoveResult] {
        try Task.checkCancellation()
        guard !requests.isEmpty else {
            return []
        }

        let windows = try liveWindows(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil,
            includeSkippedWindows: true
        )
        let candidates = windows.map(\.candidate)
        let validIndexedRequests = requests.enumerated().filter { $0.element.frame.isValidWindowFrame }
        let matchRequests = validIndexedRequests.map { _, request in
            WindowMatchRequest(
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
        let selectionsForValidRequests = Self.bestWindowSelections(
            in: candidates,
            matching: matchRequests,
            strictness: strictness
        )
        let selections = Dictionary(
            uniqueKeysWithValues: selectionsForValidRequests.compactMap { validRequestIndex, selection in
                validIndexedRequests.indices.contains(validRequestIndex)
                    ? (validIndexedRequests[validRequestIndex].offset, selection)
                    : nil
            }
        )

        var results: [WindowBatchMoveResult] = []
        results.reserveCapacity(requests.count)

        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            guard request.frame.isValidWindowFrame else {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: .invalidFrame(request.frame)
                ))
                continue
            }

            guard let selection = selections[index] else {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: Self.unresolvedSelectionError(
                        bundleIdentifier: request.snapshot.bundleIdentifier,
                        title: request.snapshot.windowTitle,
                        candidateCount: candidates.count,
                        usedCandidateIndices: Set(selections.values.map(\.index))
                    )
                ))
                continue
            }

            do {
                let selectedWindow = windows[selection.index]
                let restoredFrame: CGRect
                if request.shouldMove {
                    restoredFrame = try await moveWindow(
                        selectedWindow,
                        to: request.frame,
                        attempts: request.attempts,
                        bundleIdentifier: request.snapshot.bundleIdentifier
                    )
                } else {
                    restoredFrame = selectedWindow.candidate.frame ?? request.frame
                }

                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: restoredFrame,
                    matchReason: selection.reason,
                    error: nil,
                    reservation: Self.reservation(for: selectedWindow.candidate)
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WindowMoverError {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: selection.reason,
                    error: error
                ))
            } catch {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: selection.reason,
                    error: .frameWriteFailed
                ))
            }
        }

        return results
    }

    static func unresolvedSelectionError(
        bundleIdentifier: String,
        title: String,
        candidateCount: Int,
        usedCandidateIndices: Set<Int>
    ) -> WindowMoverError {
        let hasUnusedCandidate = (0..<candidateCount).contains { !usedCandidateIndices.contains($0) }

        if candidateCount == 0 || !hasUnusedCandidate {
            return .windowNotFound(
                bundleIdentifier: bundleIdentifier,
                title: title
            )
        }

        return .ambiguousWindowMatch(
            bundleIdentifier: bundleIdentifier,
            title: title
        )
    }

    static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func fuzzyTitleScore(candidate: String, target: String) -> Double {
        let candidateTitle = normalizedTitle(candidate)
        let targetTitle = normalizedTitle(target)

        guard !candidateTitle.isEmpty, !targetTitle.isEmpty else {
            return candidateTitle == targetTitle ? 1 : 0
        }

        if candidateTitle == targetTitle {
            return 1
        }

        if candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle) {
            let shorter = Double(min(candidateTitle.count, targetTitle.count))
            let longer = Double(max(candidateTitle.count, targetTitle.count))
            return max(0.72, shorter / longer)
        }

        let tokenScore = tokenOverlapScore(candidateTitle, targetTitle)
        let editScore = editSimilarity(candidateTitle, targetTitle)

        return (tokenScore * 0.62) + (editScore * 0.38)
    }

    static func bestWindowSelection(
        in candidates: [WindowMoveCandidate],
        title: String,
        strictness: MatchStrictness
    ) -> WindowSelection? {
        bestWindowSelection(
            in: candidates,
            matching: WindowMatchRequest(title: title),
            strictness: strictness
        )
    }

    static func bestWindowSelection(
        in candidates: [WindowMoveCandidate],
        matching request: WindowMatchRequest,
        strictness: MatchStrictness
    ) -> WindowSelection? {
        bestWindowSelections(
            in: candidates,
            matching: [request],
            strictness: strictness
        )[0]
    }

    static func bestWindowSelections(
        in candidates: [WindowMoveCandidate],
        matching requests: [WindowMatchRequest],
        strictness: MatchStrictness
    ) -> [Int: WindowSelection] {
        var selections: [Int: WindowSelection] = [:]
        var unresolvedRequestIndices = Set(requests.indices)
        var usedCandidateIndices = Set<Int>()

        func assign(_ requestIndex: Int, _ candidateIndex: Int, reason: WindowMoveMatchReason) {
            selections[requestIndex] = WindowSelection(index: candidateIndex, reason: reason)
            unresolvedRequestIndices.remove(requestIndex)
            usedCandidateIndices.insert(candidateIndex)
        }

        // Reservations take precedence over every mutable matching signal. A
        // live browser title or AXIdentifier may change between launch polls,
        // but the same AX object / CG window must remain owned by the snapshot
        // that already restored it.
        for requestIndex in requests.indices {
            guard let reservation = requests[requestIndex].reservation else {
                continue
            }

            // Once a snapshot owns a physical live window, mutable matching
            // signals must never transfer that ownership to a different one.
            // A temporarily missing reservation stays unresolved and retries.
            unresolvedRequestIndices.remove(requestIndex)

            let matches = candidates.indices.filter {
                !usedCandidateIndices.contains($0) &&
                    candidate(candidates[$0], matches: reservation)
            }

            if let match = uniqueIndex(matches) {
                assign(requestIndex, match, reason: .cgWindowID)
            } else if !matches.isEmpty {
                // A hash collision must fail closed: none of the physical
                // candidates covered by an existing reservation may be handed
                // to a different pending snapshot.
                usedCandidateIndices.formUnion(matches)
            }
        }

        for requestIndex in unresolvedRequestIndices.sorted() {
            guard let cgWindowID = requests[requestIndex].cgWindowID else {
                continue
            }

            let matches = candidates.indices.filter {
                !usedCandidateIndices.contains($0) &&
                    candidates[$0].cgWindowID == cgWindowID &&
                    isSameCapturedProcess(candidates[$0], request: requests[requestIndex])
            }

            if let match = uniqueIndex(matches) {
                assign(requestIndex, match, reason: .cgWindowID)
            }
        }

        for requestIndex in unresolvedRequestIndices.sorted() {
            guard let accessibilityIdentifier = normalizedAccessibilityIdentifier(requests[requestIndex].accessibilityIdentifier) else {
                continue
            }

            let matches = candidates.indices.filter {
                !usedCandidateIndices.contains($0) &&
                    normalizedAccessibilityIdentifier(candidates[$0].accessibilityIdentifier) == accessibilityIdentifier
            }

            if let match = uniqueIndex(matches) {
                assign(requestIndex, match, reason: .accessibilityIdentifier)
            }
        }

        var didAssignTitleMatch = true
        while didAssignTitleMatch {
            didAssignTitleMatch = false

            func matchedCandidates(for requestIndex: Int) -> [(Int, WindowMoveCandidate)] {
                let request = requests[requestIndex]
                return candidates.indices.compactMap { candidateIndex -> (Int, WindowMoveCandidate)? in
                    guard !usedCandidateIndices.contains(candidateIndex) else {
                        return nil
                    }

                    let candidate = candidates[candidateIndex]
                    guard
                        !shouldRejectForConflictingAccessibilityIdentifier(candidate, request: request),
                        candidateMatches(candidate, title: request.title, strictness: strictness)
                    else {
                        return nil
                    }

                    return (candidateIndex, candidate)
                }
            }

            var exactProposalsByCandidate: [Int: [(requestIndex: Int, selection: WindowSelection)]] = [:]

            for requestIndex in unresolvedRequestIndices.sorted() {
                let request = requests[requestIndex]
                let matches = matchedCandidates(for: requestIndex)

                if let titleMatch = exactTitleSelection(in: matches, request: request) {
                    exactProposalsByCandidate[titleMatch, default: []].append((
                        requestIndex: requestIndex,
                        selection: WindowSelection(index: titleMatch, reason: .titleMatch)
                    ))
                }
            }

            for proposals in exactProposalsByCandidate.values where proposals.count == 1 {
                let proposal = proposals[0]
                guard unresolvedRequestIndices.contains(proposal.requestIndex),
                      !usedCandidateIndices.contains(proposal.selection.index)
                else {
                    continue
                }

                assign(proposal.requestIndex, proposal.selection.index, reason: proposal.selection.reason)
                didAssignTitleMatch = true
            }

            if didAssignTitleMatch {
                continue
            }

            var proposalsByCandidate: [Int: [(requestIndex: Int, selection: WindowSelection)]] = [:]

            for requestIndex in unresolvedRequestIndices.sorted() {
                let request = requests[requestIndex]
                let matches = matchedCandidates(for: requestIndex)

                if let titleMatch = decisiveTitleSelection(in: matches, request: request) {
                    proposalsByCandidate[titleMatch, default: []].append((
                        requestIndex: requestIndex,
                        selection: WindowSelection(index: titleMatch, reason: .titleMatch)
                    ))
                }
            }

            for proposals in proposalsByCandidate.values where proposals.count == 1 {
                let proposal = proposals[0]
                guard unresolvedRequestIndices.contains(proposal.requestIndex),
                      !usedCandidateIndices.contains(proposal.selection.index)
                else {
                    continue
                }

                assign(proposal.requestIndex, proposal.selection.index, reason: proposal.selection.reason)
                didAssignTitleMatch = true
            }
        }

        if unresolvedRequestIndices.count == 1,
           let requestIndex = unresolvedRequestIndices.first {
            let unusedCandidates = candidates.indices.filter { !usedCandidateIndices.contains($0) }
            if let onlyCandidate = uniqueIndex(unusedCandidates),
               !shouldRejectForConflictingAccessibilityIdentifier(candidates[onlyCandidate], request: requests[requestIndex]) {
                assign(requestIndex, onlyCandidate, reason: .singleCandidateFallback)
            }
        }

        return selections
    }

    private func bestLiveWindow(
        bundleIdentifier: String,
        request: WindowMatchRequest,
        strictness: MatchStrictness
    ) throws -> AXWindow? {
        let processScopedWindows: [AXWindow]
        do {
            processScopedWindows = try liveWindows(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: request.processIdentifier,
                includeSkippedWindows: true
            )
        } catch WindowMoverError.appNotRunning where request.processIdentifier != nil {
            processScopedWindows = []
        }

        if let selectedWindow = bestWindow(
            in: processScopedWindows,
            request: request,
            strictness: strictness,
            scope: request.processIdentifier == nil ? "bundle" : "process"
        ) {
            return selectedWindow
        }

        guard request.processIdentifier != nil else {
            return nil
        }

        let fallbackWindows = try liveWindows(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil,
            includeSkippedWindows: true
        )
        let bundleFallbackRequest = WindowMatchRequest(
            title: request.title,
            accessibilityIdentifier: request.accessibilityIdentifier,
            frame: request.frame,
            rejectsConflictingAccessibilityIdentifier: false
        )

        return bestWindow(
            in: fallbackWindows,
            request: bundleFallbackRequest,
            strictness: strictness,
            scope: "bundle fallback"
        )
    }

    private func bestWindow(
        in windows: [AXWindow],
        request: WindowMatchRequest,
        strictness: MatchStrictness,
        scope: String
    ) -> AXWindow? {
        guard let selection = Self.bestWindowSelection(
            in: windows.map(\.candidate),
            matching: request,
            strictness: strictness
        ) else {
            return nil
        }

        let window = windows[selection.index]
        switch selection.reason {
        case .cgWindowID:
            AppLog.windows.debug(
                "Selected window for \(window.candidate.bundleIdentifier, privacy: .public) by CGWindowID in \(scope, privacy: .public) scope"
            )
        case .accessibilityIdentifier:
            AppLog.windows.debug(
                "Selected window for \(window.candidate.bundleIdentifier, privacy: .public) by AXIdentifier in \(scope, privacy: .public) scope"
            )
        case .titleMatch:
            break
        case .singleCandidateFallback:
            AppLog.windows.info(
                "Using only live window for \(window.candidate.bundleIdentifier, privacy: .public) after saved title did not match in \(scope, privacy: .public) scope"
            )
        }

        return window
    }

    private static func candidateMatches(
        _ candidate: WindowMoveCandidate,
        title: String,
        strictness: MatchStrictness
    ) -> Bool {
        switch strictness {
        case .strict:
            candidate.normalizedTitle == Self.normalizedTitle(title)
        case .fuzzy:
            Self.fuzzyTitleScore(candidate: candidate.title, target: title) >= Self.minimumTitleScore
        case .loose:
            Self.fuzzyTitleScore(candidate: candidate.title, target: title) >= 0.15 || candidate.title.isEmpty
        }
    }

    private static func frameDistance(_ frame: CGRect?, to targetFrame: CGRect) -> CGFloat {
        guard let frame else {
            return .greatestFiniteMagnitude
        }

        return abs(frame.origin.x - targetFrame.origin.x) +
            abs(frame.origin.y - targetFrame.origin.y) +
            abs(frame.size.width - targetFrame.size.width) +
            abs(frame.size.height - targetFrame.size.height)
    }

    private static func decisiveTitleSelection(
        in matches: [(Int, WindowMoveCandidate)],
        request: WindowMatchRequest
    ) -> Int? {
        guard let firstMatch = matches.first else {
            return nil
        }

        guard matches.count > 1 else {
            return firstMatch.0
        }

        let rankedMatches = matches.map { index, candidate in
            (
                index: index,
                candidate: candidate,
                titleScore: fuzzyTitleScore(candidate: candidate.title, target: request.title)
            )
        }
        .sorted { lhs, rhs in
            if lhs.titleScore != rhs.titleScore {
                return lhs.titleScore > rhs.titleScore
            }

            if let frame = request.frame {
                let lhsDistance = frameDistance(lhs.candidate.frame, to: frame)
                let rhsDistance = frameDistance(rhs.candidate.frame, to: frame)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
            }

            return (lhs.candidate.frame?.area ?? 0) > (rhs.candidate.frame?.area ?? 0)
        }

        let best = rankedMatches[0]
        let runnerUp = rankedMatches[1]
        let scoreGap = best.titleScore - runnerUp.titleScore

        if best.titleScore == 1, runnerUp.titleScore < 1 {
            return best.index
        }

        if scoreGap >= decisiveTitleScoreGap {
            return best.index
        }

        if let frame = request.frame {
            let bestDistance = frameDistance(best.candidate.frame, to: frame)
            let runnerUpDistance = frameDistance(runnerUp.candidate.frame, to: frame)
            if bestDistance <= frameTolerance && runnerUpDistance - bestDistance >= decisiveFrameDistanceGap {
                return best.index
            }
        }

        AppLog.windows.warning(
            "Refusing ambiguous title match for saved title"
        )
        return nil
    }

    private static func exactTitleSelection(
        in matches: [(Int, WindowMoveCandidate)],
        request: WindowMatchRequest
    ) -> Int? {
        let normalizedTarget = normalizedTitle(request.title)
        guard !normalizedTarget.isEmpty else {
            return nil
        }

        let exactMatches = matches.filter { _, candidate in
            candidate.normalizedTitle == normalizedTarget
        }

        return exactMatches.count == 1 ? exactMatches[0].0 : nil
    }

    private static func uniqueIndex(_ indices: [Int]) -> Int? {
        indices.count == 1 ? indices[0] : nil
    }

    private static func shouldRejectForConflictingAccessibilityIdentifier(
        _ candidate: WindowMoveCandidate,
        request: WindowMatchRequest
    ) -> Bool {
        guard request.rejectsConflictingAccessibilityIdentifier else {
            return false
        }

        guard
            let savedIdentifier = normalizedAccessibilityIdentifier(request.accessibilityIdentifier),
            let liveIdentifier = normalizedAccessibilityIdentifier(candidate.accessibilityIdentifier)
        else {
            return false
        }

        return savedIdentifier != liveIdentifier
    }

    private static func normalizedAccessibilityIdentifier(_ identifier: String?) -> String? {
        guard let normalized = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return nil
        }

        return normalized
    }

    private static func reservation(for candidate: WindowMoveCandidate) -> WindowCandidateReservation {
        WindowCandidateReservation(
            processIdentifier: candidate.processIdentifier,
            processLaunchDate: candidate.processLaunchDate,
            cgWindowID: candidate.cgWindowID,
            axElementHash: candidate.axElementHash
        )
    }

    private static func candidate(
        _ candidate: WindowMoveCandidate,
        matches reservation: WindowCandidateReservation
    ) -> Bool {
        guard candidate.processIdentifier == reservation.processIdentifier else {
            return false
        }

        if let reservedLaunchDate = reservation.processLaunchDate {
            guard candidate.processLaunchDate == reservedLaunchDate else {
                return false
            }
        }

        if let reservedWindowID = reservation.cgWindowID,
           let candidateWindowID = candidate.cgWindowID,
           reservedWindowID == candidateWindowID {
            return true
        }

        return candidate.axElementHash == reservation.axElementHash
    }

    /// CGWindowID is only stable for the lifetime of its owning process. PID by
    /// itself is insufficient because the kernel may reuse it after logout or
    /// reboot, so the live process must also have launched before capture.
    private static func isSameCapturedProcess(
        _ candidate: WindowMoveCandidate,
        request: WindowMatchRequest
    ) -> Bool {
        guard
            let savedProcessIdentifier = request.processIdentifier,
            candidate.processIdentifier == savedProcessIdentifier,
            let capturedAt = request.capturedAt,
            let processLaunchDate = candidate.processLaunchDate
        else {
            return false
        }

        return processLaunchDate <= capturedAt
    }

    private static func visibleCGWindows(for processIdentifier: pid_t) -> [CGWindowMetadata] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawWindowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawWindowList.compactMap { windowInfo in
            guard
                intValue(windowInfo[kCGWindowLayer as String]) == 0,
                intValue(windowInfo[kCGWindowOwnerPID as String]) == Int(processIdentifier),
                let windowID = uint32Value(windowInfo[kCGWindowNumber as String]),
                let frame = cgRect(from: windowInfo[kCGWindowBounds as String]),
                frame.width > 0,
                frame.height > 0
            else {
                return nil
            }

            return CGWindowMetadata(
                windowID: windowID,
                title: windowInfo[kCGWindowName as String] as? String ?? "",
                frame: frame
            )
        }
    }

    private static func matchingCGWindowID(
        title: String,
        frame: CGRect?,
        in cgWindows: [CGWindowMetadata],
        usedWindowIDs: Set<UInt32>
    ) -> UInt32? {
        let availableWindows = cgWindows.filter { !usedWindowIDs.contains($0.windowID) }

        if let frame {
            if let exactFrameAndTitleMatch = uniqueCGWindow(
                in: availableWindows,
                matching: {
                    $0.frame.isApproximatelyEqual(to: frame, tolerance: frameTolerance) &&
                        titlesMatchForCorrelation($0.title, title)
                }
            ) {
                return exactFrameAndTitleMatch.windowID
            }

            if let frameMatch = uniqueCGWindow(
                in: availableWindows,
                matching: { $0.frame.isApproximatelyEqual(to: frame, tolerance: frameTolerance) }
            ) {
                return frameMatch.windowID
            }
        }

        guard !title.isEmpty else {
            return nil
        }

        return uniqueCGWindow(
            in: availableWindows,
            matching: { titlesMatchForCorrelation($0.title, title) }
        )?.windowID
    }

    private static func uniqueCGWindow(
        in windows: [CGWindowMetadata],
        matching predicate: (CGWindowMetadata) -> Bool
    ) -> CGWindowMetadata? {
        let matches = windows.filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func titlesMatchForCorrelation(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return false
        }

        return normalizedTitle(lhs) == normalizedTitle(rhs)
    }

    private static func cgRect(from value: Any?) -> CGRect? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }

        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let integer as Int:
            integer
        default:
            nil
        }
    }

    private static func uint32Value(_ value: Any?) -> UInt32? {
        switch value {
        case let number as NSNumber:
            number.uint32Value
        case let integer as UInt32:
            integer
        case let integer as Int where integer >= 0:
            UInt32(integer)
        default:
            nil
        }
    }

    private func liveWindows(
        bundleIdentifier: String,
        processIdentifier: Int32?,
        includeSkippedWindows: Bool
    ) throws -> [AXWindow] {
        guard AccessibilityManager.isTrusted() else {
            AppLog.accessibility.warning("Window move blocked because Accessibility permission is missing")
            throw WindowMoverError.accessibilityPermissionMissing
        }

        let applications = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { application in
                guard let processIdentifier else {
                    return true
                }

                return application.processIdentifier == processIdentifier
            }

        guard !applications.isEmpty else {
            throw WindowMoverError.appNotRunning(bundleIdentifier: bundleIdentifier)
        }

        let windows = applications.flatMap { application in
            appWindows(
                for: application,
                bundleIdentifier: bundleIdentifier,
                includeSkippedWindows: includeSkippedWindows
            )
        }

        return windows
    }

    private func appWindows(
        for application: NSRunningApplication,
        bundleIdentifier: String,
        includeSkippedWindows: Bool
    ) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let rawWindows = copyAttribute(kAXWindowsAttribute, from: appElement) as? [AXUIElement] else {
            return []
        }

        let cgWindows = Self.visibleCGWindows(for: application.processIdentifier)
        var usedCGWindowIDs = Set<UInt32>()

        let attributes = [
            kAXRoleAttribute,
            kAXTitleAttribute,
            kAXIdentifierAttribute,
            kAXMinimizedAttribute,
            "AXFullScreen",
            kAXPositionAttribute,
            kAXSizeAttribute
        ]
        var windows: [AXWindow] = []

        for window in rawWindows {
            let values: [Any]
            switch copyAttributes(attributes, from: window) {
            case let .values(readValues):
                values = readValues
            case .cannotComplete:
                AppLog.windows.warning(
                    "Aborting AX enumeration for unresponsive pid \(application.processIdentifier)"
                )
                return windows
            case .failed:
                continue
            }

            let role = value(at: 0, in: values, as: String.self) ?? ""
            let title = value(at: 1, in: values, as: String.self) ?? ""
            let accessibilityIdentifier = value(at: 2, in: values, as: String.self)
            let isMinimized = value(at: 3, in: values, as: Bool.self) ?? false
            let isFullscreen = value(at: 4, in: values, as: Bool.self) ?? false

            guard role == kAXWindowRole as String else {
                continue
            }

            guard includeSkippedWindows || (!isMinimized && !isFullscreen) else {
                continue
            }

            let frame = frame(
                positionValue: values.indices.contains(5) ? values[5] : nil,
                sizeValue: values.indices.contains(6) ? values[6] : nil
            )
            let cgWindowID = Self.matchingCGWindowID(
                title: title,
                frame: frame,
                in: cgWindows,
                usedWindowIDs: usedCGWindowIDs
            )
            if let cgWindowID {
                usedCGWindowIDs.insert(cgWindowID)
            }

            let candidate = WindowMoveCandidate(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: application.processIdentifier,
                processLaunchDate: application.launchDate,
                cgWindowID: cgWindowID,
                accessibilityIdentifier: accessibilityIdentifier,
                title: title,
                normalizedTitle: Self.normalizedTitle(title),
                role: role,
                isMinimized: isMinimized,
                isFullscreen: isFullscreen,
                frame: frame,
                axElementHash: CFHash(window)
            )

            windows.append(AXWindow(element: window, candidate: candidate))
        }

        return windows
    }

    private func readFrame(from element: AXUIElement) -> CGRect? {
        guard case let .values(values) = copyAttributes(
            [kAXPositionAttribute, kAXSizeAttribute],
            from: element
        ) else {
            return nil
        }

        return frame(
            positionValue: values.indices.contains(0) ? values[0] : nil,
            sizeValue: values.indices.contains(1) ? values[1] : nil
        )
    }

    private func writePosition(_ position: CGPoint, to element: AXUIElement) -> Bool {
        var mutablePosition = position
        guard let axValue = AXValueCreate(.cgPoint, &mutablePosition) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue) == .success
    }

    private func writeSize(_ size: CGSize, to element: AXUIElement) -> Bool {
        var mutableSize = size
        guard let axValue = AXValueCreate(.cgSize, &mutableSize) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue) == .success
    }

    private func moveWindow(
        _ window: AXWindow,
        to frame: CGRect,
        attempts: Int,
        bundleIdentifier: String
    ) async throws -> CGRect {
        try Task.checkCancellation()
        await prepareForMove(window)
        try Task.checkCancellation()

        let attemptCount = max(1, attempts)

        for _ in 0..<attemptCount {
            try Task.checkCancellation()
            _ = writePosition(frame.origin, to: window.element)
            _ = writeSize(frame.size, to: window.element)
            _ = writePosition(frame.origin, to: window.element)

            guard let verifiedFrame = readFrame(from: window.element) else {
                continue
            }

            if verifiedFrame.isApproximatelyEqual(to: frame, tolerance: Self.frameTolerance) {
                return verifiedFrame
            }
        }

        AppLog.windows.warning(
            "Unable to verify moved window for bundle \(bundleIdentifier, privacy: .public)"
        )

        throw WindowMoverError.frameWriteFailed
    }

    private func prepareForMove(_ window: AXWindow) async {
        var requestedStateChange = false

        if window.candidate.isFullscreen {
            let error = AXUIElementSetAttributeValue(
                window.element,
                "AXFullScreen" as CFString,
                kCFBooleanFalse
            )
            requestedStateChange = error == .success
        }

        if window.candidate.isMinimized {
            let error = AXUIElementSetAttributeValue(
                window.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
            requestedStateChange = requestedStateChange || error == .success
        }

        guard requestedStateChange else {
            return
        }

        // Full-screen transitions are asynchronous in AppKit. Poll briefly on
        // this background actor until the target exposes a normal window frame,
        // without ever blocking Perch's main actor.
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(100))

            guard case let .values(values) = copyAttributes(
                [kAXMinimizedAttribute, "AXFullScreen"],
                from: window.element
            ) else {
                return
            }

            let isMinimized = value(at: 0, in: values, as: Bool.self) ?? false
            let isFullscreen = value(at: 1, in: values, as: Bool.self) ?? false
            if !isMinimized && !isFullscreen {
                return
            }
        }
    }

    private func copyAttributes(
        _ attributes: [String],
        from element: AXUIElement
    ) -> AXAttributeReadResult {
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        )

        if error == .cannotComplete {
            return .cannotComplete
        }

        guard error == .success, let values = rawValues as? [Any] else {
            return .failed
        }

        if values.contains(where: { embeddedAXError(in: $0) == .cannotComplete }) {
            return .cannotComplete
        }

        return .values(values)
    }

    private func embeddedAXError(in value: Any) -> AXError? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else {
            return nil
        }

        var error = AXError.success
        return AXValueGetValue(axValue, .axError, &error) ? error : nil
    }

    private func value<T>(at index: Int, in values: [Any], as type: T.Type) -> T? {
        guard values.indices.contains(index) else {
            return nil
        }

        return values[index] as? T
    }

    private func frame(positionValue: Any?, sizeValue: Any?) -> CGRect? {
        guard
            let position = point(from: positionValue),
            let size = size(from: sizeValue)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func point(from value: Any?) -> CGPoint? {
        guard let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func size(from value: Any?) -> CGSize? {
        guard let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard error == .success else {
            return nil
        }

        return value
    }

    private static func tokenOverlapScore(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))

        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else {
            return 0
        }

        let overlap = lhsTokens.intersection(rhsTokens).count
        let total = lhsTokens.union(rhsTokens).count

        guard total > 0 else {
            return 0
        }

        return Double(overlap) / Double(total)
    }

    private static func editSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)

        guard !lhsCharacters.isEmpty, !rhsCharacters.isEmpty else {
            return lhsCharacters.isEmpty == rhsCharacters.isEmpty ? 1 : 0
        }

        let distance = levenshteinDistance(lhsCharacters, rhsCharacters)
        let longest = max(lhsCharacters.count, rhsCharacters.count)

        guard longest > 0 else {
            return 1
        }

        return max(0, 1 - (Double(distance) / Double(longest)))
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for lhsIndex in 1...lhs.count {
            current[0] = lhsIndex

            for rhsIndex in 1...rhs.count {
                let substitutionCost = lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
            }

            swap(&previous, &current)
        }

        return previous[rhs.count]
    }
}
