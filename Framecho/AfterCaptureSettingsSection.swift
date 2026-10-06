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
            ForEach(AfterCaptureAction.actions(for: type)) { action in
                AfterCaptureToggleRow(action: action, type: type)
            }
        } header: {
            Text(title)
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
