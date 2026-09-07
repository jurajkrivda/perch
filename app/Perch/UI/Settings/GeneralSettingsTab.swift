import SwiftUI

struct GeneralSettingsTab: View {
    @Bindable var model: SettingsModel
    @State private var localization = LocalizationManager.shared
    @State private var showsAutoRestoreAdvanced = false

    var body: some View {
        Form {
            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                } header: {
                    Text(localization.text(.errorSectionTitle))
                }
            }

            Section {
                Picker(localization.text(.languagePickerLabel), selection: $model.selectedLanguage) {
                    ForEach(model.languageOptions) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } header: {
                Text(localization.text(.languageSectionTitle))
            }

            Section {
                Toggle(localization.text(.launchAtLogin), isOn: $model.launchAtLoginEnabled)
                    .onChange(of: model.launchAtLoginEnabled) { _, isEnabled in
                        model.updateLaunchAtLogin(isEnabled)
                    }
                LabeledContent(localization.text(.launchAtLoginStatus), value: model.launchAtLoginStatus)

                if let launchAtLoginError = model.launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(localization.text(.startupSectionTitle))
            }

            Section {
                Toggle(localization.text(.automaticUpdateChecksToggle), isOn: $model.automaticUpdateChecksEnabled)
                    .onChange(of: model.automaticUpdateChecksEnabled) { _, isEnabled in
                        model.updateAutomaticUpdateChecks(isEnabled)
                    }
            } header: {
                Text(localization.text(.updatesSectionTitle))
            }

            Section {
                Toggle(localization.text(.menuBarShowLabel), isOn: $model.showsMenuBarLabel)
                    .onChange(of: model.showsMenuBarLabel) { _, isVisible in
                        model.updateMenuBarLabelVisibility(isVisible)
                    }
            } header: {
                Text(localization.text(.menuBarSectionTitle))
            } footer: {
                Text(localization.text(.menuBarFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(localization.text(.autoRestoreModeLabel), selection: $model.autoRestoreMode) {
                    Text(localization.text(.autoRestoreDoNothing)).tag(AutoRestoreMode.off)
                    Text(localization.text(.autoRestorePrompt)).tag(AutoRestoreMode.prompt)
                    Text(localization.text(.autoRestoreAutomatic)).tag(AutoRestoreMode.automatic)
                }
                .pickerStyle(.menu)
                .onChange(of: model.autoRestoreMode) { _, mode in
                    model.updateAutoRestoreMode(mode)
                }

                DisclosureGroup(
                    localization.text(.autoRestoreAdvanced),
                    isExpanded: $showsAutoRestoreAdvanced
                ) {
                    Stepper(
                        value: $model.autoRestoreSettleTimeout,
                        in: SlotStoreDocument.autoRestoreSettleTimeoutRange,
                        step: 1
                    ) {
                        LabeledContent(
                            localization.text(.autoRestoreSettleTimeoutLabel),
                            value: "\(Int(model.autoRestoreSettleTimeout)) s"
                        )
                    }
                    .onChange(of: model.autoRestoreSettleTimeout) { _, timeout in
                        model.updateAutoRestoreSettleTimeout(timeout)
                    }

                    Text(localization.text(.autoRestoreSettleTimeoutFooter))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(localization.text(.autoRestoreSectionTitle))
            } footer: {
                if model.autoRestoreMode == .automatic {
                    Text(localization.text(.autoRestoreAutomaticFooter))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.autoRestoreMode == .prompt {
                    Text(localization.text(.autoRestorePromptFooter))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(localization.text(.openMissingAppsDuringRestore), isOn: $model.opensMissingApplicationsOnRestore)
                    .onChange(of: model.opensMissingApplicationsOnRestore) { _, shouldOpenApplications in
                        model.updateMissingApplicationsRestoreBehavior(shouldOpenApplications)
                    }
            } header: {
                Text(localization.text(.restoreSectionTitle))
            } footer: {
                Text(localization.text(.restoreSectionFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top) {
            if !model.isAccessibilityTrusted {
                AccessibilityBanner(model: model)
                    .padding([.horizontal, .top])
            }
        }
    }
}
