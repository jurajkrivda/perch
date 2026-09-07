@preconcurrency import ApplicationServices
import AppKit
import Foundation

enum AccessibilityManager {
    enum ResetError: LocalizedError {
        case missingBundleIdentifier
        case failed(status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .missingBundleIdentifier:
                return "Unable to reset Accessibility permission because the bundle identifier is missing."
            case let .failed(status, output):
                if output.isEmpty {
                    return "Unable to reset Accessibility permission. tccutil exited with status \(status)."
                }

                return "Unable to reset Accessibility permission. tccutil exited with status \(status): \(output)"
            }
        }
    }

    enum PermissionState: Sendable {
        case trusted
        case notRequested
        case pending
    }

    struct Status: Sendable {
        var isTrusted: Bool
        var permissionState: PermissionState
        var hasRequestedPermissionForCurrentApp: Bool
        var bundleIdentifier: String
        var bundleLocation: String
        var registeredApplicationLocation: String?
    }

    private static var promptOptionKey: String {
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    }

    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    private static let requestedBundlePathKey = "AccessibilityPermissionRequestedBundlePath"
    private static let requestedAtKey = "AccessibilityPermissionRequestedAt"

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Caps how long a single AX request from this process may block on an
    /// unresponsive app. The system default is several seconds per call. Capture
    /// and restore use dedicated actors, but the cap still prevents one hung app
    /// from monopolizing that serial AX worker for an excessive amount of time.
    static func configureMessagingTimeout(_ timeoutInSeconds: Float = 1.0) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeoutInSeconds)
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let options = [promptOptionKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func status() -> Status {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let permissionState = permissionState()
        let hasRequestedPermission = hasRequestedPermissionForCurrentApp()
        let registeredApplicationPath = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier)?
            .standardizedFileURL
            .path

        return Status(
            isTrusted: isTrusted(),
            permissionState: permissionState,
            hasRequestedPermissionForCurrentApp: hasRequestedPermission,
            bundleIdentifier: bundleIdentifier,
            bundleLocation: redactedPathForLogging(Bundle.main.bundleURL.standardizedFileURL.path),
            registeredApplicationLocation: registeredApplicationPath.map(redactedPathForLogging)
        )
    }

    @MainActor
    static func permissionState() -> PermissionState {
        if isTrusted() {
            return .trusted
        }

        return hasRequestedPermissionForCurrentApp() ? .pending : .notRequested
    }

    @MainActor
    static func hasRequestedPermissionForCurrentApp() -> Bool {
        UserDefaults.standard.string(forKey: requestedBundlePathKey) == currentBundlePath
    }

    @MainActor
    static func logStatus(reason: String) {
        let status = status()
        AppLog.accessibility.info(
            """
            Accessibility status \(reason, privacy: .public): trusted=\(status.isTrusted), \
            state=\(String(describing: status.permissionState), privacy: .public), \
            requestedForCurrentApp=\(status.hasRequestedPermissionForCurrentApp), \
            bundleID=\(status.bundleIdentifier, privacy: .public), \
            bundleLocation=\(status.bundleLocation, privacy: .public), \
            registeredLocation=\(status.registeredApplicationLocation ?? "none", privacy: .public)
            """
        )
    }

    @MainActor
    @discardableResult
    static func requestPermission() -> Bool {
        logStatus(reason: "before request")

        if isTrusted() {
            AppLog.accessibility.info("Accessibility permission already granted")
            return true
        }

        let hasAlreadyRequested = hasRequestedPermissionForCurrentApp()
        markPermissionRequestedForCurrentApp()

        if !hasAlreadyRequested {
            let trustedAfterPrompt = isTrusted(prompt: true)
            guard !trustedAfterPrompt else {
                AppLog.accessibility.info("Accessibility permission granted after trusted check prompt")
                return true
            }
        } else {
            AppLog.accessibility.info("Accessibility permission already requested for current app; not showing AX prompt again")
        }

        AppLog.accessibility.warning("Accessibility permission missing or pending; opening System Settings")
        openSystemSettings()

        let trusted = isTrusted()
        logStatus(reason: "after opening settings")
        return trusted
    }

    @MainActor
    static func requestPermissionAndWait(timeout: TimeInterval = 20, pollInterval: TimeInterval = 0.5) async -> Bool {
        if requestPermission() {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                return isTrusted()
            }

            if isTrusted() {
                AppLog.accessibility.info("Accessibility permission detected after waiting")
                logStatus(reason: "after wait")
                return true
            }
        }

        AppLog.accessibility.warning("Accessibility permission still missing after waiting")
        logStatus(reason: "after wait timeout")
        return isTrusted()
    }

    @MainActor
    static func openSystemSettings() {
        guard let settingsURL else {
            AppLog.accessibility.error("Unable to create Accessibility settings URL")
            return
        }

        NSWorkspace.shared.open(settingsURL)
    }

    @MainActor
    static func resetPermissionForCurrentApp() async throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw ResetError.missingBundleIdentifier
        }

        AppLog.accessibility.warning("Resetting Accessibility permission for \(bundleIdentifier, privacy: .public)")

        try await Task.detached {
            try runTCCUtilReset(bundleIdentifier: bundleIdentifier)
        }.value

        clearPermissionRequest()
        logStatus(reason: "after reset")
    }

    /// Runs off the main actor: `waitUntilExit` and the pipe read block the
    /// calling thread for the lifetime of the tccutil process.
    private nonisolated static func runTCCUtilReset(bundleIdentifier: String) throws {
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            AppLog.accessibility.error(
                "Accessibility permission reset failed with status \(process.terminationStatus): \(output, privacy: .private)"
            )
            throw ResetError.failed(status: process.terminationStatus, output: output)
        }
    }

    @MainActor
    static func relaunchCurrentApp() throws {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        AppLog.accessibility.info("Relaunching app to refresh Accessibility permission state")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = relaunchArguments(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundlePath: bundlePath
        )

        try process.run()
        NSApp.terminate(nil)
    }

    /// Arguments for `/bin/sh` that reopen the bundle once the old process has
    /// exited (bounded wait) — a fixed delay can lose the race against a slow
    /// termination, and `LSMultipleInstancesProhibited` then rejects the new
    /// instance, leaving no Perch running. PID and path travel as positional
    /// parameters so they are never interpolated into the script.
    nonisolated static func relaunchArguments(processIdentifier: Int32, bundlePath: String) -> [String] {
        let script = """
        waited=0
        while kill -0 "$1" 2>/dev/null && [ "$waited" -lt 40 ]; do
          sleep 0.25
          waited=$((waited + 1))
        done
        exec /usr/bin/open -n "$2"
        """

        return ["-c", script, "perch-relaunch", String(processIdentifier), bundlePath]
    }

    @MainActor
    private static var currentBundlePath: String {
        Bundle.main.bundleURL.standardizedFileURL.path
    }

    @MainActor
    private static func markPermissionRequestedForCurrentApp() {
        UserDefaults.standard.set(currentBundlePath, forKey: requestedBundlePathKey)
        UserDefaults.standard.set(Date(), forKey: requestedAtKey)
    }

    @MainActor
    private static func clearPermissionRequest() {
        UserDefaults.standard.removeObject(forKey: requestedBundlePathKey)
        UserDefaults.standard.removeObject(forKey: requestedAtKey)
    }

    static func redactedPathForLogging(_ path: String) -> String {
        let standardizedURL = URL(fileURLWithPath: path).standardizedFileURL
        let fileManager = FileManager.default

        if let applicationsURL = try? fileManager.url(
            for: .applicationDirectory,
            in: .localDomainMask,
            appropriateFor: nil,
            create: false
        ), standardizedURL.path.hasPrefix(applicationsURL.standardizedFileURL.path + "/") {
            return "/Applications/\(standardizedURL.lastPathComponent)"
        }

        if let userApplicationsURL = try? fileManager.url(
            for: .applicationDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ), standardizedURL.path.hasPrefix(userApplicationsURL.standardizedFileURL.path + "/") {
            return "~/Applications/\(standardizedURL.lastPathComponent)"
        }

        let temporaryDirectoryPath = fileManager.temporaryDirectory.standardizedFileURL.path
        if standardizedURL.path.hasPrefix(temporaryDirectoryPath + "/") {
            return "<temporary>/\(standardizedURL.lastPathComponent)"
        }

        if standardizedURL.path.hasPrefix(NSHomeDirectory() + "/") {
            return "~/.../\(standardizedURL.lastPathComponent)"
        }

        return "<redacted>/\(standardizedURL.lastPathComponent)"
    }
}
