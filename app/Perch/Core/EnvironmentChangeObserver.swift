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

    private let settleTimeoutProvider: SettleTimeoutProvider
    private let onTriggered: TriggeredHandler
    private let onSessionVisibilityChanged: SessionVisibilityHandler
    private let onSettled: SettledHandler

    private let observerTokens = EnvironmentObserverTokenStore()
    private var settleTask: Task<Void, Never>?
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
                    self?.sessionVisibilityDidChange(isVisible: true)
                    self?.environmentDidChange(reason: .sessionActive)
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
                    self?.sessionVisibilityDidChange(isVisible: true)
                    self?.environmentDidChange(reason: .screenUnlock)
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

        AppLog.display.info("Started environment change observer")
    }

    func stop() {
        guard isStarted else {
            return
        }

        isStarted = false
        settleTask?.cancel()
        settleTask = nil
        reasonAccumulator.reset()

        observerTokens.removeAll()

        AppLog.display.info("Stopped environment change observer")
    }

    private func environmentDidChange(reason: EnvironmentChangeReason) {
        guard isStarted else {
            return
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
                  self.isStarted
            else {
                return
            }

            let settledReason = self.reasonAccumulator.finish(fallback: reason)
            self.settleTask = nil
            self.onSettled(settledReason)
        }
    }

    private func sessionVisibilityDidChange(isVisible: Bool) {
        isSessionVisible = isVisible
        if !isVisible {
            reasonAccumulator.sessionBecameHidden()
            settleTask?.cancel()
            settleTask = nil
        }
        AppLog.display.info("Session visibility changed: visible=\(isVisible)")
        onSessionVisibilityChanged(isVisible)
    }
}
