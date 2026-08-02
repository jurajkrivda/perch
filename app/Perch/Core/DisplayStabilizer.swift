import CoreGraphics
import Foundation

extension Notification.Name {
    /// Posted after Core Graphics reports a display reconfiguration. This is
    /// separate from AppKit's screen-parameter notification because the two
    /// APIs do not always arrive at the same point in a dock reconnection.
    static let perchDisplayDidReconfigure = Notification.Name("PerchDisplayDidReconfigure")
}

actor DisplayStabilizer {
    static let shared = DisplayStabilizer()

    private var lastChangeTime = Date.distantPast
    private var isRegistered = false

    func start() {
        guard !isRegistered else {
            return
        }

        let error = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, nil)
        if error == .success {
            isRegistered = true
            AppLog.display.info("Registered display reconfiguration callback")
        } else {
            AppLog.display.error("Failed to register display reconfiguration callback: \(error.rawValue)")
        }
    }

    func markChanged() {
        lastChangeTime = Date()
        AppLog.display.debug("Display configuration changed")
    }

    func waitForStable(quietPeriod: TimeInterval = 1.0, timeout: TimeInterval = 3.0) async {
        start()

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard !Task.isCancelled else {
                AppLog.display.debug("Cancelled display stabilization wait")
                return
            }

            if Date().timeIntervalSince(lastChangeTime) >= quietPeriod {
                AppLog.display.debug("Display configuration stable")
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                AppLog.display.debug("Cancelled display stabilization wait")
                return
            }
        }

        guard !Task.isCancelled else {
            AppLog.display.debug("Cancelled display stabilization wait")
            return
        }

        AppLog.display.warning("Timed out waiting for stable display configuration")
    }

    private nonisolated static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, _ in
        Task {
            await DisplayStabilizer.shared.markChanged()
            NotificationCenter.default.post(name: .perchDisplayDidReconfigure, object: nil)
        }
    }
}
