import SwiftUI

struct LayoutsSettingsTab: View {
    @Bindable var model: SettingsModel
    @State private var localization = LocalizationManager.shared
    @State private var recordingLayout: Slot?
    @State private var pendingDeletion: Slot?
    @FocusState private var focusedLayoutID: String?

    var body: some View {
        Form {
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
                    Button(localization.text(.addButton), action: createLayout)
                        .disabled(trimmedNewName.isEmpty || model.isCreatingLayout)
                }
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

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented { pendingDeletion = nil }
            }
        )
    }

    private func createLayout() {
        guard !trimmedNewName.isEmpty else { return }
        model.createLayout()
    }

    private func layoutRow(_ layout: Slot) -> some View {
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
            }

            Spacer()

            Button {
                recordingLayout = layout
            } label: {
                Image(systemName: "record.circle")
            }
            .help(localization.text(.recordRestoreShortcutHelp))
            .accessibilityLabel("\(localization.text(.recordRestoreShortcutHelp)): \(layout.name)")

            Button {
                model.setRestoreHotkey(nil, for: layout)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help(localization.text(.clearCustomShortcutHelp))
            .accessibilityLabel("\(localization.text(.clearCustomShortcutHelp)): \(layout.name)")
            .disabled(layout.restoreHotkey == nil)

            Button(role: .destructive) {
                pendingDeletion = layout
            } label: {
                Image(systemName: "trash")
            }
            .help(localization.text(.deleteLayoutHelp))
            .accessibilityLabel("\(localization.text(.deleteLayoutHelp)): \(layout.name)")
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
