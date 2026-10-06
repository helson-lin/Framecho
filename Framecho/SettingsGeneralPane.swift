//
//  SettingsGeneralPane.swift
//  Framecho
//

import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage(FramechoPreferences.exportDirectoryPathKey) private var exportDirectoryPath = ""
    @AppStorage(FramechoPreferences.saveButtonUsesFolderKey) private var saveButtonUsesFolder = false
    @AppStorage(FramechoPreferences.playSoundsKey) private var playSounds = true
    @AppStorage(FramechoPreferences.showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(FramechoPreferences.includeAppWindowsInCapturesKey)
    private var includeAppWindowsInCaptures = false
    @State private var launchAtLoginStatus = LaunchAtLoginController.status
    @State private var launchAtLoginError: String?
    @State private var revealError: String?
    @State private var permissionCenter = AppPermissionCenter.shared

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginStatus.isEnabled },
            set: updateLaunchAtLogin
        )
    }

    private var saveButtonUsesFolderBinding: Binding<Bool> {
        Binding(
            get: { _ = saveButtonUsesFolder; return FramechoPreferences.saveButtonUsesConfiguredFolder },
            set: { saveButtonUsesFolder = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Save Location") {
                LabeledContent {
                    HStack(spacing: 6) {
                        ExportFolderPicker(
                            exportDirectoryPath: $exportDirectoryPath,
                            chooseOther: chooseExportDirectory
                        )

                        Button {
                            revealExportDirectory()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                    }
                } label: {
                    SettingsControlLabel(
                        String(localized: "Export folder"),
                        detail: FramechoPreferences.exportDirectory.abbreviatedPath
                    )
                }

                if let revealError {
                    SettingsIssueText(revealError)
                }

                Toggle(isOn: saveButtonUsesFolderBinding) {
                    SettingsControlLabel(
                        "Save without choosing a location",
                        detail: "When you click Save, write straight to the export folder instead of asking where to put it."
                    )
                }
            }

            Section {
                ForEach(AppPermission.allCases) { permission in
                    AppPermissionRow(permission: permission)
                }
                if permissionCenter.isRelaunchSuggested {
                    AppPermissionRelaunchNotice()
                }
            } header: {
                Text("Permissions")
            } footer: {
                Button("Show Setup Guide…") {
                    OnboardingWindowController.show(page: .welcome, reason: .manual)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            .onAppear { permissionCenter.beginObserving() }
            .onDisappear { permissionCenter.endObserving() }

            Section("System") {
                Toggle(isOn: launchAtLoginBinding) {
                    SettingsControlLabel(
                        "Launch at login",
                        detail: "Start Framecho automatically when you sign in."
                    )
                }

                if let launchAtLoginError {
                    SettingsIssueText(launchAtLoginError)
                } else if launchAtLoginStatus.requiresApproval {
                    HStack(spacing: 10) {
                        SettingsIssueText(String(localized: "Approve Framecho in System Settings → General → Login Items."))
                        Spacer(minLength: 8)
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }

                Toggle(isOn: $playSounds) {
                    SettingsControlLabel(
                        "Play sounds",
                        detail: "Play the camera shutter sound when a screenshot is taken."
                    )
                }

                Toggle(isOn: $showMenuBarIcon) {
                    SettingsControlLabel(
                        "Show menu bar icon",
                        detail: "When hidden, reopen Framecho to get back to Settings."
                    )
                }

                Toggle(isOn: $includeAppWindowsInCaptures) {
                    SettingsControlLabel(
                        "Include Framecho windows in captures",
                        detail: "Show preview cards, recording controls, Settings, and other Framecho windows in screenshots and screen recordings."
                    )
                }
            }
        }
        .settingsFormStyle()
        .onAppear {
            refreshLaunchAtLoginStatus()
        }
        .onChange(of: includeAppWindowsInCaptures) { _, _ in
            PreviewWindowCaptureExclusion.shared.refreshRegisteredWindows()
        }
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Save Location")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FramechoPreferences.exportDirectory

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        exportDirectoryPath = url.path
    }

    private func revealExportDirectory() {
        let directory = FramechoPreferences.exportDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            revealError = nil
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            revealError = String(localized: "Could not open the export folder: \(error.localizedDescription)")
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = LaunchAtLoginController.status
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        do {
            launchAtLoginError = nil
            try LaunchAtLoginController.setEnabled(isEnabled)
        } catch {
            launchAtLoginError = String(localized: "Could not update Launch at Login: \(error.localizedDescription)")
        }

        refreshLaunchAtLoginStatus()
    }
}

/// The export folder as a pop-up: the default, the usual user folders, the
/// current custom folder, and Other… to pick any folder.
private struct ExportFolderPicker: View {
    @Binding var exportDirectoryPath: String
    let chooseOther: () -> Void

    private struct Choice: Identifiable {
        let url: URL
        let title: String
        var id: String { url.standardizedFileURL.path }
    }

    private var current: URL { FramechoPreferences.exportDirectory }

    private var choices: [Choice] {
        let fileManager = FileManager.default
        let defaultURL = FramechoPreferences.defaultExportDirectory
        var choices = [Choice(
            url: defaultURL,
            title: String(localized: "\(fileManager.displayName(atPath: defaultURL.path)) (Default)")
        )]
        for directory in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            guard let url = fileManager.urls(for: directory, in: .userDomainMask).first else { continue }
            choices.append(Choice(url: url, title: fileManager.displayName(atPath: url.path)))
        }
        if !choices.contains(where: { $0.id == current.standardizedFileURL.path }) {
            choices.append(Choice(url: current, title: fileManager.displayName(atPath: current.path)))
        }
        return choices
    }

    private static let otherID = "other"

    var body: some View {
        Picker("Export folder", selection: Binding(
            get: { current.standardizedFileURL.path },
            set: { id in
                if id == Self.otherID {
                    // Let the menu close before the open panel runs modally.
                    DispatchQueue.main.async(execute: chooseOther)
                } else if let choice = choices.first(where: { $0.id == id }) {
                    select(choice)
                }
            }
        )) {
            ForEach(choices) { choice in
                Label(choice.title, systemImage: "folder").tag(choice.id)
            }
            Divider()
            Text("Other…").tag(Self.otherID)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help(current.path)
    }

    private func select(_ choice: Choice) {
        let isDefault = choice.id == FramechoPreferences.defaultExportDirectory.standardizedFileURL.path
        exportDirectoryPath = isDefault ? "" : choice.url.path
    }
}

private enum LaunchAtLoginStatus {
    case disabled
    case enabled
    case requiresApproval

    var isEnabled: Bool {
        self == .enabled
    }

    var requiresApproval: Bool {
        self == .requiresApproval
    }
}

@MainActor
private enum LaunchAtLoginController {
    static var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notRegistered, .notFound:
            .disabled
        @unknown default:
            .disabled
        }
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        let service = SMAppService.mainApp

        if isEnabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
