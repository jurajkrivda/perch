@preconcurrency import ApplicationServices
import Foundation

extension WindowMover {
    private func readFrame(from element: AXUIElement) -> CGRect? {
        guard case let .values(values) = AccessibilityValues.copyAttributes(
            [kAXPositionAttribute, kAXSizeAttribute],
            from: element
        ) else {
            return nil
        }

        return AccessibilityValues.frame(
            positionValue: values.indices.contains(0) ? values[0] : nil,
            sizeValue: values.indices.contains(1) ? values[1] : nil
        )
    }

    private func writePosition(_ position: CGPoint, to element: AXUIElement) -> Bool {
        var mutablePosition = position
        guard let axValue = AXValueCreate(.cgPoint, &mutablePosition) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue) == .success
    }

    private func writeSize(_ size: CGSize, to element: AXUIElement) -> Bool {
        var mutableSize = size
        guard let axValue = AXValueCreate(.cgSize, &mutableSize) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue) == .success
    }

    func moveWindow(
        _ window: AXWindow,
        to frame: CGRect,
        attempts: Int,
        bundleIdentifier: String
    ) async throws -> CGRect {
        try Task.checkCancellation()
        await prepareForMove(window)
        try Task.checkCancellation()

        let attemptCount = max(1, attempts)

        for _ in 0..<attemptCount {
            try Task.checkCancellation()
            _ = writePosition(frame.origin, to: window.element)
            _ = writeSize(frame.size, to: window.element)
            _ = writePosition(frame.origin, to: window.element)

            guard let verifiedFrame = readFrame(from: window.element) else {
                continue
            }

            if verifiedFrame.isApproximatelyEqual(to: frame, tolerance: Self.frameTolerance) {
                return verifiedFrame
            }
        }

        AppLog.windows.warning(
            "Unable to verify moved window for bundle \(bundleIdentifier, privacy: .public)"
        )

        throw WindowMoverError.frameWriteFailed
    }

    private func prepareForMove(_ window: AXWindow) async {
        var requestedStateChange = false

        if window.candidate.isFullscreen {
            let error = AXUIElementSetAttributeValue(
                window.element,
                "AXFullScreen" as CFString,
                kCFBooleanFalse
            )
            requestedStateChange = error == .success
        }

        if window.candidate.isMinimized {
            let error = AXUIElementSetAttributeValue(
                window.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
            requestedStateChange = requestedStateChange || error == .success
        }

        guard requestedStateChange else {
            return
        }

        // Full-screen transitions are asynchronous in AppKit. Poll briefly on
        // this background actor until the target exposes a normal window frame,
        // without ever blocking Perch's main actor.
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(100))

            guard case let .values(values) = AccessibilityValues.copyAttributes(
                [kAXMinimizedAttribute, "AXFullScreen"],
                from: window.element
            ) else {
                return
            }

            let isMinimized = AccessibilityValues.value(at: 0, in: values, as: Bool.self) ?? false
            let isFullscreen = AccessibilityValues.value(at: 1, in: values, as: Bool.self) ?? false
            if !isMinimized && !isFullscreen {
                return
            }
        }
    }

}
