import CoreGraphics

struct OverlayScreenGeometry: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
    let isKey: Bool
    let isMain: Bool
}

enum OverlayWindowPlacement {
    static func targetScreenIndex(
        mouseLocation: CGPoint,
        screens: [OverlayScreenGeometry]
    ) -> Int? {
        let eligibleIndices = screens.indices.filter {
            !screens[$0].visibleFrame.isEmpty
        }

        return eligibleIndices.first {
            screens[$0].frame.contains(mouseLocation)
        } ?? eligibleIndices.first {
            screens[$0].isKey
        } ?? eligibleIndices.first {
            screens[$0].isMain
        } ?? eligibleIndices.first
    }

    static func topCenterOrigin(
        windowSize: CGSize,
        visibleFrame: CGRect,
        topInset: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.maxY - windowSize.height - topInset
        )
    }
}
