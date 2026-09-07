@preconcurrency import ApplicationServices
@preconcurrency import AppKit
import CoreGraphics
import Foundation

/// Serializes blocking Accessibility calls away from the main actor. AX objects
/// remain private to this actor; only Sendable values cross its boundary.
actor WindowMover {
    static let frameTolerance: CGFloat = 2

    struct AXWindow {
        var element: AXUIElement
        var candidate: WindowMoveCandidate
    }

    @discardableResult
    func setFrame(_ request: WindowMoveRequest, strictness: MatchStrictness = .fuzzy) async throws -> CGRect {
        guard request.frame.isValidWindowFrame else {
            throw WindowMoverError.invalidFrame(request.frame)
        }

        guard let window = try bestLiveWindow(
            bundleIdentifier: request.bundleIdentifier,
            request: WindowMatcher.WindowMatchRequest(
                title: request.windowTitle,
                processIdentifier: request.processIdentifier,
                capturedAt: request.capturedAt,
                cgWindowID: request.cgWindowID,
                accessibilityIdentifier: request.accessibilityIdentifier,
                frame: request.frame
            ),
            strictness: strictness
        ) else {
            throw WindowMoverError.windowNotFound(
                bundleIdentifier: request.bundleIdentifier,
                title: request.windowTitle
            )
        }

        return try await moveWindow(
            window,
            to: request.frame,
            attempts: request.attempts,
            bundleIdentifier: request.bundleIdentifier
        )
    }

    @discardableResult
    func move(
        snapshot: WindowSnapshot,
        to frame: CGRect,
        attempts: Int = 3,
        strictness: MatchStrictness
    ) async throws -> CGRect {
        try await setFrame(
            WindowMoveRequest(
                bundleIdentifier: snapshot.bundleIdentifier,
                windowTitle: snapshot.windowTitle,
                processIdentifier: snapshot.processIdentifier,
                cgWindowID: snapshot.cgWindowID,
                accessibilityIdentifier: snapshot.accessibilityIdentifier,
                capturedAt: snapshot.capturedAt,
                frame: frame,
                attempts: attempts
            ),
            strictness: strictness
        )
    }

    func move(
        requests: [WindowBatchMoveRequest],
        bundleIdentifier: String,
        strictness: MatchStrictness
    ) async throws -> [WindowBatchMoveResult] {
        try Task.checkCancellation()
        guard !requests.isEmpty else {
            return []
        }

        let windows = try liveWindows(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil,
            includeSkippedWindows: true
        )
        let candidates = windows.map(\.candidate)
        let validIndexedRequests = requests.enumerated().filter { $0.element.frame.isValidWindowFrame }
        let matchRequests = validIndexedRequests.map { _, request in
            WindowMatcher.WindowMatchRequest(
                title: request.snapshot.windowTitle,
                processIdentifier: request.snapshot.processIdentifier,
                capturedAt: request.snapshot.capturedAt,
                cgWindowID: request.snapshot.cgWindowID,
                accessibilityIdentifier: request.snapshot.accessibilityIdentifier,
                frame: request.frame,
                reservation: request.reservation,
                rejectsConflictingAccessibilityIdentifier: false
            )
        }
        let selectionsForValidRequests = WindowMatcher.bestWindowSelections(
            in: candidates,
            matching: matchRequests,
            strictness: strictness
        )
        let selections = Dictionary(
            uniqueKeysWithValues: selectionsForValidRequests.compactMap { validRequestIndex, selection in
                validIndexedRequests.indices.contains(validRequestIndex)
                    ? (validIndexedRequests[validRequestIndex].offset, selection)
                    : nil
            }
        )

        var results: [WindowBatchMoveResult] = []
        results.reserveCapacity(requests.count)

        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            guard request.frame.isValidWindowFrame else {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: .invalidFrame(request.frame)
                ))
                continue
            }

            guard let selection = selections[index] else {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: nil,
                    error: Self.unresolvedSelectionError(
                        bundleIdentifier: request.snapshot.bundleIdentifier,
                        title: request.snapshot.windowTitle,
                        candidateCount: candidates.count,
                        usedCandidateIndices: Set(selections.values.map(\.index))
                    )
                ))
                continue
            }

            do {
                let selectedWindow = windows[selection.index]
                let restoredFrame: CGRect
                if request.shouldMove {
                    restoredFrame = try await moveWindow(
                        selectedWindow,
                        to: request.frame,
                        attempts: request.attempts,
                        bundleIdentifier: request.snapshot.bundleIdentifier
                    )
                } else {
                    restoredFrame = selectedWindow.candidate.frame ?? request.frame
                }

                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: restoredFrame,
                    matchReason: selection.reason,
                    error: nil,
                    reservation: WindowMatcher.reservation(for: selectedWindow.candidate)
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WindowMoverError {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: selection.reason,
                    error: error
                ))
            } catch {
                results.append(WindowBatchMoveResult(
                    snapshotID: request.snapshot.id,
                    restoredFrame: nil,
                    matchReason: selection.reason,
                    error: .frameWriteFailed
                ))
            }
        }

        return results
    }

    static func unresolvedSelectionError(
        bundleIdentifier: String,
        title: String,
        candidateCount: Int,
        usedCandidateIndices: Set<Int>
    ) -> WindowMoverError {
        let hasUnusedCandidate = (0..<candidateCount).contains { !usedCandidateIndices.contains($0) }

        if candidateCount == 0 || !hasUnusedCandidate {
            return .windowNotFound(
                bundleIdentifier: bundleIdentifier,
                title: title
            )
        }

        return .ambiguousWindowMatch(
            bundleIdentifier: bundleIdentifier,
            title: title
        )
    }

    private func bestLiveWindow(
        bundleIdentifier: String,
        request: WindowMatcher.WindowMatchRequest,
        strictness: MatchStrictness
    ) throws -> AXWindow? {
        let processScopedWindows: [AXWindow]
        do {
            processScopedWindows = try liveWindows(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: request.processIdentifier,
                includeSkippedWindows: true
            )
        } catch WindowMoverError.appNotRunning where request.processIdentifier != nil {
            processScopedWindows = []
        }

        if let selectedWindow = bestWindow(
            in: processScopedWindows,
            request: request,
            strictness: strictness,
            scope: request.processIdentifier == nil ? "bundle" : "process"
        ) {
            return selectedWindow
        }

        guard request.processIdentifier != nil else {
            return nil
        }

        let fallbackWindows = try liveWindows(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil,
            includeSkippedWindows: true
        )
        let bundleFallbackRequest = WindowMatcher.WindowMatchRequest(
            title: request.title,
            accessibilityIdentifier: request.accessibilityIdentifier,
            frame: request.frame,
            rejectsConflictingAccessibilityIdentifier: false
        )

        return bestWindow(
            in: fallbackWindows,
            request: bundleFallbackRequest,
            strictness: strictness,
            scope: "bundle fallback"
        )
    }

    private func bestWindow(
        in windows: [AXWindow],
        request: WindowMatcher.WindowMatchRequest,
        strictness: MatchStrictness,
        scope: String
    ) -> AXWindow? {
        guard let selection = WindowMatcher.bestWindowSelection(
            in: windows.map(\.candidate),
            matching: request,
            strictness: strictness
        ) else {
            return nil
        }

        let window = windows[selection.index]
        switch selection.reason {
        case .cgWindowID:
            AppLog.windows.debug(
                "Selected window for \(window.candidate.bundleIdentifier, privacy: .public) by CGWindowID in \(scope, privacy: .public) scope"
            )
        case .accessibilityIdentifier:
            AppLog.windows.debug(
                "Selected window for \(window.candidate.bundleIdentifier, privacy: .public) by AXIdentifier in \(scope, privacy: .public) scope"
            )
        case .titleMatch:
            break
        case .singleCandidateFallback:
            AppLog.windows.info(
                "Using only live window for \(window.candidate.bundleIdentifier, privacy: .public) after saved title did not match in \(scope, privacy: .public) scope"
            )
        }

        return window
    }

    private func liveWindows(
        bundleIdentifier: String,
        processIdentifier: Int32?,
        includeSkippedWindows: Bool
    ) throws -> [AXWindow] {
        guard AccessibilityManager.isTrusted() else {
            AppLog.accessibility.warning("Window move blocked because Accessibility permission is missing")
            throw WindowMoverError.accessibilityPermissionMissing
        }

        let applications = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { application in
                guard let processIdentifier else {
                    return true
                }

                return application.processIdentifier == processIdentifier
            }

        guard !applications.isEmpty else {
            throw WindowMoverError.appNotRunning(bundleIdentifier: bundleIdentifier)
        }

        let windows = applications.flatMap { application in
            appWindows(
                for: application,
                bundleIdentifier: bundleIdentifier,
                includeSkippedWindows: includeSkippedWindows
            )
        }

        return windows
    }

    private func appWindows(
        for application: NSRunningApplication,
        bundleIdentifier: String,
        includeSkippedWindows: Bool
    ) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let rawWindows = copyAttribute(kAXWindowsAttribute, from: appElement) as? [AXUIElement] else {
            return []
        }

        let cgWindows = CGWindowCatalog.visibleWindows(for: application.processIdentifier)
        var usedCGWindowIDs = Set<UInt32>()

        let attributes = [
            kAXRoleAttribute,
            kAXTitleAttribute,
            kAXIdentifierAttribute,
            kAXMinimizedAttribute,
            "AXFullScreen",
            kAXPositionAttribute,
            kAXSizeAttribute
        ]
        var windows: [AXWindow] = []

        for window in rawWindows {
            let values: [Any]
            switch AccessibilityValues.copyAttributes(attributes, from: window) {
            case let .values(readValues):
                values = readValues
            case .cannotComplete:
                AppLog.windows.warning(
                    "Aborting AX enumeration for unresponsive pid \(application.processIdentifier)"
                )
                return windows
            case .failed:
                continue
            }

            let role = AccessibilityValues.value(at: 0, in: values, as: String.self) ?? ""
            let title = AccessibilityValues.value(at: 1, in: values, as: String.self) ?? ""
            let accessibilityIdentifier = AccessibilityValues.value(at: 2, in: values, as: String.self)
            let isMinimized = AccessibilityValues.value(at: 3, in: values, as: Bool.self) ?? false
            let isFullscreen = AccessibilityValues.value(at: 4, in: values, as: Bool.self) ?? false

            guard role == kAXWindowRole as String else {
                continue
            }

            guard includeSkippedWindows || (!isMinimized && !isFullscreen) else {
                continue
            }

            let frame = AccessibilityValues.frame(
                positionValue: values.indices.contains(5) ? values[5] : nil,
                sizeValue: values.indices.contains(6) ? values[6] : nil
            )
            let cgWindowID = CGWindowCatalog.matchingWindowID(
                title: title,
                frame: frame,
                in: cgWindows,
                usedWindowIDs: usedCGWindowIDs
            )
            if let cgWindowID {
                usedCGWindowIDs.insert(cgWindowID)
            }

            let candidate = WindowMoveCandidate(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: application.processIdentifier,
                processLaunchDate: application.launchDate,
                cgWindowID: cgWindowID,
                accessibilityIdentifier: accessibilityIdentifier,
                title: title,
                normalizedTitle: WindowTitleSimilarity.normalize(title),
                role: role,
                isMinimized: isMinimized,
                isFullscreen: isFullscreen,
                frame: frame,
                axElementHash: CFHash(window)
            )

            windows.append(AXWindow(element: window, candidate: candidate))
        }

        return windows
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard error == .success else {
            return nil
        }

        return value
    }

}
