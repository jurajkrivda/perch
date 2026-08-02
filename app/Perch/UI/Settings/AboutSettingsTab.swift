import SwiftUI

struct AboutSettingsTab: View {
    @Bindable var model: SettingsModel
    @State private var localization = LocalizationManager.shared
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsError: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Perch")
                .font(.title2.weight(.semibold))

            Text(localization.format(.aboutVersionFormat, version))
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text(localization.text(.aboutDescriptionSummary))
                    .font(.callout)
                    .foregroundStyle(.primary)

                Text(localization.text(.aboutDescriptionRestore))

                Text(localization.text(.aboutDescriptionPrivacy))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

            Link(
                localization.text(.aboutMadeBy),
                destination: URL(string: "https://github.com/jurajkrivda/perch")!
            )
                .font(.caption)

            LabeledContent(localization.text(.aboutAccessibilityLabel)) {
                Text(model.isAccessibilityTrusted ? localization.text(.aboutGranted) : localization.text(.aboutMissing))
                    .foregroundStyle(model.isAccessibilityTrusted ? .green : .orange)
            }
            .frame(maxWidth: 260)

            if !model.isAccessibilityTrusted {
                Button(localization.text(.openSystemSettings)) {
                    model.requestAccessibilityPermission()
                }
            }

            Button {
                exportDiagnostics()
            } label: {
                if isExportingDiagnostics {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(localization.text(.aboutExportDiagnostics), systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isExportingDiagnostics)

            Text(localization.text(.aboutDiagnosticsRedacted))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let diagnosticsError {
                Text(diagnosticsError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportDiagnostics() {
        isExportingDiagnostics = true
        diagnosticsError = nil

        Task { @MainActor in
            defer { isExportingDiagnostics = false }

            do {
                _ = try await DiagnosticsExporter.export()
                ToastWindow.show(localization.text(.diagnosticsExported))
            } catch let error as CocoaError where error.code == .userCancelled {
                diagnosticsError = nil
            } catch {
                diagnosticsError = error.localizedDescription
            }
        }
    }
}
