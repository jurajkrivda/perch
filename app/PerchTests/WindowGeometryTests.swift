import CoreGraphics
import Foundation
import XCTest

final class WindowGeometryTests: XCTestCase {
    func testClampedKeepsFrameAlreadyInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

        XCTAssertEqual(frame.clamped(to: bounds), frame)
    }

    func testClampedShrinksOversizedFrameToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

        XCTAssertEqual(frame.clamped(to: bounds), bounds)
    }

    func testClampedMovesOffscreenOriginInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 2000, y: 850, width: 1200, height: 600)

        XCTAssertEqual(
            frame.clamped(to: bounds),
            CGRect(x: 240, y: 300, width: 1200, height: 600)
        )
    }

    func testClampedHandlesDisplaysWithNegativeOrigin() {
        let bounds = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let frame = CGRect(x: -3000, y: -100, width: 800, height: 600)

        XCTAssertEqual(
            frame.clamped(to: bounds),
            CGRect(x: -2560, y: 0, width: 800, height: 600)
        )
    }

    // MARK: - SlotEngine.targetFrame

    private let mainDisplay = DisplayInfo(
        id: 1,
        uuid: "MAIN",
        bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
        isMain: true
    )
    private let sideDisplay = DisplayInfo(
        id: 2,
        uuid: "SIDE",
        bounds: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
        isMain: false
    )

    func testTargetFrameMapsLocalFrameOntoSavedDisplay() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 1540, y: 100, width: 800, height: 600),
            displayUUID: "SIDE",
            localFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay, sideDisplay])

        XCTAssertEqual(target, CGRect(x: 1540, y: 100, width: 800, height: 600))
    }

    func testTargetFrameFallsBackToDisplayContainingSavedFrame() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 200, y: 100, width: 800, height: 600),
            displayUUID: "GONE",
            localFrame: CGRect(x: 200, y: 100, width: 800, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay])

        XCTAssertEqual(target, CGRect(x: 200, y: 100, width: 800, height: 600))
    }

    func testTargetFrameKeepsWindowHangingOverDisplayEdge() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 3440, y: 200, width: 1200, height: 600),
            displayUUID: "SIDE",
            localFrame: CGRect(x: 2000, y: 200, width: 1200, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay, sideDisplay])

        XCTAssertEqual(target, CGRect(x: 3440, y: 200, width: 1200, height: 600))
    }

    func testTargetFrameKeepsOversizedWindowThatStillIntersectsDisplay() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 100, y: 100, width: 2560, height: 1440),
            displayUUID: "GONE",
            localFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay])

        XCTAssertEqual(target, CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    func testTargetFrameRescuesWindowOffscreenAfterDisplayResize() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600),
            displayUUID: "MAIN",
            localFrame: CGRect(x: 2000, y: 100, width: 800, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay])

        XCTAssertEqual(target, CGRect(x: 640, y: 100, width: 800, height: 600))
    }

    func testTargetFrameKeepsPartiallyVisibleLegacySnapshot() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: -100, y: 850, width: 400, height: 300),
            displayUUID: nil,
            localFrame: nil
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay])

        XCTAssertEqual(target, CGRect(x: -100, y: 850, width: 400, height: 300))
    }

    func testTargetFrameRescuesFullyOffscreenLegacySnapshot() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 5000, y: 850, width: 400, height: 300),
            displayUUID: nil,
            localFrame: nil
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay])

        XCTAssertEqual(target, CGRect(x: 1040, y: 600, width: 400, height: 300))
    }

    func testTargetFrameReturnsSavedFrameWhenNoDisplays() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600),
            displayUUID: "MAIN",
            localFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [])

        XCTAssertEqual(target, CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    // MARK: - DisplayManager.display(containing:in:)
    // Pins the shared ownership heuristic used by both capture and restore.

    func testDisplayContainingFramePicksLargestIntersection() {
        let frame = CGRect(x: 900, y: 100, width: 800, height: 600)

        let display = DisplayManager.display(containing: frame, in: [mainDisplay, sideDisplay])

        XCTAssertEqual(display?.uuid, "MAIN")
    }

    func testDisplayContainingFullyOffscreenFrameFallsBackToNearestDisplay() {
        let frame = CGRect(x: 4200, y: 2000, width: 400, height: 300)

        let display = DisplayManager.display(containing: frame, in: [mainDisplay, sideDisplay])

        XCTAssertEqual(display?.uuid, "SIDE")
    }

    func testTargetFrameSkipsClampingForDegenerateDisplayBounds() {
        let brokenDisplay = DisplayInfo(
            id: 3,
            uuid: "BROKEN",
            bounds: CGRect(x: 0, y: 0, width: 0, height: 0),
            isMain: false
        )
        let snapshot = makeSnapshot(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600),
            displayUUID: "BROKEN",
            localFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [brokenDisplay])

        XCTAssertEqual(target, CGRect(x: 100, y: 100, width: 800, height: 600))
    }
}

private func makeSnapshot(
    frame: CGRect,
    displayUUID: String?,
    localFrame: CGRect?
) -> WindowSnapshot {
    WindowSnapshot(
        bundleIdentifier: "com.example.app",
        windowTitle: "Example",
        frame: CodableRect(frame),
        displayUUID: displayUUID,
        displayLocalFrame: localFrame.map { CodableRect($0) },
        windowRole: "AXWindow",
        processIdentifier: 100,
        capturedAt: Date(timeIntervalSince1970: 1_779_190_400)
    )
}
