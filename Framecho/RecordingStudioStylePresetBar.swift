//
//  RecordingStudioStylePresetBar.swift
//  Framecho
//

import SwiftUI

struct RecordingStudioStylePresetBar: View {
    @Bindable var model: RecordingStudioModel
    @Bindable var presetStore: RecordingStudioStylePresetStore

    @State private var isNameEditorPresented = false
    @State private var draftName = ""
    @State private var presetPendingDeletion: RecordingStudioStylePreset?
    @FocusState private var isNameFieldFocused: Bool

    private var appliedPreset: RecordingStudioStylePreset? {
        presetStore.preset(id: model.appliedStylePresetID)
    }

    private var duplicateNamePreset: RecordingStudioStylePreset? {
        presetStore.preset(named: draftName)
    }

    private var displayTitle: String {
        appliedPreset?.name ?? String(localized: "Presets…")
    }

    private var isAppliedPresetModified: Bool {
        guard let appliedPreset else { return false }
        return !appliedPreset.matches(model.style)
    }

    private var canSaveName: Bool {
        !RecordingStudioStylePresetStore.normalizedName(draftName).isEmpty
            && duplicateNamePreset == nil
            && !model.style.hasMissingCustomWallpaper
    }

    /// What the menu shows as applied: nothing once the style has been
    /// changed away from the preset, so the checkmark never lies.
    private var selectedPresetID: RecordingStudioStylePreset.ID? {
        isAppliedPresetModified ? nil : model.appliedStylePresetID
    }

    private var availablePresets: [RecordingStudioStylePreset] {
        presetStore.presets.filter { !$0.hasMissingWallpaper }
    }

    private var missingPresets: [RecordingStudioStylePreset] {
        presetStore.presets.filter(\.hasMissingWallpaper)
    }

    /// A toolbar menu: presets restyle the whole video, so they sit with the
    /// window's other document actions rather than inside one inspector tab.
    var body: some View {
        Menu {
            if !availablePresets.isEmpty {
                Picker("Saved Presets", selection: Binding(
                    get: { selectedPresetID },
                    set: { selectPreset($0) }
                )) {
                    Text("Current Settings").tag(RecordingStudioStylePreset.ID?.none)
                    ForEach(availablePresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .pickerStyle(.inline)
            }

            if !missingPresets.isEmpty {
                Section("Wallpaper Missing") {
                    ForEach(missingPresets) { preset in
                        Button("Delete “\(preset.name)”…", systemImage: "trash") {
                            presetPendingDeletion = preset
                        }
                    }
                }
            }

            if !availablePresets.isEmpty {
                Menu("Default Preset") {
                    Picker("Default Preset", selection: Binding(
                        get: { presetStore.activePreset?.id },
                        set: { presetStore.setActivePreset(id: $0) }
                    )) {
                        Text("None").tag(RecordingStudioStylePreset.ID?.none)
                        ForEach(availablePresets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            Divider()

            Button("Save as Preset…", systemImage: "plus") {
                draftName = ""
                isNameEditorPresented = true
            }

            if let appliedPreset {
                Button("Delete “\(appliedPreset.name)”…", systemImage: "trash") {
                    presetPendingDeletion = appliedPreset
                }
            }
        } label: {
            Label {
                Text(verbatim: displayTitle)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "wand.and.stars")
            }
            .labelStyle(.titleAndIcon)
        }
        .help(presetHelp)
        .accessibilityLabel("Studio style preset")
        .accessibilityValue(presetAccessibilityValue)
        .popover(isPresented: $isNameEditorPresented, arrowEdge: .bottom) {
            nameEditor
        }
        .alert(
            "Delete Preset?",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button("Delete", role: .destructive) {
                presetStore.deletePreset(id: preset.id)
                if model.appliedStylePresetID == preset.id {
                    model.appliedStylePresetID = nil
                }
                presetPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                presetPendingDeletion = nil
            }
        } message: { preset in
            Text("“\(preset.name)” will be removed from your saved presets. The current recording won’t change.")
        }
    }

    private func selectPreset(_ presetID: RecordingStudioStylePreset.ID?) {
        guard let preset = presetStore.preset(id: presetID) else {
            model.appliedStylePresetID = nil
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            model.applyStylePreset(preset)
        }
    }

    private var presetHelp: String {
        if let activePreset = presetStore.activePreset {
            return String(localized: "Choose a preset. \(activePreset.name) is applied to new recordings.")
        }
        return String(localized: "Choose a background, layout, cursor, and camera preset")
    }

    private var presetAccessibilityValue: String {
        var details = [displayTitle]
        if isAppliedPresetModified {
            details.append(String(localized: "modified"))
        }
        if appliedPreset?.hasMissingWallpaper == true {
            details.append(String(localized: "wallpaper missing"))
        }
        return details.joined(separator: ", ")
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Preset")
                    .font(.system(size: 14, weight: .semibold))

                Text("Save the current background, layout, cursor size, and camera settings. It will be used for new recordings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Preset name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .onSubmit(savePreset)
                    .onChange(of: draftName) { _, newValue in
                        let limitedName = String(
                            newValue.prefix(RecordingStudioStylePresetStore.maximumNameLength)
                        )
                        if limitedName != newValue {
                            draftName = limitedName
                        }
                    }

                if model.style.hasMissingCustomWallpaper {
                    Label(
                        "The selected wallpaper can’t be found. Choose it again before saving.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                } else if duplicateNamePreset != nil {
                    Label(
                        "A preset with this name already exists.",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    isNameEditorPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    savePreset()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSaveName)
            }
        }
        .padding(16)
        .frame(width: 292)
        .onAppear {
            Task { @MainActor in
                isNameFieldFocused = true
            }
        }
    }

    private func savePreset() {
        guard canSaveName else { return }
        guard let preset = presetStore.savePreset(named: draftName, style: model.style) else {
            return
        }
        model.appliedStylePresetID = preset.id
        presetStore.setActivePreset(id: preset.id)
        isNameEditorPresented = false
    }
}
