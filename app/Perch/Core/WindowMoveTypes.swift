import Foundation

enum WindowMoverError: LocalizedError, Equatable, Sendable {
    case accessibilityPermissionMissing
    case appNotRunning(bundleIdentifier: String)
    case windowNotFound(bundleIdentifier: String, title: String)
    case ambiguousWindowMatch(bundleIdentifier: String, title: String)
    case invalidFrame(CGRect)
    case frameReadFailed
    case frameWriteFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "Accessibility permission is required to move windows."
        case let .appNotRunning(bundleIdentifier):
            "No running application was found for \(bundleIdentifier)."
        case let .windowNotFound(bundleIdentifier, title):
            "No movable window was found for \(bundleIdentifier) with title \(title)."
        case let .ambiguousWindowMatch(bundleIdentifier, title):
            "Multiple windows were available for \(bundleIdentifier), but Perch could not safely choose one for \(title)."
        case let .invalidFrame(frame):
            "Invalid target frame: \(frame)."
        case .frameReadFailed:
            "Unable to read the current window frame."
        case .frameWriteFailed:
            "Unable to set and verify the window frame."
        }
    }
}

enum WindowMoveMatchReason: Equatable, Sendable {
    case cgWindowID
    case accessibilityIdentifier
    case titleMatch
    case singleCandidateFallback

    @MainActor
    var userDescription: String {
        switch self {
        case .cgWindowID:
            L10n.text(.matchReasonSameLiveWindow)
        case .accessibilityIdentifier:
            L10n.text(.matchReasonSavedWindowIdentity)
        case .titleMatch:
            L10n.text(.matchReasonWindowTitle)
        case .singleCandidateFallback:
            L10n.text(.matchReasonOnlyOpenWindow)
        }
    }
}

struct WindowMoveRequest: Sendable {
    var bundleIdentifier: String
    var windowTitle: String
    var processIdentifier: Int32?
    var cgWindowID: UInt32?
    var accessibilityIdentifier: String?
    var capturedAt: Date?
    var frame: CGRect
    var attempts: Int

    init(
        bundleIdentifier: String,
        windowTitle: String,
        processIdentifier: Int32? = nil,
        cgWindowID: UInt32? = nil,
        accessibilityIdentifier: String? = nil,
        capturedAt: Date? = nil,
        frame: CGRect,
        attempts: Int = 3
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.processIdentifier = processIdentifier
        self.cgWindowID = cgWindowID
        self.accessibilityIdentifier = accessibilityIdentifier
        self.capturedAt = capturedAt
        self.frame = frame
        self.attempts = attempts
    }
}

struct WindowBatchMoveRequest: Sendable {
    var snapshot: WindowSnapshot
    var frame: CGRect
    var attempts: Int
    /// Identity of the exact live window selected by an earlier batch. It is
    /// independent of mutable title/AX metadata and prevents another saved
    /// snapshot from claiming the same physical window on a later retry.
    var reservation: WindowCandidateReservation?
    /// Keeps an already-restored window in later launch-retry batches so the
    /// one-to-one matcher reserves it without moving it again.
    var shouldMove: Bool

    init(
        snapshot: WindowSnapshot,
        frame: CGRect,
        attempts: Int,
        reservation: WindowCandidateReservation? = nil,
        shouldMove: Bool = true
    ) {
        self.snapshot = snapshot
        self.frame = frame
        self.attempts = attempts
        self.reservation = reservation
        self.shouldMove = shouldMove
    }
}

struct WindowCandidateReservation: Equatable, Hashable, Sendable {
    var processIdentifier: Int32
    var processLaunchDate: Date?
    var cgWindowID: UInt32?
    var axElementHash: UInt
}

struct WindowBatchMoveResult: Equatable, Sendable {
    var snapshotID: String
    var restoredFrame: CGRect?
    var matchReason: WindowMoveMatchReason?
    var error: WindowMoverError?
    var reservation: WindowCandidateReservation? = nil

    var isSuccess: Bool {
        error == nil
    }
}

struct WindowMoveCandidate: Equatable, Sendable {
    var bundleIdentifier: String
    var processIdentifier: Int32
    var processLaunchDate: Date?
    var cgWindowID: UInt32?
    var accessibilityIdentifier: String?
    var title: String
    var normalizedTitle: String
    var role: String
    var isMinimized: Bool
    var isFullscreen: Bool
    var frame: CGRect?
    var axElementHash: UInt = 0
}
