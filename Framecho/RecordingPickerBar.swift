//
//  RecordingPickerBar.swift
//  Framecho
//
//  The pre-record mode of the floating bar. "Record" anywhere in the app
//  brings the bar up at the bottom of the active screen; it picks the source
//  (display / window / area) and toggles the capture inputs (camera,
//  microphone, system audio) for the next recording, then hands off to
//  CaptureCoordinator - at which point the same bar morphs into the in-session
//  controls (RecordingControlPresenter). Clicks and keystrokes are always
//  logged to the session sidecar; whether they appear is decided later in
//  Studio.
//
//  The panel, the chrome and the morph live in RecordingBarPresenter.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// Retained as the entry point callers already use; the bar itself is owned
/// by RecordingBarPresenter.
@MainActor
enum RecordingPickerPresenter {
    static var shared: RecordingBarPresenter { RecordingBarPresenter.shared }
}

extension RecordingBarPresenter {
    func toggle() {
        togglePicker()
    }

    func show() {
        showPicker()
    }
}

// MARK: - Controls

struct RecordingPickerControls: View {
    @State private var sources = RecordingSourceCatalog.shared
    @State private var microphoneLevel = MicrophoneLevelMonitor.shared
    @AppStorage(FramechoPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(FramechoPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @AppStorage(FramechoPreferences.recordingSystemAudioKey) private var systemAudio = false
    @AppStorage(FramechoPreferences.recordingStartDelaySecondsKey) private var startDelaySeconds = 0
    @AppStorage(FramechoPreferences.recordingTeleprompterEnabledKey) private var teleprompterEnabled = false

    private static let timerOptions = [0, 1, 3, 5]

    @State private var selectedSource: ScreenRecordingSource?
    @State private var selectedAreaDimensions: RecordingPixelDimensions?
    @State private var isRecordHovered = false
    @State private var recordFrame: CGRect = .zero
    @Environment(BarTooltipModel.self) private var tooltip: BarTooltipModel?

    var body: some View {
        GlassEffectContainer(spacing: BarMetrics.pickerSectionGap) {
            VStack(spacing: BarMetrics.pickerSectionGap) {
                configuration
                recordActions
            }
        }
        .frame(width: BarMetrics.pickerWidth)
        .task { await sources.refresh() }
        .onChange(of: sources.isLoading) { _, isLoading in
            if !isLoading, case .area(let display, let rect) = currentSource?.kind {
                selectedAreaDimensions = ScreenRecordingManager.areaDimensions(display: display, rect: rect)
            }
        }
    }

    private var canSelectSource: Bool {
        !sources.isLoading && !sources.displays.isEmpty && !CaptureCountdownPresenter.shared.isRunning
    }

    private var currentSource: ScreenRecordingSource? {
        guard let selectedSource else {
            return targetDisplay.map { ScreenRecordingSource(kind: .fullscreen($0)) }
        }
        switch selectedSource.kind {
        case .fullscreen(let display):
            return sources.displays.first { $0.displayID == display.displayID }
                .map { ScreenRecordingSource(kind: .fullscreen($0)) }
        case .window(let window):
            return sources.windows.first { $0.windowID == window.windowID }
                .map { ScreenRecordingSource(kind: .window($0)) }
        case .area(let display, let rect):
            return sources.displays.first { $0.displayID == display.displayID }
                .map { ScreenRecordingSource(kind: .area(display: $0, rect: rect)) }
        }
    }

    private var targetDisplay: SCDisplay? {
        let displayID = selectedSource?.displayID
            ?? ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        return sources.displays.first { $0.displayID == displayID } ?? sources.displays.first
    }

    private var sourceMode: ScreenRecordingSourceMode {
        switch selectedSource?.kind {
        case .window: .window
        case .area: .area
        default: .fullscreen
        }
    }

    private var dimensions: RecordingPixelDimensions? {
        switch currentSource?.kind {
        case .fullscreen(let display): sources.displaySizes[display.displayID]
        case .window(let window): sources.windowSizes[window.windowID]
        case .area: selectedAreaDimensions
        case nil: nil
        }
    }

    private var configuration: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pickerCell(sourceMenu, height: BarMetrics.pickerHeaderHeight)
                resolutionReadout
                    .frame(width: BarMetrics.pickerCellWidth * 3, height: BarMetrics.pickerHeaderHeight)
                    .overlay(alignment: .trailing) { cellDivider }
                BarActionButton(
                    id: .area,
                    title: String(localized: "Drag to select a region"),
                    systemImage: "crop",
                    accessibility: String(localized: "Area - drag to select the region to record")
                ) { selectArea() }
                .disabled(!canSelectSource)
                .frame(width: BarMetrics.pickerCellWidth, height: BarMetrics.pickerHeaderHeight)
            }
            Rectangle().fill(BarMetrics.stroke).frame(height: 1)
            inputRow
        }
        .environment(\.recordingBarControlLayout, .grid)
        .clipShape(surfaceShape)
        .glassEffect(.regular, in: surfaceShape)
        .overlay { surfaceShape.strokeBorder(BarMetrics.edge, lineWidth: 0.5) }
    }

    private var inputRow: some View {
        HStack(spacing: 0) {
            pickerCell(microphonePicker)
            pickerCell(inputToggle(
                id: .systemAudio,
                title: systemAudio ? String(localized: "System audio on") : String(localized: "System audio off"),
                isOn: systemAudio,
                systemImage: "speaker.wave.2",
                accessibility: systemAudio
                    ? String(localized: "System audio on - click to stop capturing what you hear")
                    : String(localized: "System audio off - click to capture what you hear")
            ) { systemAudio.toggle() })
            pickerCell(inputToggle(
                id: .camera,
                title: cameraID.isEmpty ? String(localized: "Camera off") : String(localized: "Camera on"),
                isOn: !cameraID.isEmpty,
                systemImage: "video",
                accessibility: cameraAccessibilityLabel
            ) { toggleCamera() }.contextMenu { cameraDeviceMenu })
            pickerCell(inputToggle(
                id: .teleprompter,
                title: teleprompterEnabled ? String(localized: "Teleprompter on") : String(localized: "Teleprompter off"),
                isOn: teleprompterEnabled,
                systemImage: "text.pad.header",
                accessibility: teleprompterEnabled
                    ? String(localized: "Teleprompter on - click to edit the script")
                    : String(localized: "Teleprompter off - click to write a script")
            ) { TeleprompterComposerPresenter.shared.toggle() })
            pickerCell(timerMenu, showsDivider: false)
        }
    }

    private var resolutionReadout: some View {
        HStack(spacing: 4) {
            dimensionValue(dimensions.map { String($0.width) } ?? "—", title: "Recording width")
            Text("×").font(.system(size: 12, weight: .semibold))
            dimensionValue(dimensions.map { String($0.height) } ?? "—", title: "Recording height")
            BarActionButton(
                id: .display,
                title: String(localized: "Use full screen"),
                systemImage: "arrow.up.left.and.arrow.down.right"
            ) {
                guard let display = targetDisplay else { return }
                selectedSource = ScreenRecordingSource(kind: .fullscreen(display))
                selectedAreaDimensions = nil
            }
            .environment(\.recordingBarControlLayout, .inline)
            .disabled(!canSelectSource)
        }
        .foregroundStyle(BarMetrics.activeTint)
    }

    private func dimensionValue(_ value: String, title: LocalizedStringKey) -> some View {
        Text(value)
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 50, height: 28)
            .background(BarMetrics.hoverFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .help("Recording resolution")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(value)
    }

    private var recordActions: some View {
        HStack(spacing: 0) {
            Button {
                tooltip?.dismiss()
                beginRecording()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "video.fill").font(.system(size: 15))
                    Text("Record Video").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "return")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BarMetrics.inactiveTint)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(BarMetrics.activeTint)
                .padding(.horizontal, 14)
                .frame(height: BarMetrics.pickerActionHeight)
                .contentShape(Rectangle())
                .background(BarMetrics.hoverFill.opacity(isRecordHovered ? 1 : 0))
            }
            .buttonStyle(BarButtonStyle())
            .keyboardShortcut(.return, modifiers: [])
            .help("Start recording the selected source (Return)")
            .opacity(canSelectSource && currentSource != nil ? 1 : 0.35)
            .disabled(!canSelectSource || currentSource == nil)
            .pointerStyle(canSelectSource && currentSource != nil ? .link : nil)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BarCoordinateSpace.bar)) } action: {
                recordFrame = $0
            }
            .background {
                BarControlHover(isEnabled: canSelectSource && currentSource != nil) { isHovering in
                    isRecordHovered = isHovering
                    if isHovering {
                        tooltip?.hover(id: .record, text: String(localized: "Record Video"), frame: recordFrame)
                    } else {
                        tooltip?.endHover(id: .record)
                    }
                }
            }
            .onDisappear { tooltip?.endHover(id: .record) }
            Rectangle().fill(BarMetrics.stroke).frame(width: 1, height: 24)
            BarActionButton(
                id: .close,
                title: String(localized: "Close"),
                systemImage: "xmark",
                accessibility: String(localized: "Close the recorder - Esc")
            ) { dismissPicker() }
            .frame(width: BarMetrics.pickerActionHeight, height: BarMetrics.pickerActionHeight)
        }
        .clipShape(surfaceShape)
        .glassEffect(.regular, in: surfaceShape)
        .overlay { surfaceShape.strokeBorder(BarMetrics.edge, lineWidth: 0.5) }
    }

    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BarMetrics.pickerCornerRadius, style: .continuous)
    }

    private var cellDivider: some View {
        Rectangle().fill(BarMetrics.stroke).frame(width: 1)
    }

    private func pickerCell<Content: View>(
        _ content: Content,
        height: CGFloat = BarMetrics.pickerRowHeight,
        showsDivider: Bool = true
    ) -> some View {
        content
            .frame(width: BarMetrics.pickerCellWidth, height: height)
            .overlay(alignment: .trailing) { if showsDivider { cellDivider } }
    }

    // MARK: Sources

    private var sourceMenu: some View {
        Menu {
            if let errorMessage = sources.errorMessage {
                Text("Could not load windows: \(errorMessage)")
                if !CGPreflightScreenCaptureAccess() {
                    Button("Allow Screen Recording…") {
                        OnboardingWindowController.show(page: .permissions, reason: .screenRecordingNeeded)
                    }
                }
            }
            Section("Display") {
                ForEach(Array(sources.displays.enumerated()), id: \.element.displayID) { index, display in
                    Button {
                        selectedSource = ScreenRecordingSource(kind: .fullscreen(display))
                        selectedAreaDimensions = nil
                    } label: {
                        menuSelectionLabel(RecordingSourceCatalog.displayTitle(display, index: index), isSelected: isSelected(display))
                    }
                }
            }
            Section("Window") {
                if sources.windows.isEmpty { Text("No app windows found") }
                ForEach(sources.windows, id: \.windowID) { window in
                    Button {
                        selectedSource = ScreenRecordingSource(kind: .window(window))
                        selectedAreaDimensions = nil
                    } label: {
                        menuSelectionLabel(windowMenuTitle(window), isSelected: isSelected(window))
                    }
                }
            }
            Divider()
            Button("Refresh Windows") { Task { await sources.refresh() } }
        } label: {
            BarActionLabel(
                id: .source,
                title: String(localized: "Choose recording source"),
                systemImage: sources.errorMessage == nil ? "slider.horizontal.3" : "exclamationmark.triangle",
                subtitle: sourceMode.title
            )
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .help("Choose a screen or window before recording")
        .accessibilityLabel("Choose recording source")
        .accessibilityValue(sourceMode.title)
        .disabled(sources.isLoading || CaptureCountdownPresenter.shared.isRunning)
    }

    private func isSelected(_ display: SCDisplay) -> Bool {
        guard case .fullscreen(let selected) = currentSource?.kind else { return false }
        return selected.displayID == display.displayID
    }

    private func isSelected(_ window: SCWindow) -> Bool {
        guard case .window(let selected) = currentSource?.kind else { return false }
        return selected.windowID == window.windowID
    }

    private func windowMenuTitle(_ window: SCWindow) -> String {
        let title = RecordingSourceCatalog.windowTitle(window)
        guard let dimensions = sources.windowSizes[window.windowID] else { return title }
        return "\(title)  ·  \(dimensions.label)"
    }

    private func selectArea() {
        guard let display = targetDisplay else { return }
        RecordingBarPresenter.shared.hide()
        RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
            if let rect {
                selectedSource = ScreenRecordingSource(kind: .area(display: display, rect: rect))
                selectedAreaDimensions = ScreenRecordingManager.areaDimensions(display: display, rect: rect)
            }
            RecordingBarPresenter.shared.showPicker()
        }
    }

    private func beginRecording() {
        guard canSelectSource, let source = currentSource else { return }
        startRecording {
            switch source.kind {
            case .fullscreen(let display): CaptureCoordinator.shared.recordFullscreen(display)
            case .window(let window): CaptureCoordinator.shared.recordWindow(window)
            case .area(let display, let rect): CaptureCoordinator.shared.recordArea(display, rect: rect)
            }
        }
    }

    /// Leaves the bar on screen: it stays as the picker through any start
    /// delay, then morphs into the session controls the moment capture
    /// actually begins. The warm camera preview (if any) is left running so it
    /// flows straight into the recording instead of restarting and refading.
    private func startRecording(_ start: () -> Void) {
        TeleprompterComposerPresenter.shared.hide()
        start()
    }

    /// Backs out of the picker without recording: stop any warm camera
    /// preview so it doesn't keep running in the background.
    private func dismissPicker() {
        RecordingBarPresenter.shared.hide()
        Task { await CameraRecordingManager.shared.stopPreview() }
    }

    // MARK: Input toggles

    private func toggleCamera() {
        if cameraID.isEmpty {
            selectCamera(RecordingDeviceCatalog.cameras().first?.uniqueID)
        } else {
            cameraID = ""
            Task { await CameraRecordingManager.shared.stopPreview() }
        }
    }

    private var cameraAccessibilityLabel: String {
        guard !cameraID.isEmpty else {
            return String(localized: "Camera off - click to record your camera, right-click to pick one")
        }
        guard let camera = RecordingDeviceCatalog.cameras().first(where: { $0.uniqueID == cameraID }) else {
            return String(localized: "Camera unavailable - right-click to choose another camera")
        }
        return String(localized: "Camera on - \(camera.localizedName), right-click to switch")
    }

    /// The pill only has room for the state, so a microphone that's
    /// selected but not working is worth calling out there - it's the case
    /// where the icon alone would be misleading.
    private var microphoneTooltip: String {
        guard !microphoneID.isEmpty else { return String(localized: "Microphone off") }
        guard RecordingDeviceCatalog.microphone(withID: microphoneID) != nil else {
            return String(localized: "Microphone unavailable")
        }
        switch microphoneLevel.status {
        case .silent: return String(localized: "Microphone muted - no sound")
        case .unavailable: return String(localized: "Microphone not responding")
        case .idle, .starting, .live: return String(localized: "Microphone on")
        }
    }

    private var microphoneAccessibilityLabel: String {
        guard !microphoneID.isEmpty else {
            return String(localized: "Microphone off - click to choose an input")
        }
        guard let microphone = RecordingDeviceCatalog.microphone(withID: microphoneID) else {
            return String(localized: "Microphone unavailable - choose another input")
        }
        switch microphoneLevel.status {
        case .silent:
            return String(localized: "Microphone muted - \(microphone.localizedName) is sending no sound")
        case .unavailable:
            return String(localized: "Microphone not responding - \(microphone.localizedName), choose another input")
        case .idle, .starting, .live:
            return String(localized: "Microphone on - \(microphone.localizedName)")
        }
    }

    private var isMicrophoneFaulty: Bool {
        guard !microphoneID.isEmpty else { return false }
        return RecordingDeviceCatalog.microphone(withID: microphoneID) == nil
            || microphoneLevel.status == .silent
            || microphoneLevel.status == .unavailable
    }

    /// The device the meter should be listening to: the selected one, and
    /// only while the picker is on screen.
    private var meteredMicrophoneID: String? {
        guard RecordingBarPresenter.shared.isPickerVisible, !microphoneID.isEmpty else { return nil }
        return microphoneID
    }

    @ViewBuilder
    private var cameraDeviceMenu: some View {
        ForEach(RecordingDeviceCatalog.cameras(), id: \.uniqueID) { device in
            Toggle(isOn: Binding(
                get: { cameraID == device.uniqueID },
                set: { selected in
                    if selected {
                        selectCamera(device.uniqueID)
                    } else {
                        cameraID = ""
                        Task { await CameraRecordingManager.shared.stopPreview() }
                    }
                }
            )) {
                Text(device.localizedName)
            }
        }
    }

    private var microphonePicker: some View {
        Menu {
            Button {
                microphoneID = ""
            } label: {
                menuSelectionLabel(String(localized: "Off"), isSelected: microphoneID.isEmpty)
            }

            Divider()

            ForEach(RecordingDeviceCatalog.microphones(), id: \.uniqueID) { device in
                Button {
                    selectMicrophone(device.uniqueID)
                } label: {
                    menuSelectionLabel(
                        device.localizedName,
                        isSelected: microphoneID == device.uniqueID
                    )
                }
            }
        } label: {
            BarActionLabel(
                id: .microphone,
                title: microphoneTooltip,
                systemImage: "mic",
                tint: microphoneID.isEmpty
                    ? BarMetrics.inactiveTint
                    : isMicrophoneFaulty ? BarMetrics.warningTint : BarMetrics.activeTint,
                isOn: !microphoneID.isEmpty,
                isWarning: isMicrophoneFaulty,
                level: microphoneLevel.status == .live ? microphoneLevel.level : nil
            )
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .help(microphoneAccessibilityLabel)
        .accessibilityLabel(microphoneAccessibilityLabel)
        .onChange(of: meteredMicrophoneID, initial: true) { _, deviceID in
            microphoneLevel.monitor(deviceID: deviceID)
        }
    }

    /// Replaces the old gear button that opened Settings: a self-contained
    /// menu for options that only matter for the next recording, starting
    /// with a start-delay timer.
    private var timerMenu: some View {
        Menu {
            ForEach(Self.timerOptions, id: \.self) { seconds in
                Button {
                    startDelaySeconds = seconds
                } label: {
                    menuSelectionLabel(timerLabel(seconds), isSelected: startDelaySeconds == seconds)
                }
            }
        } label: {
            BarActionLabel(
                id: .timer,
                title: timerTooltip,
                systemImage: "timer",
                tint: startDelaySeconds == 0 ? BarMetrics.inactiveTint : BarMetrics.activeTint,
                isOn: startDelaySeconds > 0
            )
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .help(timerAccessibilityLabel)
        .accessibilityLabel(timerAccessibilityLabel)
    }

    private func timerLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: String(localized: "None")
        case 1: String(localized: "1 second")
        default: String(localized: "\(seconds) seconds")
        }
    }

    private var timerTooltip: String {
        startDelaySeconds == 0
            ? String(localized: "Recording countdown off")
            : String(localized: "Recording countdown: \(startDelaySeconds)s")
    }

    private var timerAccessibilityLabel: String {
        startDelaySeconds == 0
            ? String(localized: "Timer off - click to add a countdown before recording starts")
            : String(localized: "Timer: \(timerLabel(startDelaySeconds)) before recording starts")
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func selectCamera(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            let authorized = await RecordingInputAuthorization.ensureAccess(for: .camera)
            cameraID = authorized ? deviceID : ""
            if authorized {
                await warmCameraPreview()
            }
        }
    }

    /// Starts the camera session (and its floating preview) ahead of "Start
    /// Recording", so its exposure/white-balance ramp - the fade-in macOS
    /// shows whenever a capture session starts cold - finishes before
    /// anything is actually being recorded.
    private func warmCameraPreview() async {
        guard !cameraID.isEmpty else { return }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        await CameraRecordingManager.shared.startPreview(deviceID: cameraID, displayID: displayID)
    }

    private func selectMicrophone(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            microphoneID = await RecordingInputAuthorization.ensureAccess(for: .microphone) ? deviceID : ""
        }
    }

    // MARK: Pieces

    /// All options use the same glyph in both states: enabled gets a check,
    /// disabled is dimmed, and the pointer target never changes size.
    private func inputToggle(
        id: BarTooltipID,
        title: String,
        isOn: Bool,
        systemImage: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        BarActionButton(
            id: id,
            title: title,
            systemImage: systemImage,
            tint: isOn ? BarMetrics.activeTint : BarMetrics.inactiveTint,
            isOn: isOn,
            accessibility: accessibility,
            action: action
        )
    }
}
