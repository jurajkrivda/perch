import SwiftUI

struct WindowRepairView: View {
    let engine: SlotEngine
    let layoutID: String
    let window: WindowSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var localization = LocalizationManager.shared
    @State private var candidates: [WindowSnapshot] = []
    @State private var selection: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.text(.assignOpenWindow)).font(.title2.bold())
            Text(RestoreReportBuilder.applicationDisplayName(for: window.bundleIdentifier)).font(.headline)
            Text(localization.text(.chooseOpenWindow)).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if isLoading { ProgressView() }
            List(candidates, selection: $selection) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.windowTitle.isEmpty ? localization.text(.untitledWindow) : candidate.windowTitle)
                    Text(LayoutSnapshotView.frameDescription(candidate.frame)).font(.caption).foregroundStyle(.secondary)
                }.tag(candidate.id)
            }
            .overlay {
                if candidates.isEmpty && !isLoading {
                    Text(localization.text(.noOpenWindowsForApp)).foregroundStyle(.secondary).padding()
                }
            }
            HStack {
                Button(localization.text(.refreshButton)) { Task { await refresh() } }.disabled(isLoading)
                Spacer()
                Button(localization.text(.cancelButton)) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(localization.text(.useThisWindow), action: assign)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || isLoading || engine.restoreSession.isRunning)
            }
        }
        .padding(20)
        .frame(width: 580, height: 420)
        .task { await refresh() }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        selection = nil
        do {
            candidates = try await engine.repairCandidates(for: window)
            errorMessage = nil
        } catch { errorMessage = LocalizedErrorMessages.message(for: error) }
    }

    private func assign() {
        guard let candidate = candidates.first(where: { $0.id == selection }) else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                try await engine.reassignWindow(layoutID: layoutID, windowID: window.id, to: candidate)
                dismiss()
            } catch { errorMessage = LocalizedErrorMessages.message(for: error) }
        }
    }
}
