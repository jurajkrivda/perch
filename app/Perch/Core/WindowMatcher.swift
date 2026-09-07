import Foundation

/// Pure one-to-one matching. No Accessibility objects or window writes.
enum WindowMatcher {
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

    private static func candidateMatches(
        _ candidate: WindowMoveCandidate,
        title: String,
        strictness: MatchStrictness
    ) -> Bool {
        switch strictness {
        case .strict:
            candidate.normalizedTitle == WindowTitleSimilarity.normalize(title)
        case .fuzzy:
            WindowTitleSimilarity.score(candidate: candidate.title, target: title) >= Self.minimumTitleScore
        case .loose:
            WindowTitleSimilarity.score(candidate: candidate.title, target: title) >= 0.15 || candidate.title.isEmpty
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
                titleScore: WindowTitleSimilarity.score(candidate: candidate.title, target: request.title)
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
        let normalizedTarget = WindowTitleSimilarity.normalize(request.title)
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

    static func reservation(for candidate: WindowMoveCandidate) -> WindowCandidateReservation {
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

}
