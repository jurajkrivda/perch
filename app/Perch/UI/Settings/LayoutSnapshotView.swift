import SwiftUI

/// The same saved-window preview is used for current layouts and old versions.
struct LayoutSnapshotView: View {
    let layout: Slot
    var onRepair: ((WindowSnapshot) -> Void)?
    @State private var localization = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let date = layout.lastSaved {
                HStack {
                    Text(localization.text(.lastSavedLabel))
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let topology = layout.capturedTopology, !topology.entries.isEmpty {
                Label(localization.format(.savedDisplaysFormat, topology.entries.count), systemImage: "display.2")
                displayPreview(topology)
            } else {
                Text(localization.text(.unknownDisplayArrangement)).foregroundStyle(.secondary)
            }
            ForEach(LayoutWindowRestorer.snapshotGroupsPreservingOrder(layout.windows), id: \.bundleIdentifier) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(RestoreReportBuilder.applicationDisplayName(for: group.bundleIdentifier)).font(.headline)
                    ForEach(group.snapshots) { snapshot in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.windowTitle.isEmpty ? localization.text(.untitledWindow) : snapshot.windowTitle)
                                    .textSelection(.enabled)
                                Text(Self.frameDescription(snapshot.frame)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let onRepair {
                                Button(localization.text(.assignOpenWindow)) { onRepair(snapshot) }.controlSize(.small)
                            }
                        }
                    }
                }
                Divider()
            }
            if layout.windows.isEmpty { Text(localization.text(.noWindowsSaved)).foregroundStyle(.secondary) }
        }
        .environment(\.locale, Locale(identifier: localization.effectiveLanguage.rawValue))
    }

    private func displayPreview(_ topology: DisplayTopologyFingerprint) -> some View {
        GeometryReader { geometry in
            let bounds = topology.entries.reduce(CGRect.null) { $0.union($1.bounds) }
            let scale = min(geometry.size.width / max(bounds.width, 1), geometry.size.height / max(bounds.height, 1))
            let offset = CGPoint(
                x: (geometry.size.width - bounds.width * scale) / 2,
                y: (geometry.size.height - bounds.height * scale) / 2
            )
            ZStack(alignment: .topLeading) {
                ForEach(Array(topology.entries.enumerated()), id: \.offset) { index, display in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.5)))
                        .overlay(alignment: .topLeading) {
                            Text("\(index + 1)\(display.isMain ? " ★" : "")").font(.caption2).padding(4)
                        }
                        .frame(width: max(display.bounds.width * scale, 1), height: max(display.bounds.height * scale, 1))
                        .offset(x: (display.bounds.minX - bounds.minX) * scale + offset.x,
                                y: (display.bounds.minY - bounds.minY) * scale + offset.y)
                }
                ForEach(layout.windows) { snapshot in
                    let frame = snapshot.frame.cgRect.intersection(bounds)
                    if !frame.isNull {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor.opacity(0.6)))
                            .frame(width: max(frame.width * scale, 1), height: max(frame.height * scale, 1))
                            .offset(x: (frame.minX - bounds.minX) * scale + offset.x,
                                    y: (frame.minY - bounds.minY) * scale + offset.y)
                    }
                }
            }
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.format(.savedDisplaysFormat, topology.entries.count))
    }

    static func frameDescription(_ frame: CodableRect) -> String {
        String(format: "%.0f × %.0f · (%.0f, %.0f)", frame.width, frame.height, frame.x, frame.y)
    }
}

struct LayoutDetailsView: View {
    let engine: SlotEngine
    @State var layout: Slot
    @State private var repairTarget: WindowSnapshot?
    @State private var errorMessage: String?
    @State private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(layout.name).font(.title2.bold())
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            ScrollView {
                LayoutSnapshotView(layout: layout, onRepair: { repairTarget = $0 })
                    .disabled(engine.restoreSession.isRunning)
            }
            HStack {
                Spacer()
                Button(localization.text(.closeButton)) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 520)
        .sheet(item: $repairTarget) { snapshot in
            WindowRepairView(engine: engine, layoutID: layout.id, window: snapshot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .perchDocumentDidChange)) { _ in
            Task { @MainActor in
                do {
                    if let current = try await engine.currentDocument().slots.first(where: { $0.id == layout.id }) {
                        layout = current
                    }
                } catch { errorMessage = LocalizedErrorMessages.message(for: error) }
            }
        }
    }
}
