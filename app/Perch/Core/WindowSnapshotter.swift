@preconcurrency import ApplicationServices
@preconcurrency import AppKit
import CoreGraphics
import Foundation

enum WindowSnapshotterError: LocalizedError {
    case accessibilityPermissionMissing
    case unableToCopyWindowList
    case incompleteAccessibilityRead(processIdentifier: Int32)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "Accessibility permission is required to capture windows."
        case .unableToCopyWindowList:
            "Unable to read the current window list."
        case let .incompleteAccessibilityRead(processIdentifier):
            "Window capture was incomplete because application \(processIdentifier) did not respond to Accessibility requests."
        }
    }
}

/// Captures windows on a serial actor so a slow Accessibility client never
/// stalls menu interaction or global hotkeys on the main actor.
actor WindowSnapshotter {
    struct AXWindowMetadata: Equatable, Sendable {
        let title: String
        let role: String
        let isMinimized: Bool
        let isFullscreen: Bool
        let accessibilityIdentifier: String?
        let frame: CGRect?
    }

    private enum AXAttributeReadResult {
        case values([Any])
        case cannotComplete
        case failed
    }

    private enum AXSingleAttributeReadResult {
        case value(CFTypeRef)
        case cannotComplete
        case failed
    }

    private static let excludedOwnerNames: Set<String> = [
        "Control Center",
        "Dock",
        "Notification Center",
        "SystemUIServer",
        "Window Server",
        "WindowManager"
    ]

    func captureCurrentWindows() throws -> [WindowSnapshot] {
        guard AccessibilityManager.isTrusted() else {
            AppLog.accessibility.warning("Window capture blocked because Accessibility permission is missing")
            throw WindowSnapshotterError.accessibilityPermissionMissing
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawWindowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            AppLog.windows.error("Unable to copy CG window list")
            throw WindowSnapshotterError.unableToCopyWindowList
        }

        let displays = DisplayManager.currentDisplays()
        var axMetadataByProcess: [pid_t: [AXWindowMetadata]] = [:]
        var usedAXMetadataIndicesByProcess: [pid_t: Set<Int>] = [:]
        var snapshots: [WindowSnapshot] = []
        for windowInfo in rawWindowList {
            if let snapshot = try snapshot(
                from: windowInfo,
                displays: displays,
                axMetadataByProcess: &axMetadataByProcess,
                usedAXMetadataIndicesByProcess: &usedAXMetadataIndicesByProcess
            ) {
                snapshots.append(snapshot)
            }
        }

        AppLog.windows.info("Captured \(snapshots.count) visible windows")
        return snapshots
    }

    private func snapshot(
        from windowInfo: [String: Any],
        displays: [DisplayInfo],
        axMetadataByProcess: inout [pid_t: [AXWindowMetadata]],
        usedAXMetadataIndicesByProcess: inout [pid_t: Set<Int>]
    ) throws -> WindowSnapshot? {
        guard let layer = intValue(windowInfo[kCGWindowLayer as String]), layer == 0 else {
            return nil
        }

        let ownerName = windowInfo[kCGWindowOwnerName as String] as? String
        if let ownerName, Self.excludedOwnerNames.contains(ownerName) {
            return nil
        }

        guard
            let processIdentifier = intValue(windowInfo[kCGWindowOwnerPID as String]),
            let frame = cgRect(from: windowInfo[kCGWindowBounds as String]),
            frame.width > 0,
            frame.height > 0
        else {
            return nil
        }

        guard let bundleIdentifier = NSRunningApplication(
            processIdentifier: pid_t(processIdentifier)
        )?.bundleIdentifier else {
            AppLog.windows.warning("Skipping window because bundle identifier is unavailable for pid \(processIdentifier)")
            return nil
        }

        if bundleIdentifier == Bundle.main.bundleIdentifier {
            AppLog.windows.debug("Skipping Perch window while capturing layout")
            return nil
        }

        let cgWindowID = uint32Value(windowInfo[kCGWindowNumber as String])
        let cgTitle = windowInfo[kCGWindowName as String] as? String ?? ""
        let pid = pid_t(processIdentifier)
        let processMetadata: [AXWindowMetadata]
        if let cached = axMetadataByProcess[pid] {
            processMetadata = cached
        } else {
            let fetched = try axWindowList(for: pid)
            axMetadataByProcess[pid] = fetched
            processMetadata = fetched
        }
        let usedIndices = usedAXMetadataIndicesByProcess[pid, default: []]
        guard let axMetadataIndex = Self.matchAXWindowIndex(
            in: processMetadata,
            cgTitle: cgTitle,
            cgFrame: frame,
            excluding: usedIndices
        ) else {
            AppLog.windows.debug(
                "Skipping CG window for pid \(pid) because no unused AX window matched it"
            )
            return nil
        }
        usedAXMetadataIndicesByProcess[pid, default: []].insert(axMetadataIndex)
        let axMetadata = processMetadata[axMetadataIndex]
        let windowTitle = axMetadata.title.isEmpty ? cgTitle : axMetadata.title
        let windowRole = axMetadata.role
        let accessibilityIdentifier = normalizedAccessibilityIdentifier(axMetadata.accessibilityIdentifier)

        guard windowRole == "AXWindow" else {
            AppLog.windows.debug("Skipping non-window AX role \(windowRole, privacy: .public)")
            return nil
        }

        if axMetadata.isMinimized {
            AppLog.windows.debug("Skipping minimized window for bundle \(bundleIdentifier, privacy: .public)")
            return nil
        }

        if axMetadata.isFullscreen {
            AppLog.windows.debug("Skipping fullscreen window for bundle \(bundleIdentifier, privacy: .public)")
            return nil
        }

        let display = DisplayManager.display(containing: frame, in: displays)
        let displayLocalFrame = display.map { display in
            DisplayManager.localFrame(for: frame, in: display)
        }

        return WindowSnapshot(
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            frame: CodableRect(frame),
            displayUUID: display?.uuid,
            displayLocalFrame: displayLocalFrame.map { CodableRect($0) },
            windowRole: windowRole,
            processIdentifier: Int32(processIdentifier),
            capturedAt: Date(),
            cgWindowID: cgWindowID,
            accessibilityIdentifier: accessibilityIdentifier
        )
    }

    private func axWindowList(for processIdentifier: pid_t) throws -> [AXWindowMetadata] {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        let rawWindows: [AXUIElement]
        switch copyAttribute("AXWindows", from: appElement) {
        case let .value(value):
            guard let windows = value as? [AXUIElement] else {
                return []
            }
            rawWindows = windows
        case .cannotComplete:
            throw WindowSnapshotterError.incompleteAccessibilityRead(
                processIdentifier: Int32(processIdentifier)
            )
        case .failed:
            // Some CG-only surfaces legitimately expose no AXWindows
            // attribute. They are not a transient partial read and must not
            // prevent the rest of the layout from being saved.
            return []
        }

        let attributes = [
            "AXRole",
            "AXTitle",
            "AXMinimized",
            "AXFullScreen",
            "AXIdentifier",
            "AXPosition",
            "AXSize"
        ]
        var metadata: [AXWindowMetadata] = []

        for window in rawWindows {
            let values: [Any]
            switch copyAttributes(attributes, from: window) {
            case let .values(readValues):
                values = readValues
            case .cannotComplete:
                AppLog.windows.warning(
                    "Aborting AX capture for unresponsive pid \(processIdentifier)"
                )
                throw WindowSnapshotterError.incompleteAccessibilityRead(
                    processIdentifier: Int32(processIdentifier)
                )
            case .failed:
                continue
            }

            guard let role = value(at: 0, in: values, as: String.self) else {
                continue
            }

            metadata.append(AXWindowMetadata(
                title: value(at: 1, in: values, as: String.self) ?? "",
                role: role,
                isMinimized: value(at: 2, in: values, as: Bool.self) ?? false,
                isFullscreen: value(at: 3, in: values, as: Bool.self) ?? false,
                accessibilityIdentifier: value(at: 4, in: values, as: String.self),
                frame: frame(
                    positionValue: values.indices.contains(5) ? values[5] : nil,
                    sizeValue: values.indices.contains(6) ? values[6] : nil
                )
            ))
        }

        return metadata
    }

    static func matchAXWindow(
        in metadata: [AXWindowMetadata],
        cgTitle: String,
        cgFrame: CGRect
    ) -> AXWindowMetadata? {
        guard let index = matchAXWindowIndex(
            in: metadata,
            cgTitle: cgTitle,
            cgFrame: cgFrame,
            excluding: []
        ) else {
            return nil
        }

        return metadata[index]
    }

    static func matchAXWindowIndex(
        in metadata: [AXWindowMetadata],
        cgTitle: String,
        cgFrame: CGRect,
        excluding excludedIndices: Set<Int>
    ) -> Int? {
        let availableIndices = metadata.indices.filter {
            !excludedIndices.contains($0) &&
                metadata[$0].role == "AXWindow" &&
                !metadata[$0].isMinimized &&
                !metadata[$0].isFullscreen
        }

        if let exactMatch = uniqueMatchIndex(
            in: metadata,
            availableIndices: availableIndices,
            matching: { $0.role == "AXWindow" && !$0.title.isEmpty && $0.title == cgTitle }
        ) {
            return exactMatch
        }

        if let frameMatch = uniqueMatchIndex(
            in: metadata,
            availableIndices: availableIndices,
            matching: { $0.role == "AXWindow" && $0.frame?.isApproximatelyEqual(to: cgFrame, tolerance: 2) == true }
        ) {
            return frameMatch
        }

        if let caseInsensitiveMatch = uniqueMatchIndex(
            in: metadata,
            availableIndices: availableIndices,
            matching: {
                $0.role == "AXWindow" &&
                    !$0.title.isEmpty &&
                    $0.title.localizedCaseInsensitiveCompare(cgTitle) == .orderedSame
            }
        ) {
            return caseInsensitiveMatch
        }

        guard cgTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return uniqueMatchIndex(
            in: metadata,
            availableIndices: availableIndices,
            matching: { $0.role == "AXWindow" }
        )
    }

    private static func uniqueMatchIndex(
        in metadata: [AXWindowMetadata],
        availableIndices: [Int],
        matching predicate: (AXWindowMetadata) -> Bool
    ) -> Int? {
        let matches = availableIndices.filter { predicate(metadata[$0]) }
        return matches.count == 1 ? matches[0] : nil
    }

    static func isIncompleteAccessibilityError(_ error: AXError) -> Bool {
        error == .cannotComplete
    }

    private func copyAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXSingleAttributeReadResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        if Self.isIncompleteAccessibilityError(error) {
            return .cannotComplete
        }

        guard error == .success, let value else {
            return .failed
        }

        return .value(value)
    }

    private func cgRect(from value: Any?) -> CGRect? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }

        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let integer as Int:
            integer
        default:
            nil
        }
    }

    private func uint32Value(_ value: Any?) -> UInt32? {
        switch value {
        case let number as NSNumber:
            number.uint32Value
        case let integer as UInt32:
            integer
        case let integer as Int where integer >= 0:
            UInt32(integer)
        default:
            nil
        }
    }

    private func normalizedAccessibilityIdentifier(_ identifier: String?) -> String? {
        guard let normalized = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return nil
        }

        return normalized
    }

    private func copyAttributes(
        _ attributes: [String],
        from element: AXUIElement
    ) -> AXAttributeReadResult {
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        )

        if Self.isIncompleteAccessibilityError(error) {
            return .cannotComplete
        }

        guard error == .success, let values = rawValues as? [Any] else {
            return .failed
        }

        if values.contains(where: {
            embeddedAXError(in: $0).map(Self.isIncompleteAccessibilityError) == true
        }) {
            return .cannotComplete
        }

        return .values(values)
    }

    private func embeddedAXError(in value: Any) -> AXError? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else {
            return nil
        }

        var error = AXError.success
        return AXValueGetValue(axValue, .axError, &error) ? error : nil
    }

    private func value<T>(at index: Int, in values: [Any], as type: T.Type) -> T? {
        guard values.indices.contains(index) else {
            return nil
        }

        return values[index] as? T
    }

    private func frame(positionValue: Any?, sizeValue: Any?) -> CGRect? {
        guard
            let position = point(from: positionValue),
            let windowSize = size(from: sizeValue)
        else {
            return nil
        }

        return CGRect(origin: position, size: windowSize)
    }

    private func point(from value: Any?) -> CGPoint? {
        guard let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func size(from value: Any?) -> CGSize? {
        guard let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

}
