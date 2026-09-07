import AppKit
import SwiftUI

@MainActor
final class RestoreReportWindowController {
    static let shared = RestoreReportWindowController()
    private var window: NSWindow?

    func show(engine: SlotEngine) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: RestoreReportView(engine: engine)))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 680, height: 580))
            window.center()
            window.setFrameAutosaveName("PerchRestoreReportWindow")
            self.window = window
        }
        window?.title = L10n.text(.restoreActivity)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RestoreReportView: View {
    let engine: SlotEngine
    @State private var localization = LocalizationManager.shared
    @State private var errorMessage: String?
    @State private var repairTarget: WindowSnapshot?

    private var session: RestoreSession { engine.restoreSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text(session.isUndo ? .undoResults : .restoreActivity)).font(.title2.bold())
                    if let layout = session.layout { Text(layout.name).foregroundStyle(.secondary) }
                }
                Spacer()
                if session.isRunning {
                    Button(localization.text(.stopRestore)) { engine.cancelRestore() }
                        .disabled(session.isCancelling)
                }
            }
            if session.isRunning {
                progress
            } else if let result = session.result {
                Label(result.restoreSummary, systemImage: result.skipped == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.headline)
            }
            if let message = errorMessage ?? session.errorMessage {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            if let result = session.result {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(result.details) { report in
                            reportRow(report)
                            Divider().padding(.vertical, 10)
                        }
                    }
                }
            } else {
                ContentUnavailableView(localization.text(.noRestoreYet), systemImage: "rectangle.on.rectangle")
            }
            HStack {
                Button(localization.text(.retryRemaining)) {
                    run { _ = try await engine.retryLastRestore() }
                }
                .disabled(!session.canRetry)
                Button(localization.text(.undoLastRestore)) {
                    run { _ = try await engine.undoLastRestore() }
                }
                .disabled(!session.canUndo)
                .help(localization.text(.undoExplanation))
                Spacer()
            }
            Text(localization.text(session.isUndo ? .undoExplanation : .reportHelp))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 440)
        .sheet(item: $repairTarget) { snapshot in
            if let layout = session.layout {
                WindowRepairView(engine: engine, layoutID: layout.id, window: snapshot)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.isStabilizing {
                ProgressView().controlSize(.small)
                Text(localization.text(.waitingForDisplays))
            } else {
                ProgressView(value: Double(session.completedCount), total: Double(max(session.result?.total ?? 0, 1)))
                Text(localization.format(.restoreProgressFormat, session.completedCount, session.result?.total ?? 0))
                if let application = session.currentApplication {
                    Text(localization.format(.workingOnApplicationFormat, application)).foregroundStyle(.secondary)
                }
            }
            if session.isCancelling { Text(localization.text(.stoppingRestore)).foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    private func reportRow(_ report: RestoreWindowReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: report.outcome.symbolName)
                    .foregroundStyle(report.isSuccess ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.appName).font(.headline)
                    Text(report.windowTitle.isEmpty ? localization.text(.untitledWindow) : report.windowTitle)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(localization.text(report.outcome.labelKey)).foregroundStyle(.secondary)
            }
            if let message = report.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if !report.isSuccess && !session.isRunning && !session.isUndo {
                HStack {
                    if report.outcome == .appNotRunning || report.outcome == .launchFailed {
                        Button(localization.text(.openAndRetry)) {
                            run { _ = try await engine.retryLastRestore(windowIDs: [report.id], openApplications: true) }
                        }
                    } else {
                        Button(localization.text(.retryWindow)) {
                            run { _ = try await engine.retryLastRestore(windowIDs: [report.id]) }
                        }
                    }
                    if report.outcome == .ambiguousWindowMatch || report.outcome == .windowNotFound || report.outcome == .skipped {
                        Button(localization.text(.assignOpenWindow)) {
                            repairTarget = session.layout?.windows.first { $0.id == report.id }
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        Task { @MainActor in
            do { try await operation() }
            catch is CancellationError { }
            catch { errorMessage = LocalizedErrorMessages.message(for: error) }
        }
    }
}
