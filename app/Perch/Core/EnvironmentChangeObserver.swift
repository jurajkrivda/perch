import AppKit
import Foundation

/// Block-observer tokens are Objective-C objects and therefore non-Sendable.
/// Keeping their teardown in a non-actor helper lets Swift 6 safely run cleanup
/// when the main-actor observer is deallocated.
private final class EnvironmentObserverTokenStore {
    let workspaceCenter: NotificationCenter
    let applicationCenter: NotificationCenter
    let distributedCenter: NotificationCenter
    var workspace: [NSObjectProtocol] = []
    var application: [NSObjectProtocol] = []
    var distributed: [NSObjectProtocol] = []

    init(workspace: NotificationCenter, application: NotificationCenter, distributed: NotificationCenter) {
        workspaceCenter = workspace
        applicationCenter = application
        distributedCenter = distributed
    }

    func removeAll() {
        workspace.forEach(workspaceCenter.removeObserver)
        workspace.removeAll()

        application.forEach(applicationCenter.removeObserver)
        application.removeAll()

        distributed.forEach(distributedCenter.removeObserver)
        distributed.removeAll()
    }

    deinit {
        removeAll()
    }
}

enum SystemSessionVisibility {
    /// Core Graphics exposes no typed constant for this session-dictionary key.
    /// It is present with a true value while the secure screen is locked and
    /// absent on an unlocked session, so absence deliberately means false.
    private static let screenLockedKey = "CGSSessionScreenIsLocked"

    static func current() -> Bool? {
        guard let sessionDictionary = CGSessionCopyCurrentDictionary() else {
            return nil
        }

        let session = sessionDictionary as NSDictionary
        let isOnConsole = session[kCGSessionOnConsoleKey] as? Bool ?? false
        let loginIsComplete = session[kCGSessionLoginDoneKey] as? Bool ?? false
        let screenIsLocked = session[screenLockedKey] as? Bool ?? false
        return isOnConsole && loginIsComplete && !screenIsLocked
    }
}

/// Coalesces wake, unlock, and display-change signals into one callback after
/// the display environment and macOS window relocation have settled.
@MainActor
final class EnvironmentChangeObserver {
    typealias SettleTimeoutProvider = @MainActor () async -> TimeInterval
    typealias TriggeredHandler = @MainActor (EnvironmentChangeReason) -> Void
    typealias SessionVisibilityHandler = @MainActor (Bool) -> Void
    typealias SettledHandler = @MainActor (EnvironmentChangeReason) -> Void

    private static let quietPeriod: TimeInterval = 2
    private static let relocationGracePeriod: TimeInterval = 1.5
    private static let defaultSettleTimeout: TimeInterval = 10
    private static let visibilityConfirmationAttempts = 60

    private let settleTimeoutProvider: SettleTimeoutProvider
    private let onTriggered: TriggeredHandler
    private let onSessionVisibilityChanged: SessionVisibilityHandler
    private let onSettled: SettledHandler

    private let observerTokens: EnvironmentObserverTokenStore
    private let sessionVisibility: @MainActor () -> Bool?
    private let waitForStable: @Sendable (TimeInterval) async -> Bool
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var settleTask: Task<Void, Never>?
    private var visibilityConfirmationTask: Task<Void, Never>?
    private var reasonAccumulator = EnvironmentChangeReasonAccumulator()
    private var isSessionVisible = false
    private var isAsleep = false
    private var hasEvaluatedWakeCycle = true
    private var isStarted = false

    init(
        settleTimeout: @escaping SettleTimeoutProvider = { defaultSettleTimeout },
        onTriggered: @escaping TriggeredHandler = { _ in },
        onSessionVisibilityChanged: @escaping SessionVisibilityHandler = { _ in },
        onSettled: @escaping SettledHandler,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationCenter: NotificationCenter = .default,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        sessionVisibility: @escaping @MainActor () -> Bool? = { SystemSessionVisibility.current() },
        waitForStable: @escaping @Sendable (TimeInterval) async -> Bool = { timeout in
            return await DisplayStabilizer.shared.waitAfterChange(
                quietPeriod: quietPeriod, timeout: max(quietPeriod, timeout)
            )
        },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        settleTimeoutProvider = settleTimeout
        self.onTriggered = onTriggered
        self.onSessionVisibilityChanged = onSessionVisibilityChanged
        self.onSettled = onSettled
        self.sessionVisibility = sessionVisibility
        self.waitForStable = waitForStable
        self.sleep = sleep
        observerTokens = EnvironmentObserverTokenStore(
            workspace: workspaceCenter, application: applicationCenter, distributed: distributedCenter
        )
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

        onSessionVisibilityChanged(false)
        let workspaceCenter = observerTokens.workspaceCenter
        observerTokens.workspace = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.wake(reason: .systemWake)
                }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.wake(reason: .screensWake)
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

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observerTokens.workspace.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isAsleep = true
                    self?.hasEvaluatedWakeCycle = false
                    self?.sessionVisibilityDidChange(isVisible: false)
                }
            })
        }

        let applicationCenter = observerTokens.applicationCenter
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
        let distributedCenter = observerTokens.distributedCenter
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

        // Retain startup intent if login/WindowServer is not ready yet. A login
        // item cannot rely on notifications sent before its observers existed.
        _ = reasonAccumulator.receive(.applicationLaunch, isSessionVisible: false, beginsNewBurst: false)
        confirmVisibleSession(reason: .applicationLaunch)

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
        isAsleep = false
        hasEvaluatedWakeCycle = true
        isSessionVisible = false

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
        if reason.requiresRestoreEvaluation || reason == .displayReconfiguration {
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
            guard let self else {
                return
            }
            let settleTimeout = await self.settleTimeoutProvider()
            guard !Task.isCancelled else { return }

            // A wake or unlock is itself the start of a new settling window,
            // even if Core Graphics has not reported display changes yet.
            guard await self.waitForStable(settleTimeout) else {
                guard !Task.isCancelled else { return }
                self.settleTask = nil
                AppLog.display.warning("Automatic restore deferred: displays did not stabilize")
                return
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                try await self.sleep(Self.relocationGracePeriod)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  self.isStarted,
                  self.isSessionVisible
            else {
                return
            }

            self.refreshSessionVisibilityFromSystem()
            guard self.isSessionVisible else { return }
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
        sessionVisibilityDidChange(isVisible: !isAsleep && sessionVisibility() == true)
    }

    private func wake(reason: EnvironmentChangeReason) {
        isAsleep = false
        // System wake and screen wake can be far apart on docks. They belong
        // to one sleep cycle, so a late second signal only rechecks topology.
        let effectiveReason = hasEvaluatedWakeCycle ? .displayReconfiguration : reason
        hasEvaluatedWakeCycle = true
        environmentDidChange(reason: effectiveReason)
        if !isSessionVisible { confirmVisibleSession(reason: reason) }
    }

    private func confirmVisibleSession(reason: EnvironmentChangeReason) {
        visibilityConfirmationTask?.cancel()
        visibilityConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 0..<Self.visibilityConfirmationAttempts {
                guard self.isStarted, !Task.isCancelled else { return }

                if !self.isAsleep, self.sessionVisibility() == true {
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
                    try await self.sleep(0.5)
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
