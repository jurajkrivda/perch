import AppKit

@MainActor
enum RestoreReportBuilder {
    static func reportForRestoreFailure(
        snapshot: WindowSnapshot,
        error: Error,
        didLaunchApplication: Bool = false,
        matchReason: WindowMoveMatchReason? = nil
    ) -> RestoreWindowReport {
        let outcome: RestoreWindowOutcome

        switch error {
        case WindowMoverError.windowNotFound:
            outcome = .windowNotFound
        case WindowMoverError.ambiguousWindowMatch:
            outcome = .ambiguousWindowMatch
        case WindowMoverError.appNotRunning:
            outcome = .appNotRunning
        case WindowMoverError.frameWriteFailed, WindowMoverError.frameReadFailed, WindowMoverError.invalidFrame:
            outcome = .frameWriteFailed
        default:
            outcome = .skipped
        }

        AppLog.windows.warning(
            "Skipping restore for \(snapshot.bundleIdentifier, privacy: .public): \(restoreLogDescription(for: error), privacy: .public)"
        )

        return report(
            for: snapshot,
            outcome: outcome,
            didLaunchApplication: didLaunchApplication,
            matchReason: matchReason,
            message: LocalizedErrorMessages.message(for: error)
        )
    }

    static func reportsForClosedApplication(_ snapshots: [WindowSnapshot]) -> [RestoreWindowReport] {
        snapshots.map { snapshot in
            AppLog.windows.info(
                "Skipping restore for \(snapshot.bundleIdentifier, privacy: .public): app closed; auto-open disabled"
            )

            return report(
                for: snapshot,
                outcome: .appNotRunning,
                didLaunchApplication: false,
                matchReason: nil,
                message: L10n.text(.applicationClosed)
            )
        }
    }

    static func report(
        for snapshot: WindowSnapshot,
        outcome: RestoreWindowOutcome,
        didLaunchApplication: Bool,
        matchReason: WindowMoveMatchReason?,
        message: String?
    ) -> RestoreWindowReport {
        RestoreWindowReport(
            id: snapshot.id,
            bundleIdentifier: snapshot.bundleIdentifier,
            appName: applicationDisplayName(for: snapshot.bundleIdentifier),
            windowTitle: snapshot.windowTitle,
            outcome: outcome,
            didLaunchApplication: didLaunchApplication,
            matchReason: matchReason,
            message: message
        )
    }

    private static func restoreLogDescription(for error: Error) -> String {
        switch error {
        case WindowMoverError.windowNotFound:
            "window not found"
        case WindowMoverError.ambiguousWindowMatch:
            "ambiguous window match"
        case WindowMoverError.frameWriteFailed:
            "frame write failed"
        case WindowMoverError.frameReadFailed:
            "frame read failed"
        case WindowMoverError.invalidFrame:
            "invalid frame"
        case WindowMoverError.appNotRunning:
            "app not running"
        case WindowMoverError.accessibilityPermissionMissing:
            "accessibility permission missing"
        default:
            "restore failed"
        }
    }

    private static func applicationDisplayName(for bundleIdentifier: String) -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }

        if let bundle = Bundle(url: appURL) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !displayName.isEmpty {
                return displayName
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }

        return appURL.deletingPathExtension().lastPathComponent
    }

    static func reports(
        for snapshots: [WindowSnapshot],
        moveResults: [WindowBatchMoveResult],
        didLaunchApplication: Bool
    ) -> [RestoreWindowReport] {
        let resultsBySnapshotID = Dictionary(
            moveResults.map { ($0.snapshotID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return snapshots.map { snapshot in
            guard let result = resultsBySnapshotID[snapshot.id] else {
                return reportForRestoreFailure(
                    snapshot: snapshot,
                    error: WindowMoverError.windowNotFound(
                        bundleIdentifier: snapshot.bundleIdentifier,
                        title: snapshot.windowTitle
                    ),
                    didLaunchApplication: didLaunchApplication
                )
            }

            if let error = result.error {
                return reportForRestoreFailure(
                    snapshot: snapshot,
                    error: error,
                    didLaunchApplication: didLaunchApplication,
                    matchReason: result.matchReason
                )
            }

            return report(
                for: snapshot,
                outcome: didLaunchApplication ? .launchedAndRestored : .restored,
                didLaunchApplication: didLaunchApplication,
                matchReason: result.matchReason,
                message: nil
            )
        }
    }

}
