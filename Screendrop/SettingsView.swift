//
//  SettingsView.swift
//  Screendrop
//

import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case screenshots
    case video
    case overlay
    case cloud
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .shortcuts: String(localized: "Keyboard Shortcuts")
        case .screenshots: String(localized: "Screenshots")
        case .video: String(localized: "Screen Recordings")
        case .overlay: String(localized: "Overlay")
        case .cloud: String(localized: "Cloud")
        case .about: String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .screenshots: "photo.on.rectangle.angled"
        case .video: "video"
        case .overlay: "square.on.square"
        case .cloud: "icloud.and.arrow.up"
        case .about: "info.circle"
        }
    }

    /// One line under the pane title saying what the pane controls.
    var summary: String {
        switch self {
        case .general: String(localized: "Where captures are saved, what Framecho can access, and how it starts.")
        case .shortcuts: String(localized: "Click a shortcut, then press the new keys. Each needs at least one modifier key.")
        case .screenshots: String(localized: "How screenshots are taken and saved, and what happens after each one.")
        case .video: String(localized: "What happens after a recording and after its export.")
        case .overlay: String(localized: "Where the floating preview appears, how large it is, and what it offers.")
        case .cloud: String(localized: "Upload captures to your own Cloudflare Worker and share their links.")
        case .about: String(localized: "Version, updates and project information.")
        }
    }

    /// The glyph color inside the sidebar's icon tile.
    var tint: Color {
        switch self {
        case .general, .about: .gray
        case .shortcuts: .indigo
        case .screenshots: .blue
        case .video: .red
        case .overlay: .teal
        case .cloud: .cyan
        }
    }

    /// Sidebar order, split into the groups the sidebar spaces apart.
    static let sidebarGroups: [[SettingsTab]] = [
        [.general, .shortcuts],
        [.screenshots, .video, .overlay],
        [.cloud],
        [.about],
    ]
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var selectedTab: SettingsTab? = .general

    private init() {}
}

// MARK: - Main Settings View

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared

    private var activeTab: SettingsTab {
        navigation.selectedTab ?? .general
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebarView(selectedTab: $navigation.selectedTab)
                .navigationSplitViewColumnWidth(min: 210, ideal: 210, max: 210)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(tab: activeTab)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 540)
    }
}

// MARK: - Sidebar

private struct SettingsSidebarView: View {
    @Binding var selectedTab: SettingsTab?

    var body: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsTab.sidebarGroups, id: \.self) { group in
                Section {
                    ForEach(group) { tab in
                        SettingsSidebarRow(tab: tab)
                            .tag(tab)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectSoftIfAvailable()
        .navigationTitle("Settings")
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            SettingsIconTile(systemImage: tab.systemImage, tint: tab.tint)
        }
        .padding(.vertical, 3)
    }
}

/// A neutral rounded tile with a tinted glyph, so the sidebar reads by
/// shape and color without six saturated blocks competing for attention.
private struct SettingsIconTile: View {
    let systemImage: String
    let tint: Color

    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(.background, in: shape)
            .overlay { shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

// MARK: - Detail

private struct SettingsDetailView: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralSettingsPane()
            case .shortcuts:
                ShortcutsSettingsPane()
            case .screenshots:
                ScreenshotsSettingsPane()
            case .video:
                VideoSettingsPane()
            case .overlay:
                OverlaySettingsPane()
            case .cloud:
                CloudSettingsPane()
            case .about:
                SettingsAboutPane()
            }
        }
        .safeAreaBarIfAvailable(edge: .top) {
            SettingsPaneHeader(tab: tab)
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The pane's title and summary, centered above its form. The window's own
/// title stays hidden so the name isn't shown twice.
private struct SettingsPaneHeader: View {
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 4) {
            Text(tab.title)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(tab.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

// MARK: - Helpers

extension View {
    /// The grouped form every settings pane uses, with switches for toggles.
    func settingsFormStyle() -> some View {
        formStyle(.grouped)
            .toggleStyle(.switch)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
    }
}

/// The same label rhythm across settings panes, with descriptions allowed to
/// wrap at the window's minimum width instead of being vertically truncated.
struct SettingsControlLabel: View {
    let title: String
    let detail: String

    init(_ title: LocalizedStringResource, detail: LocalizedStringResource) {
        self.init(String(localized: title), detail: String(localized: detail))
    }

    @_disfavoredOverload
    init<Title: StringProtocol, Detail: StringProtocol>(_ title: Title, detail: Detail) {
        self.title = String(title)
        self.detail = String(detail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension URL {
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
