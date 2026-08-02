import ApplicationServices
import CoreGraphics
import XCTest

@MainActor
final class WindowSnapshotterTests: XCTestCase {
    func testOnlyCannotCompleteIsClassifiedAsIncompleteCapture() {
        XCTAssertTrue(WindowSnapshotter.isIncompleteAccessibilityError(.cannotComplete))
        XCTAssertFalse(WindowSnapshotter.isIncompleteAccessibilityError(.attributeUnsupported))
        XCTAssertFalse(WindowSnapshotter.isIncompleteAccessibilityError(.invalidUIElement))
    }

    func testMatchPrefersUniqueExactTitle() {
        let windows = [
            metadata(title: "Inbox", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "Budget", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertEqual(match?.title, "Budget")
    }

    func testMatchFallsBackToFrameWhenTitlesUnavailable() {
        let windows = [
            metadata(title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "", frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "",
            cgFrame: CGRect(x: 901, y: 1, width: 799, height: 600)
        )

        XCTAssertEqual(match?.frame, CGRect(x: 900, y: 0, width: 800, height: 600))
    }

    func testMatchUsesCaseInsensitiveTitleFallback() {
        let windows = [
            metadata(title: "BUDGET", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "Inbox", frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertEqual(match?.title, "BUDGET")
    }

    func testMatchFallsBackToOnlyWindowWhenCGTitleIsUnavailable() {
        let windows = [
            metadata(title: "Something Else", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertEqual(match?.title, "Something Else")
    }

    func testMatchReturnsNilWhenAmbiguous() {
        let windows = [
            metadata(title: "Untitled", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "Untitled", frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Untitled",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertNil(match)
    }

    func testMatchIgnoresNonWindowRoles() {
        let windows = [
            metadata(title: "Budget", role: "AXSheet", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertNil(match)
    }

    func testMatchPrefersExactTitleOverFrameMatch() {
        let windows = [
            metadata(title: "Budget", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "Other", frame: CGRect(x: 500, y: 500, width: 100, height: 100))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertEqual(match?.title, "Budget")
    }

    func testMatchFrameToleranceBoundary() {
        let windows = [
            metadata(title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "", frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        ]

        let withinTolerance = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "",
            cgFrame: CGRect(x: 902, y: 0, width: 800, height: 600)
        )
        let beyondTolerance = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "",
            cgFrame: CGRect(x: 903, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(withinTolerance?.frame, CGRect(x: 900, y: 0, width: 800, height: 600))
        XCTAssertNil(beyondTolerance)
    }

    func testMatchDoesNotReuseAXWindowAlreadyAssignedToAnotherCGWindow() {
        let windows = [
            metadata(title: "Budget", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "Inbox", frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        ]

        let firstIndex = WindowSnapshotter.matchAXWindowIndex(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            excluding: []
        )
        guard let firstIndex else {
            XCTFail("Expected the first CG window to match an AX window")
            return
        }
        let secondIndex = WindowSnapshotter.matchAXWindowIndex(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            excluding: Set([firstIndex])
        )

        XCTAssertEqual(firstIndex, 0)
        XCTAssertNil(secondIndex)
    }

    private func metadata(
        title: String,
        role: String = "AXWindow",
        frame: CGRect?
    ) -> WindowSnapshotter.AXWindowMetadata {
        WindowSnapshotter.AXWindowMetadata(
            title: title,
            role: role,
            isMinimized: false,
            isFullscreen: false,
            accessibilityIdentifier: nil,
            frame: frame
        )
    }
}
