import CoreGraphics
import Foundation

enum CGWindowCatalog {
    struct CGWindowMetadata {
        var windowID: UInt32
        var title: String
        var frame: CGRect
    }

    static func visibleWindows(for processIdentifier: pid_t) -> [CGWindowMetadata] {
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

    static func matchingWindowID(
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
                    $0.frame.isApproximatelyEqual(to: frame, tolerance: 2) &&
                        titlesMatchForCorrelation($0.title, title)
                }
            ) {
                return exactFrameAndTitleMatch.windowID
            }

            if let frameMatch = uniqueCGWindow(
                in: availableWindows,
                matching: { $0.frame.isApproximatelyEqual(to: frame, tolerance: 2) }
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

        return WindowTitleSimilarity.normalize(lhs) == WindowTitleSimilarity.normalize(rhs)
    }

    static func cgRect(from value: Any?) -> CGRect? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }

        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let integer as Int:
            integer
        default:
            nil
        }
    }

    static func uint32Value(_ value: Any?) -> UInt32? {
        switch value {
        case let number as NSNumber:
            UInt32(exactly: number.doubleValue)
        case let integer as UInt32:
            integer
        case let integer as Int where integer >= 0:
            UInt32(exactly: integer)
        default:
            nil
        }
    }

}
