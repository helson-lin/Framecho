//
//  SettingsAboutPane.swift
//  Framecho
//

import AppKit
import SwiftUI

struct SettingsAboutPane: View {
    @ObservedObject private var updaterManager = UpdaterManager.shared

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        switch (version, build) {
        case let (version?, build?):
            return String(localized: "Version \(version) (\(build))")
        case let (version?, nil):
            return String(localized: "Version \(version)")
        default:
            return String(localized: "Version \(build ?? "—")")
        }
    }

    private var lastCheckedText: String {
        guard let date = updaterManager.lastUpdateCheckDate else {
            return String(localized: "Not checked yet")
        }
        return String(localized: "Last checked \(date.formatted(.relative(presentation: .named)))")
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Framecho")
                            .font(.largeTitle.bold())

                        Text(versionText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("A native, open-source screenshot and recording tool for macOS.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if UpdaterManager.isEnabled {
                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updaterManager.automaticallyChecksForUpdates },
                        set: { updaterManager.automaticallyChecksForUpdates = $0 }
                    ))

                    LabeledContent {
                        Button("Check Now") {
                            updaterManager.checkForUpdates()
                        }
                        .disabled(!updaterManager.canCheckForUpdates)
                    } label: {
                        SettingsControlLabel(String(localized: "Check for updates"), detail: lastCheckedText)
                    }
                }
            }

            Section("Project") {
                LabeledContent {
                    Link("View on GitHub", destination: URL(string: "https://github.com/helson-lin/Framecho")!)
                } label: {
                    SettingsControlLabel(String(localized: "Source code"), detail: "github.com/helson-lin/Framecho")
                }

                LabeledContent {
                    Link(destination: URL(string: "https://github.com/fayazara/screendrop")!) {
                        Text(verbatim: "Screendrop")
                    }
                } label: {
                    SettingsControlLabel(String(localized: "Credits"), detail: String(localized: "Based on Screendrop by Fayaz Ahmed"))
                }
            }
        }
        .settingsFormStyle()
    }
}
