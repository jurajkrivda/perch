import AppKit
import Foundation

/// Block-observer tokens are Objective-C objects and therefore non-Sendable.
/// Keeping their teardown in a non-actor helper lets Swift 6 safely run cleanup
/// when the main-actor observer is deallocated.
private final class EnvironmentObserverTokenStore {
    var workspace: [NSObjectProtocol] = []
    var application: [NSObjectProtocol] = []
    var distributed: [NSObjectProtocol] = []

    func removeAll() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspace.forEach(workspaceCenter.removeObserver)
        workspace.removeAll()

        application.forEach(NotificationCenter.default.removeObserver)
        application.removeAll()

        let distributedCenter = DistributedNotificationCenter.default()
        distributed.forEach(distributedCenter.removeObserver)
        distributed.removeAll()
    }

    deinit {
        removeAll()
    }
}

private enum SystemSessionVisibility {
    /// Core Graphics exposes no typed constant for this session-dictionary key.
    /// It is present with a true value while the secure screen is locked and
    /// absent on an unlocked session, so absence deliberately means false.
    private static let screenLockedKey = "CGSSessionScreenIsLocked"

    static func current() -> Bool? {
        guard let sessionDictionary = CGSessionCopyCurrentDictionary() else {
            return nil
        }

        let session = sessionDictionary as NSDictionary
        let isOnConsole = session[kCGSessionOnConsoleKey] as? Bool ?? true
        let loginIsComplete = session[kCGSessionLoginDoneKey] as? Bool ?? true
        let screenIsLocked = session[screenLockedKey] as? Bool ?? false
        return isOnConsole && loginIsComplete && !screenIsLocked
    }
}

/// Coalesces wake, unlock, and display-change signals into one callback after
/// the display environment and macOS window relocation have settled.
@MainActor
final class EnvironmentChangeObserver {
    typealias SettleTimeoutProvider = @MainActor () -> TimeInterval
    typealias TriggeredHandler = @MainActor (EnvironmentChangeReason) -> Void
    typealias SessionVisibilityHandler = @MainActor (Bool) -> Void
    typealias SettledHandler = @MainActor (EnvironmentChangeReason) -> Void

    private static let quietPeriod: TimeInterval = 2
    private static let relocationGracePeriod: TimeInterval = 1.5
    private static let defaultSettleTimeout: TimeInterval = 10
    private static let visibilityConfirmationAttempts = 10
    private static let visibilityConfirmationDelayNanoseconds: UInt64 = 200_000_000

    private let settleTimeoutProvider: SettleTimeoutProvider
    private let onTriggered: TriggeredHandler
    private let onSessionVisibilityChanged: SessionVisibilityHandler
    private let onSettled: SettledHandler

    private let observerTokens = EnvironmentObserverTokenStore()
    private var settleTask: Task<Void, Never>?
    private var visibilityConfirmationTask: Task<Void, Never>?
    private var reasonAccumulator = EnvironmentChangeReasonAccumulator()
    private var isSessionVisible = true
    private var isStarted = false

    init(
        settleTimeout: @escaping SettleTimeoutProvider = { defaultSettleTimeout },
        onTriggered: @escaping TriggeredHandler = { _ in },
        onSessionVisibilityChanged: @escaping SessionVisibilityHandler = { _ in },
        onSettled: @escaping SettledHandler
    ) {
        settleTimeoutProvider = settleTimeout
        self.onTriggered = onTriggered
        self.onSessionVisibilityChanged = onSessionVisibilityChanged
        self.onSettled = onSettled
    }

    deinit {
        settleTask?.cancel()
        visibilityConfirmationTask?.cancel()
    }

    func start() {
        guard !isStarted else {
            return
        }

        isStarted = true

        Task {
            await DisplayStabilizer.shared.start()
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerTokens.workspace = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.environmentDidChange(reason: .systemWake)
                }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.environmentDidChange(reason: .screensWake)
                }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.confirmVisibleSession(reason: .sessionActive)
                }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sessionVisibilityDidChange(isVisible: false)
                }
            }
        ]

        let applicationCenter = NotificationCenter.default
        observerTokens.application = [
            applicationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.environmentDidChange(reason: .displayReconfiguration)
                }
            },
            applicationCenter.addObserver(
                forName: .perchDisplayDidReconfigure,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.environmentDidChange(reason: .displayReconfiguration)
                }
            }
        ]

        // Distributed screen lock/unlock notifications require an unsandboxed app.
        // Perch currently has empty entitlements; adding App Sandbox later will
        // silently stop this notification from being delivered.
        let distributedCenter = DistributedNotificationCenter.default()
        observerTokens.distributed = [
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.confirmVisibleSession(reason: .screenUnlock)
                }
            },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sessionVisibilityDidChange(isVisible: false)
                }
            }
        ]

        refreshSessionVisibilityFromSystem()

        AppLog.display.info("Started environment change observer")
    }

    func stop() {
        guard isStarted else {
            return
        }

        isStarted = false
        settleTask?.cancel()
        settleTask = nil
        visibilityConfirmationTask?.cancel()
        visibilityConfirmationTask = nil
        reasonAccumulator.reset()

        observerTokens.removeAll()

        AppLog.display.info("Stopped environment change observer")
    }

    private func environmentDidChange(reason: EnvironmentChangeReason) {
        guard isStarted else {
            return
        }

        // Lock notifications can be delivered before this observer starts or
        // race a wake callback. Re-read the current session before processing
        // wake/display work so an offer cannot expire behind the secure UI.
        if reason.isWake || reason == .displayReconfiguration {
            refreshSessionVisibilityFromSystem()
        }

        AppLog.display.info("Environment change triggered: \(reason.rawValue, privacy: .public)")

        // Display callbacks can keep arriving behind the secure login UI.
        // Defer them until unlock/session-active starts a fresh burst with a
        // fresh interaction timestamp.
        guard isSessionVisible else {
            _ = reasonAccumulator.receive(
                reason,
                isSessionVisible: false,
                beginsNewBurst: false
            )
            settleTask?.cancel()
            settleTask = nil
            return
        }

        let beginsNewBurst = settleTask == nil
        if let triggerReason = reasonAccumulator.receive(
            reason,
            isSessionVisible: true,
            beginsNewBurst: beginsNewBurst
        ) {
            onTriggered(triggerReason)
        }

        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            guard let settleTimeout = self?.settleTimeoutProvider() else {
                return
            }

            // A wake or unlock is itself the start of a new settling window,
            // even if Core Graphics has not reported display changes yet.
            await DisplayStabilizer.shared.markChanged()
            await DisplayStabilizer.shared.waitForStable(
                quietPeriod: Self.quietPeriod,
                timeout: settleTimeout
            )

            guard !Task.isCancelled else {
                return
            }

            do {
                try await Task.sleep(for: .seconds(Self.relocationGracePeriod))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.isStarted,
                  self.isSessionVisible
            else {
                return
            }

            let settledReason = self.reasonAccumulator.finish(fallback: reason)
            self.settleTask = nil
            self.onSettled(settledReason)
        }
    }

    private func sessionVisibilityDidChange(
        isVisible: Bool,
        cancelVisibilityConfirmation: Bool = true
    ) {
        if !isVisible, cancelVisibilityConfirmation {
            visibilityConfirmationTask?.cancel()
            visibilityConfirmationTask = nil
        }
        guard self.isSessionVisible != isVisible else { return }
        isSessionVisible = isVisible
        if !isVisible {
            reasonAccumulator.sessionBecameHidden()
            settleTask?.cancel()
            settleTask = nil
        }
        AppLog.display.info("Session visibility changed: visible=\(isVisible)")
        onSessionVisibilityChanged(isVisible)
    }

    private func refreshSessionVisibilityFromSystem() {
        guard let isVisible = SystemSessionVisibility.current() else { return }
        sessionVisibilityDidChange(isVisible: isVisible)
    }

    private func confirmVisibleSession(reason: EnvironmentChangeReason) {
        visibilityConfirmationTask?.cancel()
        visibilityConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 0..<Self.visibilityConfirmationAttempts {
                guard self.isStarted, !Task.isCancelled else { return }

                if SystemSessionVisibility.current() == true {
                    self.visibilityConfirmationTask = nil
                    self.sessionVisibilityDidChange(isVisible: true)
                    self.environmentDidChange(reason: reason)
                    return
                }

                // A locked or temporarily unavailable session dictionary is
                // not positive confirmation. Synchronize to hidden so an
                // existing settle or prompt cannot expire behind the secure UI,
                // but keep this bounded confirmation task alive for a real
                // unlock whose dictionary update is still catching up.
                self.sessionVisibilityDidChange(
                    isVisible: false,
                    cancelVisibilityConfirmation: false
                )

                guard attempt + 1 < Self.visibilityConfirmationAttempts else {
                    break
                }
                do {
                    try await Task.sleep(
                        nanoseconds: Self.visibilityConfirmationDelayNanoseconds
                    )
                } catch {
                    return
                }
            }

            self.visibilityConfirmationTask = nil
            AppLog.display.debug(
                "Ignored visible-session notification while the secure screen remained locked"
            )
        }
    }
}
