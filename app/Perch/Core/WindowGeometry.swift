import Foundation

enum WindowGeometry {
    nonisolated static func targetFrame(for snapshot: WindowSnapshot, displays: [DisplayInfo]) -> CGRect {
        let savedFrame = snapshot.frame.cgRect

        guard let displayLocalFrame = snapshot.displayLocalFrame?.cgRect else {
            return rescuedFrame(savedFrame, on: DisplayManager.display(containing: savedFrame, in: displays))
        }

        let display = snapshot.displayUUID.flatMap { DisplayManager.display(withUUID: $0, in: displays) }
            ?? DisplayManager.display(containing: savedFrame, in: displays)

        guard let display else {
            return savedFrame
        }

        let globalFrame = displayLocalFrame.offsetBy(
            dx: display.bounds.origin.x,
            dy: display.bounds.origin.y
        )

        return rescuedFrame(globalFrame, on: display)
    }

    /// Restores faithfully whenever the frame is at least partially visible on its display;
    /// clamps into the display only when the window would otherwise be completely offscreen.
    private nonisolated static func rescuedFrame(_ frame: CGRect, on display: DisplayInfo?) -> CGRect {
        guard let display, !display.bounds.isEmpty else {
            return frame
        }

        guard !display.bounds.intersects(frame) else {
            return frame
        }

        return frame.clamped(to: display.bounds)
    }}
