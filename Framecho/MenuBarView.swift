//
//  MenuBarView.swift
//  Framecho
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct MenuBarView: View {
    @State private var historyStore = ScreenshotHistoryStore.shared
    @State private var projectStore = RecordingProjectStore.shared
    @State private var hotkeyManager = HotkeyManager.shared
    @State private var recorder = ScreenRecordingManager.shared

    @State private var permissionCenter = AppPermissionCenter.shared

    // Groups follow the task rather than the capture API: what to capture,
    // recording, capture-and-process, pinning, then finding past captures.
    // Capture on Timer is left to its shortcut; updates live in Settings › About.
    var body: some View {
        Group {
            // Every capture would fail; say so before the capture items.
            if !permissionCenter.isScreenRecordingGranted {
                Button {
                    OnboardingWindowController.show(page: .permissions, reason: .screenRecordingNeeded)
                } label: {
                    Label("Allow Screen Recording…", systemImage: "exclamationmark.triangle")
                }
                Divider()
            }

            Button {
                CaptureCoordinator.shared.captureArea()
            } label: {
                Label("Capture Area", systemImage: "rectangle.dashed")
            }
            .keyboardShortcut(hotkeyManager.activeShortcuts[.area]?.keyboardShortcut)

            Button {
                CaptureCoordinator.shared.captureWindow()
            } label: {
                Label("Capture Window", systemImage: "macwindow.on.rectangle")
            }
            .keyboardShortcut(hotkeyManager.activeShortcuts[.window]?.keyboardShortcut)

            Button {
                CaptureCoordinator.shared.captureFullscreen()
            } label: {
                Label("Capture Fullscreen", systemImage: "macwindow")
            }
            .keyboardShortcut(hotkeyManager.activeShortcuts[.fullscreen]?.keyboardShortcut)

            Button {
                CaptureCoordinator.shared.captureScrolling()
            } label: {
                Label("Scrolling Capture", systemImage: "arrow.down.to.line.compact")
            }

            Divider()

            // Mirrors the recording shortcut, which stops a running recording.
            if recorder.isActive {
                Button {
                    recorder.stopRecording()
                } label: {
                    Label("Stop Screen Recording", systemImage: "stop.circle")
                }
                .keyboardShortcut(hotkeyManager.activeShortcuts[.screenRecording]?.keyboardShortcut)
                .disabled(recorder.state == .starting || recorder.state == .finishing)
            } else {
                Button {
                    RecordingPickerPresenter.shared.show()
                } label: {
                    Label("Record Screen", systemImage: "record.circle")
                }
                .keyboardShortcut(hotkeyManager.activeShortcuts[.screenRecording]?.keyboardShortcut)
            }

            Divider()

            Button {
                CaptureCoordinator.shared.captureText()
            } label: {
                Label("Capture Text", systemImage: "text.viewfinder")
            }
            .keyboardShortcut(hotkeyManager.activeShortcuts[.textCapture]?.keyboardShortcut)

            Button {
                CaptureCoordinator.shared.captureAndTranslate()
            } label: {
                Label("Capture and Translate", systemImage: "translate")
            }
            .keyboardShortcut(hotkeyManager.activeShortcuts[.translateArea]?.keyboardShortcut)

            Divider()

            Button {
                CaptureCoordinator.shared.captureAreaAndPin()
            } label: {
                Label("Capture Area and Pin", systemImage: "pin")
            }
            .keyboardShortcut(hotkeyManager.activeShortcuts[.pinArea]?.keyboardShortcut)

            Button {
                PinnedScreenshotPresenter.shared.pinLatestScreenshot()
            } label: {
                Label("Pin Latest Screenshot", systemImage: "pin.square")
            }
            .keyboardShortcut(hotkeyManager.activeShortcuts[.pinLatest]?.keyboardShortcut)
            .disabled(!historyStore.items.contains { !$0.isVideo })

            Divider()

            Button {
                CaptureLibraryModel.shared.show()
            } label: {
                Label("Open Library", systemImage: "square.grid.2x2")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Menu {
                recentMenuContent
            } label: {
                Label("Recent", systemImage: "clock.arrow.circlepath")
            }

            Divider()

            Button {
                openSettings(tab: .general)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button("Quit Framecho") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            historyStore.reload()
            projectStore.reload()
        }
    }

    /// Recent captures and recordings share one submenu. Reopening a recording
    /// is the common case after the first edit, so its recents stay one level
    /// down rather than behind the Library.
    @ViewBuilder
    private var recentMenuContent: some View {
        if historyStore.recentItems.isEmpty && projectStore.projects.isEmpty {
            Text("No captures")
        } else {
            if !historyStore.recentItems.isEmpty {
                Section("Captures") {
                    ForEach(historyStore.recentItems) { item in
                        Button(historyMenuTitle(for: item)) {
                            showHistoryPreview(item)
                        }
                    }
                }
            }

            if !projectStore.projects.isEmpty {
                Section("Recordings") {
                    ForEach(projectStore.recentProjects) { project in
                        Button(projectMenuTitle(for: project)) {
                            RecordingProjectOpener.shared.open(project.session)
                        }
                    }
                }
            }
        }

        Divider()

        Button {
            CaptureLibraryModel.shared.show(filter: .all)
        } label: {
            Label("Show All Captures…", systemImage: "rectangle.stack")
        }

        Button {
            openScreenshotsFolder()
        } label: {
            Label("Open Screenshots Folder", systemImage: "folder")
        }
    }

    private func projectMenuTitle(for project: RecordingProjectSummary) -> String {
        let name = truncatedMenuTitle(project.displayName)
        return project.hasUnsavedDraft ? String(localized: "\(name) - Unsaved") : name
    }

    private func showHistoryPreview(_ item: ScreenshotHistoryItem) {
        if item.isVideo {
            ScreenshotPreviewStack.shared.previewExistingVideo(url: item.url)
        } else {
            ScreenshotPreviewStack.shared.previewExistingImage(url: item.url)
        }
        PreviewPanelPresenter.shared.show(displayID: ActiveDisplayResolver.activeDisplayID(preferPointer: false))
    }

    private func openSettings(tab: SettingsTab) {
        SettingsWindowController.show(tab: tab)
    }

    private func openScreenshotsFolder() {
        let directory = FramechoPreferences.exportDirectory

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            showOpenScreenshotsFolderError(directory: directory, errorDescription: error.localizedDescription)
            return
        }

        if !NSWorkspace.shared.open(directory) {
            showOpenScreenshotsFolderError(directory: directory, errorDescription: nil)
        }
    }

    private func showOpenScreenshotsFolderError(directory: URL, errorDescription: String?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not open screenshots folder.")
        alert.informativeText = errorDescription ?? directory.path
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func historyMenuTitle(for item: ScreenshotHistoryItem) -> String {
        let name = item.displayName ?? item.fileName
        let limit = 30

        guard name.count > limit else {
            return name
        }

        let url = URL(fileURLWithPath: name)
        let pathExtension = url.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let baseName = url.deletingPathExtension().lastPathComponent
        let allowedBaseLength = max(8, limit - suffix.count - 3)

        return "\(baseName.prefix(allowedBaseLength))...\(suffix)"
    }

    /// Menus get unusably wide with full session names, which carry a
    /// timestamp and a uniquing suffix.
    private func truncatedMenuTitle(_ name: String) -> String {
        let limit = 34
        guard name.count > limit else { return name }
        return "\(name.prefix(limit - 1))…"
    }
}
