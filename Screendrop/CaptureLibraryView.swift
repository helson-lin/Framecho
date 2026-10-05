import AppKit
import SwiftUI

struct CaptureLibraryView: View {
    @State private var model = CaptureLibraryModel.shared
    @State private var history = ScreenshotHistoryStore.shared
    @State private var projects = RecordingProjectStore.shared
    @State private var libraryWindow: NSWindow?
    @AppStorage("captureLibrary.layout") private var layout: CaptureLibraryLayout = .grid
    @AppStorage("captureLibrary.inspectorVisible") private var inspectorVisible = true
    @AppStorage("captureLibrary.sort") private var savedSort: CaptureLibrarySort = .newest
    @AppStorage("captureLibrary.thumbnailScale") private var thumbnailScale = 0.3

    private var activeFilter: CaptureLibraryFilter { model.filter ?? .all }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $model.filter) {
                Section("Library") {
                    ForEach(CaptureLibraryFilter.kinds) { filter in
                        sidebarRow(filter)
                    }
                }
                Section("Smart Groups") {
                    ForEach(CaptureLibraryFilter.smartGroups) { filter in
                        sidebarRow(filter)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollEdgeEffectSoftIfAvailable()
            .navigationSplitViewColumnWidth(min: 210, ideal: 210, max: 240)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                Button {
                    SettingsWindowController.show(tab: .general)
                } label: {
                    Label {
                        Text("Settings")
                    } icon: {
                        SidebarIconTile(systemImage: "gearshape", tint: .gray)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        } detail: {
            VStack(spacing: 0) {
                browser
                Divider()
                statusBar
            }
            .navigationTitle(activeFilter.title)
            .navigationSubtitle(captureCountText)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search captures")
        .inspector(isPresented: $inspectorVisible) {
            CaptureLibraryInspector(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar { toolbar }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear {
            AppActivationPolicy.enter()
            model.sortOrder = savedSort
            model.refresh()
        }
        .onDisappear { AppActivationPolicy.leave() }
        .onWindowChange { window in
            libraryWindow = window
            PreviewWindowCaptureExclusion.shared.register(window: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === libraryWindow { model.refresh() }
        }
        .onChange(of: history.items) { _, _ in model.refresh() }
        .onChange(of: projects.projects) { _, _ in model.refresh() }
        .onChange(of: model.sortOrder) { _, value in savedSort = value }
        .alert("Rename Capture", isPresented: Binding(
            get: { model.renamingItem != nil },
            set: { if !$0 { model.renamingItem = nil } }
        )) {
            TextField("Name", text: $model.renameText)
            Button("Rename") { model.rename() }
                .disabled(model.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { model.renamingItem = nil }
        }
        .alert(trashAlertTitle, isPresented: Binding(
            get: { !model.pendingTrash.isEmpty },
            set: { if !$0 { model.pendingTrash = [] } }
        )) {
            Button("Move to Trash", role: .destructive) { model.movePendingItemsToTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = [] }
        } message: {
            Text("The local files and their edits will move to Trash. Exported copies and cloud links will remain available.")
        }
        .alert("The Library action could not be completed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var browser: some View {
        if model.items.isEmpty && model.isLoading {
            ProgressView("Loading Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleItems.isEmpty {
            if !model.searchText.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No matches for “\(model.searchText)” in \(activeFilter.title).")
                } actions: {
                    Button("Clear Search") { model.searchText = "" }
                }
            } else {
                ContentUnavailableView {
                    Label(emptyLibraryTitle, systemImage: activeFilter.symbol)
                } description: {
                    Text(emptyLibraryDescription)
                } actions: {
                    emptyLibraryActions
                }
            }
        } else {
            VStack(spacing: 0) {
                if layout == .list {
                    LibraryListHeader(sortOrder: $model.sortOrder)
                }
                CaptureLibraryCollection(sections: model.sections, revision: model.contentRevision, layout: layout,
                    thumbnailScale: thumbnailScale,
                    selection: $model.selection, isBusy: model.isBusy, onAction: model.perform)
            }
        }
    }

    private func sidebarRow(_ filter: CaptureLibraryFilter) -> some View {
        Label {
            HStack {
                Text(filter.title)
                Spacer()
                Text(model.count(for: filter), format: .number)
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
            }
        } icon: {
            SidebarIconTile(systemImage: filter.symbol, tint: filter.tint)
        }
        .padding(.vertical, 3)
        .tag(filter)
    }

    /// Start a capture from the empty Library, showing each action's shortcut
    /// so it can be used next time without opening the window.
    @ViewBuilder private var emptyLibraryActions: some View {
        let showsCapture = activeFilter == .all || activeFilter == .screenshots
        let showsRecording = activeFilter == .all || activeFilter == .recordings
        if showsCapture || showsRecording {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    if showsCapture {
                        Button { CaptureCoordinator.shared.captureArea() } label: {
                            shortcutLabel("Capture Area", action: .area)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if showsRecording {
                        Button { RecordingPickerPresenter.shared.show() } label: {
                            shortcutLabel("Record Screen", action: .screenRecording)
                        }
                        .disabled(ScreenRecordingManager.shared.isActive)
                    }
                }
                .controlSize(.large)

                Button("Change Shortcuts…") { SettingsWindowController.show(tab: .shortcuts) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }

    private func shortcutLabel(_ title: LocalizedStringResource, action: CaptureHotkeyAction) -> some View {
        HStack(spacing: 8) {
            Text(title)
            HotkeyShortcutDisplay(shortcut: CaptureHotkeyPreferences.shortcut(for: action))
        }
    }

    private var captureCountText: String {
        let count = model.visibleItems.count
        return count == 1 ? String(localized: "1 capture") : String(localized: "\(count) captures")
    }

    private var trashAlertTitle: String {
        let count = model.pendingTrash.count
        return count == 1
            ? String(localized: "Move capture to Trash?")
            : String(localized: "Move \(count) captures to Trash?")
    }

    private var emptyLibraryTitle: String {
        switch activeFilter {
        case .all: String(localized: "No Captures")
        case .screenshots: String(localized: "No Screenshots")
        case .recordings: String(localized: "No Recordings")
        case .shared: String(localized: "No Shared Captures")
        case .drafts: String(localized: "No Drafts")
        }
    }

    private var emptyLibraryDescription: String {
        switch activeFilter {
        case .all: String(localized: "Screenshots and recordings you capture will appear here.")
        case .screenshots: String(localized: "Take a screenshot to start your screenshot library.")
        case .recordings: String(localized: "Record your screen to start your recording library.")
        case .shared: String(localized: "Captures you upload to the cloud appear here.")
        case .drafts: String(localized: "Recordings with unsaved edits appear here.")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let title = model.operationTitle {
                ProgressView().controlSize(.mini)
                Text(title)
            } else {
                Text(captureCountText)
                if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.mini).help("Refreshing Library") }
            if layout == .grid && !model.visibleItems.isEmpty {
                thumbnailSizeSlider
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private var thumbnailSizeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3")
                .imageScale(.small)
                .accessibilityHidden(true)
            Slider(value: $thumbnailScale, in: 0.0...1.0)
                .controlSize(.mini)
                .frame(width: 96)
                .accessibilityLabel(Text("Thumbnail size"))
            Image(systemName: "square.grid.2x2")
                .accessibilityHidden(true)
        }
        .help(Text("Thumbnail size"))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Capture Fullscreen", systemImage: "macwindow") { CaptureCoordinator.shared.captureFullscreen() }
                Button("Capture Window", systemImage: "macwindow.on.rectangle") { CaptureCoordinator.shared.captureWindow() }
                Button("Capture Area", systemImage: "rectangle.dashed") { CaptureCoordinator.shared.captureArea() }
                Divider()
                Button("Record Screen", systemImage: "record.circle") { RecordingPickerPresenter.shared.show() }
                    .disabled(ScreenRecordingManager.shared.isActive)
            } label: { Label("New Capture", systemImage: "plus") }
            .help("New capture")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $layout) {
                Label("Grid View", systemImage: "square.grid.2x2").tag(CaptureLibraryLayout.grid).help("Grid view")
                Label("List View", systemImage: "list.bullet").tag(CaptureLibraryLayout.list).help("List view")
            }
            .labelStyle(.iconOnly)
            .pickerStyle(.segmented)
            .help("Switch between grid and list")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(CaptureLibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .help("Sort captures")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorVisible.toggle() } label: {
                Label(inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
        }
    }
}
