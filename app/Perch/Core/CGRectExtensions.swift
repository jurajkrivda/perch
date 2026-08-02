import CoreGraphics

extension CGRect {
    var isValidWindowFrame: Bool {
        origin.x.isFinite &&
            origin.y.isFinite &&
            size.width.isFinite &&
            size.height.isFinite &&
            width > 0 &&
            height > 0
    }

    var area: CGFloat {
        guard width > 0, height > 0 else {
            return 0
        }

        return width * height
    }

    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(size.width - other.size.width) <= tolerance &&
            abs(size.height - other.size.height) <= tolerance
    }

    /// Assumes `self.isValidWindowFrame` and non-empty `bounds`; results are undefined otherwise.
    func clamped(to bounds: CGRect) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let x = min(max(origin.x, bounds.minX), bounds.maxX - width)
        let y = min(max(origin.y, bounds.minY), bounds.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }
}
