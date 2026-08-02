import ColorSync
import CoreGraphics
import Foundation

struct DisplayInfo: Equatable, Sendable {
    let id: CGDirectDisplayID
    let uuid: String
    let bounds: CGRect
    let isMain: Bool
}

enum DisplayManager {
    static func currentDisplays() -> [DisplayInfo] {
        readCurrentDisplays().displays
    }

    /// Returns a fingerprint only when every active Core Graphics display has
    /// a stable UUID. During slow dock negotiation CG can report display IDs
    /// before their UUIDs are available; treating that partial list as complete
    /// could incorrectly match a smaller saved topology.
    static func currentTopologyFingerprint() -> DisplayTopologyFingerprint? {
        let read = readCurrentDisplays()
        return topologyFingerprint(
            displays: read.displays,
            activeDisplayCount: read.activeDisplayCount
        )
    }

    static func topologyFingerprint(
        displays: [DisplayInfo],
        activeDisplayCount: Int
    ) -> DisplayTopologyFingerprint? {
        guard activeDisplayCount > 0,
              displays.count == activeDisplayCount
        else {
            AppLog.display.warning(
                "Display topology incomplete: mapped=\(displays.count), active=\(activeDisplayCount)"
            )
            return nil
        }

        return DisplayTopologyFingerprint(displays: displays)
    }

    private static func readCurrentDisplays() -> (
        displays: [DisplayInfo],
        activeDisplayCount: Int
    ) {
        var displayCount: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &displayCount)

        guard countResult == .success else {
            AppLog.display.error("Failed to count active displays: \(countResult.rawValue)")
            return ([], 0)
        }

        guard displayCount > 0 else {
            AppLog.display.warning("No active displays found")
            return ([], 0)
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listResult = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }

        guard listResult == .success else {
            AppLog.display.error("Failed to read active displays: \(listResult.rawValue)")
            return ([], Int(displayCount))
        }

        let activeDisplayCount = Int(displayCount)
        let mainDisplayID = CGMainDisplayID()
        let displays = displayIDs
            .prefix(activeDisplayCount)
            .compactMap { displayInfo(for: $0, mainDisplayID: mainDisplayID) }

        AppLog.display.debug("Mapped \(displays.count) of \(activeDisplayCount) active displays")
        return (displays, activeDisplayCount)
    }

    static func display(withUUID uuid: String, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.uuid == uuid }
    }

    static func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        let containingDisplay = displays.first { $0.bounds.contains(point) }

        if let containingDisplay {
            return containingDisplay
        }

        AppLog.display.debug("No display contains point x=\(point.x), y=\(point.y); falling back to nearest display")
        return nearestDisplay(to: point, in: displays)
    }

    static func display(containing frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let display = displays
            .map({ display in
                (display: display, intersectionArea: intersectionArea(display.bounds, frame))
            })
            .filter({ $0.intersectionArea > 0 })
            .max(by: { $0.intersectionArea < $1.intersectionArea })?
            .display {
            return display
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        AppLog.display.debug("No display intersects frame x=\(frame.origin.x), y=\(frame.origin.y), width=\(frame.width), height=\(frame.height); falling back to center point")
        return display(containing: center, in: displays)
    }

    static func localFrame(for frame: CGRect, in display: DisplayInfo) -> CGRect {
        frame.offsetBy(dx: -display.bounds.origin.x, dy: -display.bounds.origin.y)
    }

    private static func displayInfo(for displayID: CGDirectDisplayID, mainDisplayID: CGDirectDisplayID) -> DisplayInfo? {
        guard let uuid = uuidString(for: displayID) else {
            AppLog.display.warning("Skipping display \(displayID) because its UUID is unavailable")
            return nil
        }

        let bounds = CGDisplayBounds(displayID)
        let display = DisplayInfo(
            id: displayID,
            uuid: uuid,
            bounds: bounds,
            isMain: displayID == mainDisplayID
        )

        AppLog.display.debug("Display mapped id=\(display.id), uuid=\(display.uuid, privacy: .public), x=\(bounds.origin.x), y=\(bounds.origin.y), width=\(bounds.width), height=\(bounds.height), isMain=\(display.isMain)")
        return display
    }

    private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid) else {
            return nil
        }

        return uuidString as String
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)

        guard !intersection.isNull && !intersection.isEmpty else {
            return 0
        }

        return intersection.width * intersection.height
    }

    private static func nearestDisplay(to point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.min { lhs, rhs in
            squaredDistance(from: point, to: lhs.bounds) < squaredDistance(from: point, to: rhs.bounds)
        }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, rect.minX), rect.maxX)
        let nearestY = min(max(point.y, rect.minY), rect.maxY)
        let deltaX = point.x - nearestX
        let deltaY = point.y - nearestY

        return deltaX * deltaX + deltaY * deltaY
    }
}
