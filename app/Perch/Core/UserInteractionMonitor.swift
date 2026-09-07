import CoreGraphics
import Foundation

enum UserInteractionMonitor {
    private static let recentInteractionThreshold: TimeInterval = 3
    static func interacted(since startedAt: Date) -> Bool {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]

        // Keep the explicit three-second safety threshold from the brief, but
        // also cover the entire settle interval so input immediately after a
        // trigger cannot age out before a slow dock becomes stable.
        let elapsedSinceTrigger = max(Date().timeIntervalSince(startedAt), 0)
        let interactionWindow = max(
            Self.recentInteractionThreshold,
            elapsedSinceTrigger
        )

        return eventTypes.contains { eventType in
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: eventType
            ) <= interactionWindow
        }
    }
}
