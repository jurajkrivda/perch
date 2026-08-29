import CoreGraphics
import XCTest

final class OverlayWindowPlacementTests: XCTestCase {
    func testMouseScreenWinsOverKeyAndMainScreens() throws {
        let screens = [
            screen(x: 0, isKey: true, isMain: true),
            screen(x: 1_920)
        ]

        XCTAssertEqual(
            OverlayWindowPlacement.targetScreenIndex(
                mouseLocation: CGPoint(x: 2_500, y: 500),
                screens: screens
            ),
            1
        )
    }

    func testNegativeOriginMouseScreenIsSelected() {
        let screens = [
            screen(x: 0, isMain: true),
            screen(x: -1_920)
        ]

        XCTAssertEqual(
            OverlayWindowPlacement.targetScreenIndex(
                mouseLocation: CGPoint(x: -500, y: 500),
                screens: screens
            ),
            1
        )
    }

    func testKeyScreenWinsWhenMouseIsOutsideAllScreens() {
        let screens = [
            screen(x: 0, isMain: true),
            screen(x: 1_920, isKey: true)
        ]

        XCTAssertEqual(
            OverlayWindowPlacement.targetScreenIndex(
                mouseLocation: CGPoint(x: 9_000, y: 9_000),
                screens: screens
            ),
            1
        )
    }

    func testMainThenFirstScreenAreFallbacks() {
        XCTAssertEqual(
            OverlayWindowPlacement.targetScreenIndex(
                mouseLocation: CGPoint(x: 9_000, y: 9_000),
                screens: [screen(x: 0), screen(x: 1_920, isMain: true)]
            ),
            1
        )
        XCTAssertEqual(
            OverlayWindowPlacement.targetScreenIndex(
                mouseLocation: CGPoint(x: 9_000, y: 9_000),
                screens: [screen(x: 0), screen(x: 1_920)]
            ),
            0
        )
    }

    func testEmptyOrInvisibleScreensHaveNoTarget() {
        XCTAssertNil(OverlayWindowPlacement.targetScreenIndex(
            mouseLocation: .zero,
            screens: []
        ))
        XCTAssertNil(OverlayWindowPlacement.targetScreenIndex(
            mouseLocation: .zero,
            screens: [OverlayScreenGeometry(
                frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                visibleFrame: .zero,
                isKey: true,
                isMain: true
            )]
        ))
    }

    func testTopCenterOriginUsesSelectedVisibleFrame() {
        let origin = OverlayWindowPlacement.topCenterOrigin(
            windowSize: CGSize(width: 400, height: 80),
            visibleFrame: CGRect(x: 1_920, y: 23, width: 2_560, height: 1_417),
            topInset: 72
        )

        XCTAssertEqual(origin.x, 3_000)
        XCTAssertEqual(origin.y, 1_288)
    }

    private func screen(
        x: CGFloat,
        isKey: Bool = false,
        isMain: Bool = false
    ) -> OverlayScreenGeometry {
        let frame = CGRect(x: x, y: 0, width: 1_920, height: 1_080)
        return OverlayScreenGeometry(
            frame: frame,
            visibleFrame: frame,
            isKey: isKey,
            isMain: isMain
        )
    }
}
