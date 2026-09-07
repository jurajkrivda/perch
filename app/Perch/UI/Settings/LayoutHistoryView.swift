import SwiftUI

struct LayoutHistoryView: View {
    let engine: SlotEngine
    var layoutID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var localization = LocalizationManager.shared
    @State private var revisions: [LayoutRevision] = []
    @State private var selection: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didRecover = false

    private var selectedRevision: LayoutRevision? { revisions.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.text(.layoutHistory)).font(.title2.bold())
            Text(localization.text(.historyExplanation)).font(.callout).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if didRecover { Label(localization.text(.historyRestored), systemImage: "checkmark.circle").foregroundStyle(.green) }
            if isLoading { ProgressView() }
            if revisions.isEmpty && !isLoading {
                ContentUnavailableView(localization.text(.noLayoutHistory), systemImage: "clock.arrow.circlepath")
            } else {
                HStack(spacing: 16) {
                    List(revisions, selection: $selection) { revision in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(revision.layout.name).font(.headline)
                            Text(revision.layout.lastSaved ?? revision.recordedAt,
                                 format: .dateTime.day().month().year().hour().minute().second())
                                .font(.caption)
                            Text("\(revision.layout.windows.count) \(localization.windowNoun(count: revision.layout.windows.count))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(revision.id)
                    }
                    .frame(width: 210)
                    ScrollView {
                        if let selectedRevision { LayoutSnapshotView(layout: selectedRevision.layout) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Button(localization.text(.refreshButton)) { Task { await refresh() } }.disabled(isLoading)
                Spacer()
                Button(localization.text(.closeButton)) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(localization.text(.restoreVersion), action: recover)
                    .disabled(selection == nil || isLoading || engine.restoreSession.isRunning)
            }
        }
        .padding(20)
        .frame(width: 760, height: 540)
        .environment(\.locale, Locale(identifier: localization.effectiveLanguage.rawValue))
        .task { await refresh() }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            revisions = try await engine.layoutHistory(layoutID: layoutID)
            if !revisions.contains(where: { $0.id == selection }) { selection = revisions.first?.id }
            errorMessage = nil
        } catch { errorMessage = LocalizedErrorMessages.message(for: error) }
    }

    private func recover() {
        guard let selection else { return }
        isLoading = true
        Task { @MainActor in
            do {
                try await engine.restoreRevision(id: selection)
                didRecover = true
                errorMessage = nil
                isLoading = false
                await refresh()
            } catch {
                errorMessage = LocalizedErrorMessages.message(for: error)
                isLoading = false
            }
        }
    }
}
