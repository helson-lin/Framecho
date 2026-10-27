//
//  AfterCaptureSettingsSection.swift
//  Framecho
//

import SwiftUI

/// A Form section listing the configurable after-capture actions for a given
/// capture type (screenshot or recording).
struct AfterCaptureActionsSection: View {
    let type: AfterCaptureType
    let title: LocalizedStringResource

    var body: some View {
        Section {
            if type == .screenshot {
                ScreenshotCapturePresetSettings()
            }
            ForEach(AfterCaptureAction.actions(for: type)) { action in
                AfterCaptureToggleRow(action: action, type: type)
            }
        } header: {
            Text(title)
        }
    }
}

private struct ScreenshotCapturePresetSettings: View {
    @AppStorage(FramechoPreferences.autoApplyScreenshotPresetKey) private var autoApplyPreset = false
    private let presetStore = AnnotationBackgroundPresetStore.shared

    private var availablePresets: [AnnotationBackgroundPreset] {
        presetStore.presets.filter { !$0.hasMissingWallpaper }
    }

    var body: some View {
        Toggle(isOn: $autoApplyPreset) {
            SettingsControlLabel(
                "Automatically apply preset",
                detail: "Apply the default screenshot preset before copying, saving, or uploading."
            )
        }

        if autoApplyPreset {
            Picker(selection: Binding(
                get: { presetStore.activePreset?.id },
                set: { presetStore.setActivePreset(id: $0) }
            )) {
                Text("None").tag(Optional<AnnotationBackgroundPreset.ID>.none)
                ForEach(availablePresets) { preset in
                    Text(verbatim: preset.name).tag(Optional(preset.id))
                }
            } label: {
                SettingsControlLabel(
                    "Default Preset",
                    detail: "Also used when opening new screenshots in the annotation editor."
                )
            }

            if presetStore.activePreset == nil {
                Group {
                    if presetStore.presets.isEmpty {
                        Text("Save a preset in the annotation editor first.")
                    } else if availablePresets.isEmpty {
                        Text("Saved presets have missing wallpapers. Restore a wallpaper or save a new preset in the annotation editor.")
                    } else {
                        Text("Choose a default preset to apply it automatically.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AfterCaptureToggleRow: View {
    @AppStorage private var isOn: Bool
    /// The same capture type's upload toggle: copying the share link only
    /// applies when uploads are on.
    @AppStorage private var uploadIsOn: Bool
    private let title: String
    private let subtitle: String
    private let action: AfterCaptureAction

    init(action: AfterCaptureAction, type: AfterCaptureType) {
        _isOn = AppStorage(wrappedValue: action.defaultValue, action.storageKey(for: type))
        _uploadIsOn = AppStorage(
            wrappedValue: AfterCaptureAction.upload.defaultValue,
            AfterCaptureAction.upload.storageKey(for: type)
        )
        self.action = action
        title = action.title
        subtitle = action.subtitle
    }

    private var isDisabled: Bool {
        switch action {
        case .upload:
            !isOn && !CloudCredentialStore.shared.isConfigured
        case .copyShareLink:
            !uploadIsOn
        default:
            false
        }
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsControlLabel(title, detail: subtitle)
        }
        .disabled(isDisabled)

        if action == .upload && !CloudCredentialStore.shared.isConfigured {
            HStack {
                Text(isOn ? "Automatic uploads are paused until Cloud is set up."
                          : "Set up Cloud to enable automatic uploads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set Up Cloud…") { SettingsWindowController.show(tab: .cloud) }
                    .controlSize(.small)
            }
        }
    }
}
