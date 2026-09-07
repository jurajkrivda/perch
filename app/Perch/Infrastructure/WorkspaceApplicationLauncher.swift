import AppKit

enum ApplicationLaunchResult: Equatable, Sendable {
    case launched
    case alreadyRunning
    case notInstalled
    case failed(String)
}

@MainActor
protocol ApplicationLaunching {
    func launchApplication(bundleIdentifier: String) async throws -> ApplicationLaunchResult
}

struct WorkspaceApplicationLauncher: ApplicationLaunching {
    func launchApplication(bundleIdentifier: String) async throws -> ApplicationLaunchResult {
        try Task.checkCancellation()
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            return .alreadyRunning
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return .notInstalled
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        // Resolved before the continuation: the completion handler runs off the
        // main actor and cannot read the localization state.
        let missingApplicationMessage = L10n.text(.launchDidNotReturnApp)

        return try await ApplicationLaunchOperation.wait(
            timeout: .seconds(10),
            timeoutMessage: L10n.text(.applicationLaunchTimedOut)
        ) { complete in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                if let error {
                    complete(.failed(error.localizedDescription))
                } else if application != nil {
                    complete(.launched)
                } else {
                    complete(.failed(missingApplicationMessage))
                }
            }
        }
    }
}

/// Waits for Launch Services without letting a missing completion hang restore
/// or quit forever. A task-group race would still wait for a stuck callback
/// task to finish; this owner resumes its continuation exactly once instead.
@MainActor
final class ApplicationLaunchOperation {
    typealias Completion = @Sendable (ApplicationLaunchResult) -> Void

    private var continuation: CheckedContinuation<ApplicationLaunchResult, Error>?
    private var timeoutTask: Task<Void, Never>?

    private init() {}

    static func wait(
        timeout: Duration,
        timeoutMessage: String,
        start: (@escaping Completion) -> Void
    ) async throws -> ApplicationLaunchResult {
        try await ApplicationLaunchOperation().perform(
            timeout: timeout, timeoutMessage: timeoutMessage, start: start
        )
    }

    private func perform(
        timeout: Duration,
        timeoutMessage: String,
        start: (@escaping Completion) -> Void
    ) async throws -> ApplicationLaunchResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(.success(.failed(timeoutMessage)))
                }
                start { [weak self] result in
                    Task { @MainActor [weak self] in self?.finish(.success(result)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<ApplicationLaunchResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
