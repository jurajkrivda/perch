import SwiftUI

struct AccessibilityBanner: View {
    @Bindable var model: SettingsModel
    @State private var localization = LocalizationManager.shared

    var body: some View {
        if !model.isAccessibilityTrusted {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.hasRequestedAccessibilityPermission
                        ? localization.text(.accessibilityBannerPendingTitle)
                        : localization.text(.accessibilityBannerRequiredTitle))
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let resetError = model.accessibilityResetError {
                        Text(resetError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            actionButtons
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            actionButtons
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.orange.opacity(0.35))
            )
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(localization.text(.openSystemSettings)) {
            model.requestAccessibilityPermission()
        }
        Button(localization.text(.refreshButton)) {
            model.refreshAccessibilityStatus()
        }
        if model.hasRequestedAccessibilityPermission {
            Button(localization.text(.resetPermissionButton)) {
                model.resetAccessibilityPermission()
            }
            Button(localization.text(.restartPerch)) {
                do {
                    try AccessibilityManager.relaunchCurrentApp()
                } catch {
                    model.accessibilityResetError = error.localizedDescription
                }
            }
        }
    }

    private var message: String {
        if model.hasRequestedAccessibilityPermission {
            return localization.text(.accessibilityBannerPendingMessage)
        }

        return localization.text(.accessibilityBannerRequiredMessage)
    }
}
