import SwiftUI

struct LayoutsSettingsTab: View {
    @Bindable var model: SettingsModel
    @State private var localization = LocalizationManager.shared
    @State private var recordingLayout: Slot?
    @State private var pendingDeletion: Slot?
    @State private var detailLayout: Slot?
    @State private var showsHistory = false
    @FocusState private var focusedLayoutID: String?

    var body: some View {
        Form {
            automaticLayoutSection
            Section {
                if model.document.slots.isEmpty {
                    Text(localization.text(.noLayouts))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.document.slots) { layout in
                        layoutRow(layout)
                    }
                }
            } header: {
                Text(localization.text(.layoutsSectionTitle))
            }

            Section {
                HStack {
                    TextField(localization.text(.newLayoutNamePlaceholder), text: $model.newLayoutName)
                        .onSubmit(createLayout)
                        .disabled(model.isCreatingLayout)
                    Button(localization.text(.captureCurrentLayout), action: createLayout)
                        .disabled(trimmedNewName.isEmpty || !canCapture)
                }
                Text(localization.text(.captureLayoutHelp)).font(.caption).foregroundStyle(.secondary)
                if model.isCreatingLayout { ProgressView().controlSize(.small) }
            }

            Section {
                Button(localization.text(.layoutHistory)) { showsHistory = true }
                    .disabled(model.slotEngine == nil)
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                } header: {
                    Text(localization.text(.errorSectionTitle))
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top) {
            if !model.isAccessibilityTrusted {
                AccessibilityBanner(model: model)
                    .padding([.horizontal, .top])
            }
        }
        .sheet(item: $recordingLayout) { layout in
            shortcutRecorderSheet(for: layout)
        }
        .sheet(item: $detailLayout) { layout in
            if let engine = model.slotEngine { LayoutDetailsView(engine: engine, layout: layout) }
        }
        .sheet(isPresented: $showsHistory) {
            if let engine = model.slotEngine { LayoutHistoryView(engine: engine) }
        }
        .alert(localization.text(.deleteLayoutTitle), isPresented: deletionBinding) {
            Button(localization.text(.cancelButton), role: .cancel) { pendingDeletion = nil }
            Button(localization.text(.deleteButton), role: .destructive) {
                if let pendingDeletion {
                    model.deleteLayout(pendingDeletion)
                }
                pendingDeletion = nil
            }
        } message: {
            Text(localization.format(.deleteLayoutMessageFormat, pendingDeletion?.name ?? ""))
        }
    }

    private var trimmedNewName: String {
        model.newLayoutName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCapture: Bool {
        model.isAccessibilityTrusted && !model.isCreatingLayout && model.changingLayoutID == nil &&
            model.slotEngine?.restoreSession.isRunning != true
    }

    private var automaticLayoutSection: some View {
        Section {
            if let topology = model.currentTopology {
                Picker(localization.text(.automaticLayoutTitle), selection: Binding(
                    get: { model.currentPreferredLayoutID },
                    set: { model.setPreferredLayout($0.isEmpty ? nil : $0) }
                )) {
                    Text(localization.text(.latestMatchingLayout)).tag("")
                    ForEach(model.document.slots.filter {
                        !$0.windows.isEmpty && $0.capturedTopology?.matchesIdentity(of: topology) == true
                    }) { layout in
                        Text(layout.name).tag(layout.id)
                    }
                }
                if model.autoRestoreMode == .off {
                    Text(localization.text(.autoRestoreDecisionDisabled)).font(.caption).foregroundStyle(.secondary)
                } else if let selected = model.automaticLayout, !selected.windows.isEmpty {
                    Text(localization.format(.selectedAutomaticLayoutFormat, selected.name))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(localization.text(.noMatchingSavedLayout)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(localization.text(.unknownDisplayArrangement)).foregroundStyle(.secondary)
            }
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented { pendingDeletion = nil }
            }
        )
    }

    private func createLayout() {
        guard !trimmedNewName.isEmpty, canCapture else { return }
        model.createLayout()
    }

    private func layoutRow(_ layout: Slot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(localization.text(.layoutNameField), text: nameBinding(for: layout))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($focusedLayoutID, equals: layout.id)
                    .onSubmit { model.renameLayout(layout) }

                Text(localization.format(
                    .windowsAndShortcutFormat,
                    layout.windows.count,
                    localization.windowNoun(count: layout.windows.count),
                    model.effectiveHotkeyDisplay(for: layout)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                if let date = layout.lastSaved {
                    HStack(spacing: 4) {
                        Text(localization.text(.lastSavedLabel))
                        Text(date, format: .dateTime.day().month().hour().minute())
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let topology = layout.capturedTopology,
                   model.document.settings.preferredLayoutsByTopology[topology.identity] == layout.id {
                    Label(localization.text(.preferredForDisplays), systemImage: "star.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                Button(localization.text(.recordRestoreShortcutHelp)) { recordingLayout = layout }
                Button(localization.text(.clearCustomShortcutHelp)) { model.setRestoreHotkey(nil, for: layout) }
                    .disabled(layout.restoreHotkey == nil)
                if let topology = layout.capturedTopology, !layout.windows.isEmpty {
                    Divider()
                    if model.document.settings.preferredLayoutsByTopology[topology.identity] == layout.id {
                        Button(localization.text(.followLatestSaved)) { model.setPreferredLayout(nil, topology: topology) }
                    } else {
                        Button(localization.text(.useForAutomaticRestore)) { model.setPreferredLayout(layout.id, topology: topology) }
                    }
                }
                Divider()
                Button(localization.text(.deleteLayoutHelp), role: .destructive) { pendingDeletion = layout }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel(layout.name)
          }
          HStack {
              Button(localization.text(.restorePromptButton)) { model.restoreLayout(layout) }
                  .disabled(layout.windows.isEmpty || model.slotEngine?.restoreSession.isRunning == true)
              Button(localization.text(.captureCurrentLayout)) { model.saveCurrentWindows(to: layout) }
                  .disabled(!canCapture)
              Button(localization.text(.layoutDetails)) { detailLayout = layout }
              if model.changingLayoutID == layout.id { ProgressView().controlSize(.small) }
          }
          .controlSize(.small)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .onChange(of: focusedLayoutID) { previous, _ in
            if previous == layout.id {
                model.renameLayout(layout)
            }
        }
    }

    private func shortcutRecorderSheet(for layout: Slot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.format(.restoreLayoutFormat, layout.name))
                .font(.headline)

            HotkeyRecorder(
                onRecord: { hotkey in
                    model.setRestoreHotkey(hotkey, for: layout)
                    recordingLayout = nil
                },
                onCancel: { recordingLayout = nil }
            )

            HStack {
                Spacer()
                Button(localization.text(.cancelButton)) { recordingLayout = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func nameBinding(for layout: Slot) -> Binding<String> {
        Binding(
            get: { model.layoutNameDrafts[layout.id] ?? layout.name },
            set: { model.layoutNameDrafts[layout.id] = $0 }
        )
    }
}
