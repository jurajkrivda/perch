import CoreGraphics
import XCTest

@MainActor
final class WindowMoverTests: XCTestCase {
    func testNormalizedTitleTrimsWhitespaceCaseAndDiacritics() {
        XCTAssertEqual(
            WindowMover.normalizedTitle("  Prilis ZLUTOUCKY  kun  "),
            "prilis zlutoucky kun"
        )
    }

    func testFuzzyTitleScorePrefersExactAndContainedTitles() {
        let exactScore = WindowMover.fuzzyTitleScore(
            candidate: "Project Plan - Pages",
            target: "Project Plan - Pages"
        )
        let containedScore = WindowMover.fuzzyTitleScore(
            candidate: "Project Plan - Pages",
            target: "Project Plan"
        )
        let unrelatedScore = WindowMover.fuzzyTitleScore(
            candidate: "Inbox - Mail",
            target: "Project Plan"
        )

        XCTAssertEqual(exactScore, 1)
        XCTAssertGreaterThan(containedScore, unrelatedScore)
        XCTAssertGreaterThan(containedScore, 0.7)
    }

    func testBestWindowSelectionFallsBackToOnlyWindowWhenBrowserTitleChanged() {
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(
                    title: "New Tab – Brave",
                    frame: CGRect(x: -2560, y: -1440, width: 2560, height: 1440)
                )
            ],
            title: "⁨From⁩ • HBO Max – Brave",
            strictness: .fuzzy
        )

        XCTAssertEqual(selection, WindowMover.WindowSelection(index: 0, reason: .singleCandidateFallback))
    }

    func testBestWindowSelectionDoesNotGuessWhenSeveralBrowserWindowsChangedTitle() {
        let target = "⁨From⁩ • HBO Max – Brave"
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(title: "New Tab – Brave"),
                candidate(title: "Downloads – Brave")
            ],
            title: target,
            strictness: .fuzzy
        )

        XCTAssertNil(selection)
    }

    func testBestWindowSelectionPrefersTitleMatchWhenSeveralWindowsExist() {
        let target = "Budget"
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(title: "Inbox – Mail"),
                candidate(title: "Budget 2026 – Numbers")
            ],
            title: target,
            strictness: .fuzzy
        )

        XCTAssertEqual(selection, WindowMover.WindowSelection(index: 1, reason: .titleMatch))
    }

    func testBestWindowSelectionIncludesMinimizedAndFullscreenCandidatesForRestore() {
        let minimizedSelection = WindowMover.bestWindowSelection(
            in: [candidate(title: "Budget", isMinimized: true)],
            title: "Budget",
            strictness: .strict
        )
        let fullscreenSelection = WindowMover.bestWindowSelection(
            in: [candidate(title: "Inbox", isFullscreen: true)],
            title: "Inbox",
            strictness: .strict
        )

        XCTAssertEqual(minimizedSelection, WindowMover.WindowSelection(index: 0, reason: .titleMatch))
        XCTAssertEqual(fullscreenSelection, WindowMover.WindowSelection(index: 0, reason: .titleMatch))
    }

    func testBestWindowSelectionRejectsAmbiguousSimilarTitleMatches() {
        let target = "Budget"
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(title: "Budget 2025 – Numbers"),
                candidate(title: "Budget 2026 – Numbers")
            ],
            title: target,
            strictness: .fuzzy
        )

        XCTAssertNil(selection)
    }

    func testBestWindowSelectionUsesExactTitleOverFuzzyTitle() {
        let target = "Budget"
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(title: "Budget 2026 – Numbers"),
                candidate(title: "Budget")
            ],
            title: target,
            strictness: .fuzzy
        )

        XCTAssertEqual(selection, WindowMover.WindowSelection(index: 1, reason: .titleMatch))
    }

    func testBestWindowSelectionPrefersCGWindowIDWhenTitlesChanged() {
        let target = "⁨From⁩ • HBO Max – Brave"
        let capturedAt = Date(timeIntervalSince1970: 1_779_190_400)
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(title: "New Tab – Brave", cgWindowID: 41),
                candidate(title: "Downloads – Brave", cgWindowID: 42)
            ],
            matching: WindowMover.WindowMatchRequest(
                title: target,
                processIdentifier: 1234,
                capturedAt: capturedAt,
                cgWindowID: 42
            ),
            strictness: .fuzzy
        )

        XCTAssertEqual(selection, WindowMover.WindowSelection(index: 1, reason: .cgWindowID))
    }

    func testBestWindowSelectionDoesNotTrustReusedCGWindowIDAfterProcessRelaunch() {
        let capturedAt = Date(timeIntervalSince1970: 1_779_190_400)
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(
                    title: "New Tab – Brave",
                    processLaunchDate: capturedAt.addingTimeInterval(60),
                    cgWindowID: 42
                ),
                candidate(
                    title: "Downloads – Brave",
                    processLaunchDate: capturedAt.addingTimeInterval(60),
                    cgWindowID: 43
                )
            ],
            matching: WindowMover.WindowMatchRequest(
                title: "Saved Window That No Longer Exists",
                processIdentifier: 1234,
                capturedAt: capturedAt,
                cgWindowID: 42
            ),
            strictness: .fuzzy
        )

        XCTAssertNil(selection)
    }

    func testBestWindowSelectionDoesNotTrustCGWindowIDWithoutLaunchDate() {
        let capturedAt = Date(timeIntervalSince1970: 1_779_190_400)
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(title: "New Tab", processLaunchDate: nil, cgWindowID: 42),
                candidate(title: "Downloads", processLaunchDate: nil, cgWindowID: 43)
            ],
            matching: WindowMover.WindowMatchRequest(
                title: "Old Saved Title",
                processIdentifier: 1234,
                capturedAt: capturedAt,
                cgWindowID: 42
            ),
            strictness: .fuzzy
        )

        XCTAssertNil(selection)
    }

    func testBestWindowSelectionPrefersAccessibilityIdentifierWhenAvailable() {
        let target = "Budget"
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(title: "Budget Copy", accessibilityIdentifier: "window-copy"),
                candidate(title: "Budget Draft", accessibilityIdentifier: "window-main")
            ],
            matching: WindowMover.WindowMatchRequest(
                title: target,
                accessibilityIdentifier: "window-main"
            ),
            strictness: .fuzzy
        )

        XCTAssertEqual(selection, WindowMover.WindowSelection(index: 1, reason: .accessibilityIdentifier))
    }

    func testBestWindowSelectionDoesNotFallbackWhenOnlyWindowHasDifferentAccessibilityIdentifier() {
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(
                    title: "New Window",
                    accessibilityIdentifier: "live-window"
                )
            ],
            matching: WindowMover.WindowMatchRequest(
                title: "Saved Window",
                accessibilityIdentifier: "saved-window"
            ),
            strictness: .fuzzy
        )

        XCTAssertNil(selection)
    }

    func testBestWindowSelectionAllowsFallbackWhenSavedProcessIdentityIsStale() {
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(
                    title: "New Tab - Brave",
                    accessibilityIdentifier: "live-window"
                )
            ],
            matching: WindowMover.WindowMatchRequest(
                title: "Saved Browser Window",
                accessibilityIdentifier: "saved-window",
                rejectsConflictingAccessibilityIdentifier: false
            ),
            strictness: .fuzzy
        )

        XCTAssertEqual(selection, WindowMover.WindowSelection(index: 0, reason: .singleCandidateFallback))
    }

    func testBestWindowSelectionsAssignsMultipleExactMatchesOnce() {
        let selections = WindowMover.bestWindowSelections(
            in: [
                candidate(title: "Budget - Chrome"),
                candidate(title: "Inbox - Chrome")
            ],
            matching: [
                WindowMover.WindowMatchRequest(title: "Inbox - Chrome"),
                WindowMover.WindowMatchRequest(title: "Budget - Chrome")
            ],
            strictness: .fuzzy
        )

        XCTAssertEqual(selections[0], WindowMover.WindowSelection(index: 1, reason: .titleMatch))
        XCTAssertEqual(selections[1], WindowMover.WindowSelection(index: 0, reason: .titleMatch))
        XCTAssertEqual(Set(selections.values.map(\.index)).count, selections.count)
    }

    func testBestWindowSelectionsDoesNotReuseOneLiveWindowForSeveralSavedWindows() {
        let selections = WindowMover.bestWindowSelections(
            in: [
                candidate(title: "Inbox - Chrome")
            ],
            matching: [
                WindowMover.WindowMatchRequest(title: "Inbox - Chrome"),
                WindowMover.WindowMatchRequest(title: "Budget - Chrome")
            ],
            strictness: .fuzzy
        )

        XCTAssertEqual(selections[0], WindowMover.WindowSelection(index: 0, reason: .titleMatch))
        XCTAssertNil(selections[1])
    }

    func testLiveReservationWinsAfterTitleChangesAndPreventsFalseSecondSuccess() {
        let launchDate = Date(timeIntervalSince1970: 1_779_190_300)
        let reservation = WindowCandidateReservation(
            processIdentifier: 1234,
            processLaunchDate: launchDate,
            cgWindowID: nil,
            axElementHash: 77
        )
        let selections = WindowMover.bestWindowSelections(
            in: [
                candidate(
                    title: "Second Saved Window",
                    processLaunchDate: launchDate,
                    axElementHash: 77
                )
            ],
            matching: [
                WindowMover.WindowMatchRequest(
                    title: "First Saved Window",
                    reservation: reservation
                ),
                WindowMover.WindowMatchRequest(title: "Second Saved Window")
            ],
            strictness: .fuzzy
        )

        XCTAssertEqual(selections[0], WindowMover.WindowSelection(index: 0, reason: .cgWindowID))
        XCTAssertNil(selections[1], "The pending snapshot must not claim the already-restored physical window")
    }

    func testLiveReservationDoesNotFallBackToDifferentWindowWithSameTitle() {
        let launchDate = Date(timeIntervalSince1970: 1_779_190_300)
        let selection = WindowMover.bestWindowSelection(
            in: [
                candidate(
                    title: "First Saved Window",
                    processLaunchDate: launchDate,
                    axElementHash: 88
                )
            ],
            matching: WindowMover.WindowMatchRequest(
                title: "First Saved Window",
                reservation: WindowCandidateReservation(
                    processIdentifier: 1234,
                    processLaunchDate: launchDate,
                    cgWindowID: nil,
                    axElementHash: 77
                )
            ),
            strictness: .fuzzy
        )

        XCTAssertNil(selection, "A reserved snapshot must wait for its exact live window")
    }

    func testUnresolvedSelectionIsRetryableWhenAllCurrentCandidatesAreReserved() {
        let error = WindowMover.unresolvedSelectionError(
            bundleIdentifier: "com.brave.Browser",
            title: "Second Saved Window",
            candidateCount: 1,
            usedCandidateIndices: [0]
        )

        XCTAssertEqual(
            error,
            .windowNotFound(
                bundleIdentifier: "com.brave.Browser",
                title: "Second Saved Window"
            )
        )
    }

    func testUnresolvedSelectionIsAmbiguousWhenUnusedCandidatesRemain() {
        let error = WindowMover.unresolvedSelectionError(
            bundleIdentifier: "com.brave.Browser",
            title: "Saved Window",
            candidateCount: 2,
            usedCandidateIndices: [0]
        )

        XCTAssertEqual(
            error,
            .ambiguousWindowMatch(
                bundleIdentifier: "com.brave.Browser",
                title: "Saved Window"
            )
        )
    }

    func testBestWindowSelectionsDoesNotGuessOneSavedWindowAmongSeveralNewBrowserWindows() {
        let selections = WindowMover.bestWindowSelections(
            in: [
                candidate(title: "New Tab - Brave"),
                candidate(title: "Downloads - Brave")
            ],
            matching: [
                WindowMover.WindowMatchRequest(title: "Saved Browser Window")
            ],
            strictness: .fuzzy
        )

        XCTAssertNil(selections[0])
    }

    private func candidate(
        title: String,
        processLaunchDate: Date? = Date(timeIntervalSince1970: 1_779_190_300),
        cgWindowID: UInt32? = nil,
        accessibilityIdentifier: String? = nil,
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        frame: CGRect? = CGRect(x: 0, y: 0, width: 1200, height: 800),
        axElementHash: UInt = 0
    ) -> WindowMoveCandidate {
        WindowMoveCandidate(
            bundleIdentifier: "com.brave.Browser",
            processIdentifier: 1234,
            processLaunchDate: processLaunchDate,
            cgWindowID: cgWindowID,
            accessibilityIdentifier: accessibilityIdentifier,
            title: title,
            normalizedTitle: WindowMover.normalizedTitle(title),
            role: "AXWindow",
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            frame: frame,
            axElementHash: axElementHash
        )
    }
}
