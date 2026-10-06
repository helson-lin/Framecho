//
//  RecordingStudioWindow.swift
//  Framecho
//
//  The recording studio: a Screen Studio-style editor for screen recordings.
//  Left/center is the composited live preview (background, padded rounded
//  card, zoom-follow-pointer, draggable camera bubble) over a timeline with
//  editable zoom cues; the trailing inspector uses the annotation
//  editor's design system.
//

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct RecordingStudioWindow: View {
    @Binding var url: URL?

    @State private var model: RecordingStudioModel?

    var body: some View {
        Group {
            if let model {
                RecordingStudioContent(model: model)
            } else {
                ProgressView()
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .modifier(CaptureLibraryEditorRegistration(url: url))
        .task(id: url) {
            guard let url else { return }
            model?.teardown()
            let newModel = RecordingStudioModel(url: url)
            model = newModel
            await newModel.load()
            guard !Task.isCancelled else {
                newModel.teardown()
                return
            }
            if model === newModel, newModel.isLoaded {
                ScreenshotPreviewStack.shared.dismissVideo(for: newModel.sessionURL)
            }
        }
        .onDisappear {
            model?.teardown()
            model = nil
        }
    }
}

private struct RecordingStudioContent: View {
    @Bindable var model: RecordingStudioModel
    @State private var isInspectorPresented = true
    @State private var closeGuard = EditorCloseGuard()

    var body: some View {
        VStack(spacing: 0) {
            if let loadError = model.loadError {
                ContentUnavailableView(
                    "Couldn't open recording",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StudioCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AnnotationEditorWorkspaceBackground())

                StudioTimelineEditor(model: model)
            }
        }
        .frame(minWidth: 980, minHeight: 720)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .inspector(isPresented: $isInspectorPresented) {
            StudioInspector(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.isCroppingVideo {
                    Button {
                        model.undo()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                    .help("Undo (⌘Z)")

                    Button {
                        model.redo()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if model.isCroppingVideo {
                    videoCropActions
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            model.beginVideoCrop()
                        }
                    } label: {
                        Label("Crop", systemImage: "crop")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(!model.isLoaded || model.exportState.isExporting)
                    .help("Crop the finished video canvas")

                    if model.isProject {
                        saveStatus
                    }

                    if model.canShareToCloud {
                        shareStatus
                    }

                    exportStatus

                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                }
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .onWindowChange { window in
            guard let window else {
                closeGuard.detach()
                return
            }
            configureCloseGuard()
            closeGuard.attach(to: window)
            closeGuard.refreshDocumentEdited()
        }
        .onChange(of: model.hasUnsavedChanges) {
            closeGuard.refreshDocumentEdited()
        }
        .onDeleteCommand {
            if let selectedCueID = model.selectedCueID {
                model.removeZoomCue(id: selectedCueID)
            } else if let selectedMotionCueID = model.selectedMotionCueID {
                model.removeMotionCue(id: selectedMotionCueID)
            } else if model.selectedClipID != nil {
                model.deleteSelectedClip()
            }
        }
        .onAppear {
            AppActivationPolicy.enter(hidePreview: true)
        }
        .onDisappear {
            closeGuard.detach()
            AppActivationPolicy.leave(restorePreview: true)
        }
    }

    private var shareSuggestedTitle: String {
        model.projectDisplayName
    }

    @ViewBuilder
    private var videoCropActions: some View {
        Menu {
            Picker("Aspect Ratio", selection: videoCropAspectBinding) {
                ForEach(CropAspectRatio.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.videoCropAspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
        .help("Crop aspect ratio")

        Button("Reset") {
            withAnimation(.snappy(duration: 0.18)) {
                model.resetVideoCrop()
            }
        }
        .help("Reset the selection to the whole video")

        Button("Cancel") {
            withAnimation(.snappy(duration: 0.22)) {
                model.cancelVideoCrop()
            }
        }
        .keyboardShortcut(.cancelAction)

        Button("Crop") {
            withAnimation(.snappy(duration: 0.22)) {
                model.applyVideoCrop()
            }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
    }

    private var videoCropAspectBinding: Binding<CropAspectRatio> {
        Binding(
            get: { model.videoCropAspect },
            set: { aspect in
                withAnimation(.snappy(duration: 0.18)) {
                    model.setVideoCropAspect(aspect)
                }
            }
        )
    }

    /// AppKit already paints the unsaved dot in the close button; the title
    /// says it in words for anyone who reads the title bar first.
    private var windowTitle: String {
        let name = Self.friendlyTitle(for: model.projectDisplayName)
        return model.hasUnsavedChanges ? String(localized: "\(name) - Edited") : name
    }

    /// Length of the edited cut and the source resolution.
    private var windowSubtitle: String {
        guard model.isLoaded else { return "" }
        let total = Int(model.duration.rounded())
        let clock = String(format: "%d:%02d", total / 60, total % 60)
        let size = model.videoSize
        return "\(clock) · \(Int(size.width))×\(Int(size.height))"
    }

    /// Unrenamed recordings are named `Framecho_<timestamp>_<id>` on disk
    /// (`Screendrop_` before the rename);
    /// the title shows when it was recorded instead of the raw file name.
    private static func friendlyTitle(for name: String) -> String {
        let parts = name.split(separator: "_")
        guard parts.count >= 2, parts[0] == "Framecho" || parts[0] == "Screendrop" else { return name }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: String(parts[1])) else { return name }
        return String(localized: "Recording · \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    private func configureCloseGuard() {
        closeGuard.hasUnsavedChanges = { [weak model] in model?.hasUnsavedChanges ?? false }
        closeGuard.offersDelete = { [weak model] in model?.hasNeverBeenSaved ?? false }
        closeGuard.projectName = { [weak model] in model?.projectDisplayName ?? String(localized: "this recording") }
        closeGuard.onDecision = { [weak model] decision, done in
            guard let model else { return }
            switch decision {
            case .save:
                if model.saveProject() { done() }
            case .discard:
                Task {
                    await model.discardChanges()
                    done()
                }
            case .delete:
                model.deleteProject()
                done()
            case .cancel:
                break
            }
        }
    }

    /// Save is a plain toolbar button rather than a menu command: Studio is
    /// reached from a menu-bar app, where the main menu isn't a reliable
    /// place to look for ⌘S.
    @ViewBuilder
    private var saveStatus: some View {
        Button {
            model.saveProject()
        } label: {
            if model.saveFlash {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                // Icon-only: a greyed-out "Save" title read as broken
                // whenever there was nothing to save.
                Label("Save", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
            }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.hasUnsavedChanges)
        .help(model.hasUnsavedChanges ? "Save this project (⌘S)" : "All changes saved")
    }

    /// Share pipeline in one toolbar slot: render → upload → link copied.
    /// The upload leg reads the uploader's live progress so the pill keeps
    /// moving through both stages.
    @ViewBuilder
    private var shareStatus: some View {
        switch model.shareState {
        case .idle:
            CloudUploadButton(suggestedTitle: shareSuggestedTitle, onUpload: model.shareToCloud) {
                Label("Share", systemImage: "link")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.isLoaded || model.exportState.isExporting)
            .help("Upload this recording and copy the share link")
        case .rendering(let progress):
            SharePill(stage: String(localized: "Rendering"), progress: progress) {
                model.cancelShare()
            }
        case .uploading:
            SharePill(
                stage: String(localized: "Uploading"),
                progress: model.shareItemID.flatMap {
                    CloudUploader.shared.uploadProgress[$0]
                } ?? 0
            ) {
                model.cancelShare()
            }
        case .finished(let url):
            HStack(spacing: 6) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Label("Link Copied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .help("Copy the share link again")

                if let shareURL = URL(string: url) {
                    Link(destination: shareURL) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .accessibilityLabel("Open Share Link")
                    .help("Open the share link in your browser")
                }

                CloudUploadButton(suggestedTitle: shareSuggestedTitle, onUpload: model.shareToCloud) {
                    Image(systemName: "link")
                }
                .help("Share Again")
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Share Failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help(message)

                CloudUploadButton(suggestedTitle: shareSuggestedTitle, onUpload: model.shareToCloud) {
                    Text("Retry")
                }
            }
        }
    }

    private var exportSummary: String {
        let settings = model.exportSettings
        return "\(settings.effectiveContainer.title) · \(settings.resolution.title)"
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch model.exportState {
        case .idle:
            RecordingExportButton(
                currentSettings: model.exportSettings,
                onExport: model.export(settings:)
            ) {
                HStack(spacing: 6) {
                    Label("Export", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                    // The format to expect, before the options open.
                    Text(verbatim: exportSummary)
                        .opacity(0.8)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(!model.isLoaded || model.shareState.isBusy)
        case .exporting(let progress):
            ExportProgressPill(progress: progress) {
                model.cancelExport()
            }
        case .finished(let url):
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .help("Reveal exported recording in Finder")

                RecordingExportButton(
                    currentSettings: model.exportSettings,
                    onExport: model.export(settings:)
                ) {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Export Again")
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Export Failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help(message)

                RecordingExportButton(
                    currentSettings: model.exportSettings,
                    onExport: model.export(settings:)
                ) {
                    Text("Retry")
                }
            }
        }
    }
}

/// The determinate ring shared by every Studio progress affordance, so the
/// toolbar pills and the inspector's export button read as one control.
private struct StudioProgressRing: View {
    let progress: Double

    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.15), value: progress)
    }
}

/// Progress pill for the share pipeline: same ring treatment as the
/// export pill, with the stage name so render and upload read distinctly.
private struct SharePill: View {
    let stage: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StudioProgressRing(progress: progress)

            Text("\(stage) \(Int((progress * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize()
                .contentTransition(.numericText())

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel Share")
            .accessibilityLabel("Cancel Share")
        }
        .padding(.leading, 12)
    }
}

/// Single pill that replaces the old "Exporting…" button plus a separate
/// progress bar with one control: a ring showing percent complete, the
/// number itself, and a way to actually stop the export.
private struct ExportProgressPill: View {
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StudioProgressRing(progress: progress)

            Text("Exporting \(Int((progress * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize()
                .contentTransition(.numericText())

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel Export")
            .accessibilityLabel("Cancel Export")
        }
        .padding(.leading, 12)
    }
}

// MARK: - Canvas

private struct StudioCanvas: View {
    @Bindable var model: RecordingStudioModel

    /// A play/pause glyph that blooms in the middle of the canvas after a
    /// click toggles playback, then fades.
    private struct PlaybackFlash: Equatable {
        let id = UUID()
        let systemImage: String
    }

    @State private var playbackFlash: PlaybackFlash?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let available = CGSize(
                width: max(proxy.size.width - 68, 100),
                height: max(proxy.size.height - 56, 100)
            )
            let canvasSize = Self.aspectFit(model.previewCanvasSize, into: available)
            let cropEditingLayout = RecordingStudioLayout.make(
                canvasSize: canvasSize,
                style: model.style,
                includeBubble: model.hasCameraVideo,
                usesUniformPadding: model.exportAspect == .original,
                contentAspect: model.sourceVideoAspect,
                contentMode: .fit
            )

            ZStack(alignment: .topLeading) {
                StudioCanvasComposition(
                    model: model,
                    canvasSize: canvasSize,
                    isEditingVideoCrop: model.isCroppingVideo
                )
                // Clicking the picture plays or pauses, like a player.
                // The camera bubble and zoom target keep their own drags.
                .contentShape(Rectangle())
                .gesture(
                    TapGesture().onEnded(togglePlayback),
                    including: model.isCroppingVideo || model.activePoseAdjustment != nil
                        ? .subviews
                        : .all
                )

                if model.activePoseAdjustment != nil {
                    StudioPoseAdjustOverlay(
                        model: model,
                        layout: RecordingStudioLayout.make(
                            canvasSize: canvasSize,
                            style: model.style,
                            includeBubble: model.hasCameraVideo,
                            usesUniformPadding: model.exportAspect == .original,
                            contentAspect: model.previewContentAspect,
                            contentMode: model.previewContentMode,
                            contentCropRect: model.videoCropRect
                        ),
                        canvasSize: canvasSize
                    )
                }

                if model.isCroppingVideo {
                    VideoCropOverlay(
                        model: model,
                        canvasSize: canvasSize,
                        videoFrame: cropEditingLayout.cardRect
                    )

                    CropResolutionBadge(size: model.videoCropPixelSize)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                } else if model.activePoseAdjustment == nil, let skimTime {
                    StudioCanvasBadge(text: String(localized: "Previewing \(studioPreciseTimecode(skimTime))"))
                        .padding(10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let playbackFlash {
                    StudioPlaybackFlashView(systemImage: playbackFlash.systemImage)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .id(playbackFlash.id)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .coordinateSpace(name: VideoCropOverlay.coordinateSpaceName)
            .frame(width: canvasSize.width, height: canvasSize.height)
            // Square like the exported video, lifted off the workspace by a
            // hairline and a soft shadow instead of a rounded mask that also
            // clipped the camera bubble.
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(canvasEdge, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .background {
                Rectangle()
                    .fill(Color.black)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 14, y: 5)
            }
            .animation(.easeOut(duration: 0.15), value: skimTime == nil)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .overlay(alignment: .top) {
            if model.isLoaded, !model.isCroppingVideo {
                outputSizeLabel
                    .padding(.top, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// What the export will measure, so a ratio or resolution change shows
    /// its effect before exporting.
    private var outputSizeLabel: some View {
        let size = RecordingStudioExporter.deliveredCanvasSize(
            source: model.basePreviewCanvasSize,
            resolution: model.exportSettings.resolution
        )
        return HStack(spacing: 6) {
            Text(model.exportAspect.title)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 20)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Export size")
    }

    /// The hovered timeline moment while the preview skims away from the
    /// playhead; nil when the canvas shows the playhead frame.
    private var skimTime: TimeInterval? {
        guard !model.isPlaying,
              let hover = model.hoverPreviewTime,
              abs(hover - model.currentTime) > 0.05 else { return nil }
        return hover
    }

    private var canvasEdge: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    private func togglePlayback() {
        guard model.isLoaded else { return }
        model.togglePlayback()
        let flash = PlaybackFlash(systemImage: model.isPlaying ? "play.fill" : "pause.fill")
        withAnimation(.easeOut(duration: 0.12)) {
            playbackFlash = flash
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard playbackFlash == flash else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                playbackFlash = nil
            }
        }
    }

    private static func aspectFit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Small dark capsule for transient canvas status.
private struct StudioCanvasBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.62)))
    }
}

private struct StudioPlaybackFlashView: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(Circle().fill(Color.black.opacity(0.5)))
    }
}

/// The complete canvas composition. A video crop changes only the screen card
/// layout and viewport; background, camera and captions remain in canvas space.
/// Original sizes that canvas to the visible source plus an equal border.
private struct StudioCanvasComposition: View {
    @Bindable var model: RecordingStudioModel
    let canvasSize: CGSize
    let isEditingVideoCrop: Bool

    var body: some View {
        let layout = RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: model.style,
            includeBubble: model.hasCameraVideo,
            usesUniformPadding: model.exportAspect == .original,
            contentAspect: isEditingVideoCrop ? model.sourceVideoAspect : model.previewContentAspect,
            contentMode: isEditingVideoCrop ? .fit : model.previewContentMode,
            contentCropRect: isEditingVideoCrop ? CropRectEditor.unit : model.videoCropRect
        )

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.isPlaying)) { _ in
            let zoomTarget = zoomTargetCue
            // While a zoom's target is on show the frame stays unzoomed, so
            // the target reads against the whole picture.
            let state = isEditingVideoCrop || zoomTarget != nil
                ? ViewportFrame.identity
                : model.previewViewportFrame(at: model.displayTime)
            // Adjusting the source crop or a zoom target edits the flat
            // picture, so the card faces front until that mode ends. A pose
            // adjusted on the canvas shows as-is, whatever the playhead.
            let projection = RecordingCardProjection(
                cardRect: layout.cardRect,
                canvasSize: canvasSize,
                pose: model.adjustedPose ?? (isEditingVideoCrop || zoomTarget != nil
                    ? .identity
                    : model.motionPose(at: model.displayTime)),
                projectionVersion: model.motionTimeline.projectionVersion
            )

            ZStack {
                StudioBackgroundView(style: model.style.background)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipped()

                StudioPlayerLayerView(player: model.screenPlayer, gravity: .resize)
                    .allowsHitTesting(false)
                    .frame(
                        width: layout.contentFillSize.width,
                        height: layout.contentFillSize.height
                    )
                    .scaleEffect(state.magnification)
                    .offset(
                        x: (0.5 - state.anchor.x) * state.magnification * layout.contentFillSize.width,
                        y: (0.5 - state.anchor.y) * state.magnification * layout.contentFillSize.height
                    )
                    .frame(width: layout.cardRect.width, height: layout.cardRect.height)
                    .overlay {
                        if let pointer = model.pointerFrame(at: model.displayTime) {
                            StudioCursorOverlay(
                                pointer: pointer,
                                artwork: model.artwork(id: pointer.artworkID),
                                state: state,
                                cardSize: layout.cardRect.size,
                                contentSize: layout.contentFillSize,
                                cursorScale: model.style.cursorScale,
                                showsClickEffect: model.showsPressEffects
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous))
                    .overlay {
                        if let caption = model.keystrokeCaption(at: model.displayTime) {
                            StudioKeystrokeCaptionView(
                                caption: caption,
                                placement: model.keystrokePlacement,
                                cardSize: layout.cardRect.size
                            )
                        }
                    }
                    // Everything on the card projects together; the shadow
                    // follows, cast by the projected card in canvas space.
                    .projectionEffect(ProjectionTransform(
                        projection.localTransform(origin: layout.cardRect.origin)
                    ))
                    .shadow(
                        color: .black.opacity(model.style.background == .none ? 0 : 0.55 * model.style.shadow),
                        radius: min(canvasSize.width, canvasSize.height) * 0.045 * model.style.shadow,
                        y: min(canvasSize.width, canvasSize.height) * 0.016 * model.style.shadow
                    )
                    .position(x: layout.cardRect.midX, y: layout.cardRect.midY)

                if model.isCameraVisible(at: model.displayTime), layout.bubbleRect.width > 0 {
                    StudioCameraBubble(model: model, layout: layout)
                }

                if let subtitle = model.subtitleText(at: model.displayTime) {
                    StudioSubtitleBarView(
                        text: subtitle,
                        karaokeLine: model.subtitleKaraokeLine(at: model.displayTime),
                        style: model.subtitleStyle,
                        canvasSize: canvasSize
                    )
                }

                if let zoomTarget {
                    StudioZoomTargetOverlay(
                        model: model,
                        cue: zoomTarget,
                        layout: layout,
                        canvasSize: canvasSize
                    )
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            // A tilted card can reach past the canvas; the export crops
            // there, so the preview does too.
            .clipped()
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// The selected zoom, shown as a target on the paused canvas.
    private var zoomTargetCue: ZoomCue? {
        guard !isEditingVideoCrop,
              !model.isPlaying,
              model.activePoseAdjustment == nil,
              model.zoomEnabled,
              let cue = model.selectedCue,
              cue.isEnabled else { return nil }
        return cue
    }
}

// MARK: - Pose adjustment

/// Direct 3D manipulation of the card on the canvas, built around a
/// rotation ball at the card's center. The ball's horizontal ring turns the
/// card left and right, its vertical ring tilts it, its outer ring rotates it
/// in the screen plane, and dragging inside the ball rotates freely like a
/// trackball. Dragging the card outside the ball moves it; the corner
/// squares scale it. Every drag is one undo step; the inspector keeps exact
/// numeric entry.
private struct StudioPoseAdjustOverlay: View {
    @Bindable var model: RecordingStudioModel
    let layout: RecordingStudioLayout
    let canvasSize: CGSize

    /// What a drag changes, decided where it starts.
    private enum DragMode: Equatable {
        case trackball
        case turn
        case tilt
        case rotate
        case move
        case scale
    }

    /// The pose and pointer when a drag began, so each event is measured
    /// against a fixed start instead of compounding.
    private struct DragStart {
        let pose: RecordingCardPose
        let location: CGPoint
        let center: CGPoint
        let mode: DragMode
    }

    @State private var dragStart: DragStart?
    @State private var hoverMode: DragMode?

    /// How far a turn, tilt or trackball drag turns the card per point. Fixed
    /// rather than tied to the ball's size, so a small ball on a small canvas
    /// isn't coarser to steer than a large one.
    private static let degreesPerPoint: Double = 0.6
    /// Vertical squash of the turn and tilt rings, which is what makes the
    /// ball read as a sphere rather than a flat target.
    private static let ringDepth: CGFloat = 0.34
    /// How close to a ring a press must land to grab it.
    private static let ringGrabDistance: CGFloat = 7
    private static let handleSize: CGFloat = 9
    private static let coordinateSpace = CoordinateSpace.named(VideoCropOverlay.coordinateSpaceName)

    var body: some View {
        let pose = model.adjustedPose ?? .identity
        let projection = RecordingCardProjection(
            cardRect: layout.cardRect,
            canvasSize: canvasSize,
            pose: pose,
            projectionVersion: model.motionTimeline.projectionVersion
        )
        let quad = projection.quad(for: layout.cardRect)
        let center = projection.project(CGPoint(x: layout.cardRect.midX, y: layout.cardRect.midY))
        let radius = ballRadius(for: projection.bounds(of: layout.cardRect))
        let outline = Path { path in
            path.addLines(quad)
            path.closeSubpath()
        }

        ZStack(alignment: .topLeading) {
            // The card face: moving outside the ball, rotating inside it.
            outline
                .fill(Color.accentColor.opacity(0.05))
                .overlay {
                    outline.stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                }

            ball(pose: pose, center: center, radius: radius)

            ForEach(0..<4, id: \.self) { index in
                scaleHandle(at: quad[index])
            }

            hud(pose: pose)
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .bottom)
                .padding(.bottom, 10)
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        // One hit surface for the face and the ball, so a press anywhere on
        // the card picks its mode from where it lands.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: Self.coordinateSpace)
                .onChanged { value in
                    drag(value, quad: quad, center: center, radius: radius)
                }
                .onEnded { _ in end() }
        )
        .onContinuousHover(coordinateSpace: Self.coordinateSpace) { phase in
            switch phase {
            case .active(let location):
                hoverMode = mode(at: location, quad: quad, center: center, radius: radius)
            case .ended:
                hoverMode = nil
            }
        }
        .pointerStyle(pointerStyle)
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card pose")
        .accessibilityValue(Text(Self.summary(pose)))
        .accessibilityAdjustableAction { direction in
            var updated = pose
            updated.yawDegrees += direction == .increment ? 5 : -5
            model.setAdjustedPose(updated)
        }
    }

    // MARK: Ball

    /// Small enough to leave most of the card visible while adjusting it.
    private func ballRadius(for cardBounds: CGRect) -> CGFloat {
        min(max(min(cardBounds.width, cardBounds.height) * 0.15, 36), 64)
    }

    private func ball(pose: RecordingCardPose, center: CGPoint, radius: CGFloat) -> some View {
        let active = dragStart?.mode ?? hoverMode
        let turnRing = Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius * Self.ringDepth,
            width: radius * 2,
            height: radius * 2 * Self.ringDepth
        ))
        let tiltRing = Path(ellipseIn: CGRect(
            x: center.x - radius * Self.ringDepth,
            y: center.y - radius,
            width: radius * 2 * Self.ringDepth,
            height: radius * 2
        ))
        let rotateRing = Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        return ZStack(alignment: .topLeading) {
            // A soft shaded sphere so the controls read as 3D.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.28), Color.black.opacity(0.18)],
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: radius * 1.2
                    )
                )
                .frame(width: radius * 2, height: radius * 2)
                .position(center)

            ring(rotateRing, color: .blue, isActive: active == .rotate, width: 2.5)
            ring(turnRing, color: .green, isActive: active == .turn)
            ring(tiltRing, color: .red, isActive: active == .tilt)

            // Where the card's front faces on each ring.
            marker(at: turnMarker(pose: pose, center: center, radius: radius), color: .green)
            marker(at: tiltMarker(pose: pose, center: center, radius: radius), color: .red)
            marker(at: rotateMarker(pose: pose, center: center, radius: radius), color: .blue)

            Circle()
                .fill(Color.white.opacity(active == .trackball ? 0.9 : 0.6))
                .frame(width: 6, height: 6)
                .position(center)
        }
        .allowsHitTesting(false)
    }

    private func ring(_ path: Path, color: Color, isActive: Bool, width: CGFloat = 2) -> some View {
        path
            .stroke(color.opacity(isActive ? 1 : 0.75), lineWidth: isActive ? width + 1.5 : width)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
    }

    private func marker(at point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .frame(width: 9, height: 9)
            .position(point)
    }

    /// Yaw as a point travelling around the horizontal ring's front.
    private func turnMarker(pose: RecordingCardPose, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = pose.yawDegrees * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(sin(angle)),
            y: center.y + radius * Self.ringDepth * CGFloat(cos(angle))
        )
    }

    /// Pitch as a point travelling around the vertical ring's front.
    private func tiltMarker(pose: RecordingCardPose, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = pose.pitchDegrees * .pi / 180
        return CGPoint(
            x: center.x + radius * Self.ringDepth * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    /// Roll as a point on the outer ring, starting at the top.
    private func rotateMarker(pose: RecordingCardPose, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = pose.rollDegrees * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(sin(angle)),
            y: center.y - radius * CGFloat(cos(angle))
        )
    }

    // MARK: Hit testing

    private func mode(
        at location: CGPoint,
        quad: [CGPoint],
        center: CGPoint,
        radius: CGFloat
    ) -> DragMode? {
        if quad.contains(where: { hypot(location.x - $0.x, location.y - $0.y) <= 10 }) {
            return .scale
        }
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = hypot(dx, dy)
        if abs(distance - radius) <= Self.ringGrabDistance {
            return .rotate
        }
        if distance < radius {
            if Self.distance(toEllipseWithRadii: CGSize(width: radius, height: radius * Self.ringDepth),
                             dx: dx, dy: dy) <= Self.ringGrabDistance {
                return .turn
            }
            if Self.distance(toEllipseWithRadii: CGSize(width: radius * Self.ringDepth, height: radius),
                             dx: dx, dy: dy) <= Self.ringGrabDistance {
                return .tilt
            }
            return .trackball
        }
        let outline = Path { path in
            path.addLines(quad)
            path.closeSubpath()
        }
        return outline.contains(location) ? .move : nil
    }

    /// Approximate distance from a point to an axis-aligned ellipse's curve.
    private static func distance(toEllipseWithRadii radii: CGSize, dx: CGFloat, dy: CGFloat) -> CGFloat {
        guard radii.width > 0, radii.height > 0 else { return .infinity }
        let normalized = hypot(dx / radii.width, dy / radii.height)
        guard normalized > 0 else { return min(radii.width, radii.height) }
        let gradient = hypot(dx / (radii.width * radii.width), dy / (radii.height * radii.height))
        return abs(normalized * normalized - 1) / (2 * max(gradient, 0.0001))
    }

    // MARK: Dragging

    private func drag(
        _ value: DragGesture.Value,
        quad: [CGPoint],
        center: CGPoint,
        radius: CGFloat
    ) {
        if dragStart == nil {
            guard let mode = mode(at: value.startLocation, quad: quad, center: center, radius: radius) else {
                return
            }
            dragStart = DragStart(
                pose: model.adjustedPose ?? .identity,
                location: value.startLocation,
                center: center,
                mode: mode
            )
            model.beginMotionEdit()
        }
        guard let start = dragStart else { return }

        let modifiers = NSEvent.modifierFlags
        var dx = Double(value.location.x - start.location.x)
        var dy = Double(value.location.y - start.location.y)
        let degreesPerPoint = Self.degreesPerPoint
        var pose = start.pose

        switch start.mode {
        case .trackball:
            if modifiers.contains(.shift) {
                if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
            }
            // Like rolling the ball: dragging right sends the card's right
            // edge away, dragging down sends its bottom away.
            pose.yawDegrees = Self.detent(start.pose.yawDegrees + dx * degreesPerPoint)
            pose.pitchDegrees = Self.detent(start.pose.pitchDegrees - dy * degreesPerPoint)
        case .turn:
            pose.yawDegrees = Self.snapped(start.pose.yawDegrees + dx * degreesPerPoint, modifiers)
        case .tilt:
            pose.pitchDegrees = Self.snapped(start.pose.pitchDegrees - dy * degreesPerPoint, modifiers)
        case .rotate:
            let startAngle = atan2(
                Double(start.location.y - start.center.y),
                Double(start.location.x - start.center.x)
            )
            let angle = atan2(
                Double(value.location.y - start.center.y),
                Double(value.location.x - start.center.x)
            )
            var delta = (angle - startAngle) * 180 / .pi
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            pose.rollDegrees = Self.snapped(start.pose.rollDegrees + delta, modifiers)
        case .move:
            if modifiers.contains(.shift) {
                if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
            }
            pose.translationX = start.pose.translationX + dx / Double(max(canvasSize.width, 1))
            pose.translationY = start.pose.translationY + dy / Double(max(canvasSize.height, 1))
        case .scale:
            let startDistance = hypot(
                start.location.x - start.center.x,
                start.location.y - start.center.y
            )
            let distance = hypot(
                value.location.x - start.center.x,
                value.location.y - start.center.y
            )
            guard startDistance > 1 else { return }
            pose.scale = start.pose.scale * Double(distance / startDistance)
        }
        model.setAdjustedPose(pose)
    }

    private func end() {
        guard dragStart != nil else { return }
        dragStart = nil
        model.endMotionEdit(actionName: String(localized: "Adjust Pose"))
    }

    private func scaleHandle(at position: CGPoint) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            )
            .frame(width: Self.handleSize, height: Self.handleSize)
            .position(position)
            .allowsHitTesting(false)
    }

    private var pointerStyle: PointerStyle? {
        switch dragStart?.mode ?? hoverMode {
        case .move: .grabIdle
        case .scale: .frameResize(position: .topLeading)
        case .turn: .columnResize
        case .tilt: .rowResize
        case .trackball, .rotate: .default
        case nil: nil
        }
    }

    private var helpText: String {
        switch hoverMode {
        case .turn: String(localized: "Drag the green ring to turn the card left or right")
        case .tilt: String(localized: "Drag the red ring to tilt the card up or down")
        case .rotate: String(localized: "Drag the blue ring to rotate the card. Hold Shift for 15° steps.")
        case .trackball: String(localized: "Drag inside the ball to turn and tilt freely. Hold Shift to keep to one direction.")
        case .move: String(localized: "Drag the card to move it")
        case .scale: String(localized: "Drag to scale the card, or press = and -")
        case nil: ""
        }
    }

    // MARK: HUD

    private func hud(pose: RecordingCardPose) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(Self.summary(pose))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Reset") { model.resetAdjustedPose() }
                .controlSize(.small)
                .disabled(pose.isIdentity)
            Button("Done") { model.endPoseAdjustment() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .help("Finish adjusting (Esc)")
        }
        .help("Press = or - to scale the card, 0 to return it to 100%")
        .background { scaleShortcuts }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    /// Plain keys while adjusting: = grows the card, - shrinks it, and
    /// 0 returns it to 100%. ⌘= and ⌘- stay with the timeline zoom.
    private var scaleShortcuts: some View {
        ZStack {
            // One binding per physical key: "+" also matches the = key and
            // would fire twice.
            Button("Scale Up") { model.scaleAdjustedPose(by: Self.scaleStep) }
                .keyboardShortcut("=", modifiers: [])
            Button("Scale Down") { model.scaleAdjustedPose(by: 1 / Self.scaleStep) }
                .keyboardShortcut("-", modifiers: [])
            Button("Actual Size") { model.resetAdjustedScale() }
                .keyboardShortcut("0", modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let scaleStep = 1.05

    private var title: String {
        switch model.activePoseAdjustment {
        case .cue:
            String(localized: "Motion target")
        default:
            String(localized: "Base pose")
        }
    }

    static func summary(_ pose: RecordingCardPose) -> String {
        let degrees = InspectorValueFormat.degrees(signed: true)
        let percent = InspectorValueFormat.percent()
        let turn = degrees.displayString(for: CGFloat(pose.yawDegrees))
        let tilt = degrees.displayString(for: CGFloat(pose.pitchDegrees))
        let rotate = degrees.displayString(for: CGFloat(pose.rollDegrees))
        let scale = percent.displayString(for: CGFloat(pose.scale))
        return String(localized: "Turn \(turn) · Tilt \(tilt) · Rotate \(rotate) · Scale \(scale)")
    }

    /// Lands exactly on zero when a drag passes close to it.
    private static func detent(_ degrees: Double) -> Double {
        abs(degrees) < 1.5 ? 0 : degrees
    }

    /// Shift snaps a single-axis drag to 15° steps.
    private static func snapped(_ degrees: Double, _ modifiers: NSEvent.ModifierFlags) -> Double {
        modifiers.contains(.shift) ? (degrees / 15).rounded() * 15 : detent(degrees)
    }
}

/// Where the selected zoom will look, drawn over the unzoomed frame with
/// everything outside it dimmed. Fixed zooms can be dragged to re-aim them;
/// pointer and smart zooms follow the pointer, so their target is shown at
/// the pointer's position under the playhead and can't be moved.
private struct StudioZoomTargetOverlay: View {
    @Bindable var model: RecordingStudioModel
    let cue: ZoomCue
    let layout: RecordingStudioLayout
    let canvasSize: CGSize

    @State private var dragStartPoint: CGPoint?
    @State private var isHovering = false

    private var isMovable: Bool {
        cue.anchorMode == .pinnedAnchor
    }

    private var target: CGPoint {
        if isMovable { return cue.pinnedPoint }
        return model.pointerLocation(at: model.displayTime) ?? CGPoint(x: 0.5, y: 0.5)
    }

    var body: some View {
        let card = layout.cardRect
        let content = layout.contentFillSize
        let magnification = max(CGFloat(cue.zoom), 1)
        let size = CGSize(width: card.width / magnification, height: card.height / magnification)
        let center = CGPoint(
            x: card.midX + content.width * (target.x - 0.5),
            y: card.midY + content.height * (target.y - 0.5)
        )
        let rect = CGRect(
            x: min(max(center.x - size.width / 2, card.minX), card.maxX - size.width),
            y: min(max(center.y - size.height / 2, card.minY), card.maxY - size.height),
            width: size.width,
            height: size.height
        )
        let isActive = isHovering || dragStartPoint != nil

        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRoundedRect(
                    in: card,
                    cornerSize: CGSize(width: layout.cardCornerRadius, height: layout.cardCornerRadius),
                    style: .continuous
                )
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isActive ? 1 : 0.9),
                    style: StrokeStyle(lineWidth: isActive ? 2.5 : 2, dash: isMovable ? [] : [6, 4])
                )
                .background(Color.white.opacity(0.001))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .overlay(alignment: .topLeading) {
                    StudioCanvasBadge(
                        text: isMovable
                            ? InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: magnification)
                            : String(localized: "Follows pointer")
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                }
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 && isMovable }
                .pointerStyle(isMovable ? (dragStartPoint == nil ? PointerStyle.grabIdle : .grabActive) : nil)
                .onTapGesture {}
                .gesture(moveGesture(contentSize: content), including: isMovable ? .all : .none)
                .help(isMovable ? "Drag to aim this zoom" : "Switch Camera Focus to Fixed to aim this zoom by hand")
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func moveGesture(contentSize: CGSize) -> some Gesture {
        // Global coordinates: the target moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStartPoint == nil {
                    dragStartPoint = cue.pinnedPoint
                    model.beginZoomCueEdit()
                }
                guard let start = dragStartPoint,
                      contentSize.width > 0,
                      contentSize.height > 0 else { return }
                var updated = cue
                updated.pinnedPoint = CGPoint(
                    x: min(max(start.x + value.translation.width / contentSize.width, 0), 1),
                    y: min(max(start.y + value.translation.height / contentSize.height, 0), 1)
                )
                model.updateZoomCue(updated)
            }
            .onEnded { _ in
                dragStartPoint = nil
                model.endZoomCueEdit(actionName: String(localized: "Aim Zoom"))
            }
    }
}

private struct VideoCropOverlay: View {
    static let coordinateSpaceName = "VideoCropSpace"

    @Bindable var model: RecordingStudioModel
    let canvasSize: CGSize
    /// The uncropped screen-video card inside the surrounding canvas.
    let videoFrame: CGRect
    @State private var moveStartCrop: CGRect?

    private var cropViewRect: CGRect {
        let crop = model.workingVideoCropRect.standardized
        return CGRect(
            x: videoFrame.minX + crop.minX * videoFrame.width,
            y: videoFrame.minY + crop.minY * videoFrame.height,
            width: crop.width * videoFrame.width,
            height: crop.height * videoFrame.height
        )
    }

    private var visibleHandles: [CropHandle] {
        model.videoCropAspect.locksAspect
            ? CropHandle.allCases.filter(\.isCorner)
            : CropHandle.allCases
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(videoFrame)
                path.addRect(cropViewRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                for index in 1...2 {
                    let x = cropViewRect.minX + cropViewRect.width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: cropViewRect.minY))
                    path.addLine(to: CGPoint(x: x, y: cropViewRect.maxY))
                    let y = cropViewRect.minY + cropViewRect.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: cropViewRect.minX, y: y))
                    path.addLine(to: CGPoint(x: cropViewRect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: cropViewRect.width, height: cropViewRect.height)
                .position(x: cropViewRect.midX, y: cropViewRect.midY)
                .shadow(color: .black.opacity(0.3), radius: 1)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(cropViewRect.width, 1), height: max(cropViewRect.height, 1))
                .position(x: cropViewRect.midX, y: cropViewRect.midY)
                .gesture(moveGesture)

            ForEach(visibleHandles, id: \.self) { handle in
                VideoCropHandleView(handle: handle)
                    .position(handlePoint(handle))
                    .gesture(handleGesture(handle))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                let start = moveStartCrop ?? model.workingVideoCropRect.standardized
                if moveStartCrop == nil { moveStartCrop = start }
                guard videoFrame.width > 0, videoFrame.height > 0 else { return }
                model.moveVideoCrop(
                    from: start,
                    byNormalized: CGSize(
                        width: value.translation.width / videoFrame.width,
                        height: value.translation.height / videoFrame.height
                    )
                )
            }
            .onEnded { _ in moveStartCrop = nil }
    }

    private func handleGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                guard videoFrame.width > 0, videoFrame.height > 0 else { return }
                model.updateVideoCrop(
                    handle: handle,
                    toNormalized: CGPoint(
                        x: (value.location.x - videoFrame.minX) / videoFrame.width,
                        y: (value.location.y - videoFrame.minY) / videoFrame.height
                    )
                )
            }
    }

    private func handlePoint(_ handle: CropHandle) -> CGPoint {
        let unit = handle.unitPoint
        return CGPoint(
            x: cropViewRect.minX + cropViewRect.width * unit.x,
            y: cropViewRect.minY + cropViewRect.height * unit.y
        )
    }
}

private struct VideoCropHandleView: View {
    let handle: CropHandle

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())

            if handle.isCorner {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            } else {
                let isHorizontal = handle == .top || handle == .bottom
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white)
                    .frame(width: isHorizontal ? 26 : 7, height: isHorizontal ? 7 : 26)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            }
        }
    }
}

/// Recorded pointer artwork, placed through the same viewport transform the
/// video card uses (see RecordingPointerTimeline for why it is reconstructed).
private struct StudioCursorOverlay: View {
    let pointer: PointerFrame
    let artwork: PointerArtwork?
    let state: ViewportFrame
    let cardSize: CGSize
    /// The video's draw size at magnification 1 - equal to the card
    /// normally, larger when a reframe aspect-fills it.
    var contentSize: CGSize?
    let cursorScale: CGFloat
    let showsClickEffect: Bool

    var body: some View {
        let content = contentSize ?? cardSize
        let tip = CGPoint(
            x: cardSize.width / 2 + content.width * state.magnification * (pointer.location.x - state.anchor.x),
            y: cardSize.height / 2 + content.height * state.magnification * (pointer.location.y - state.anchor.y)
        )

        ZStack(alignment: .topLeading) {
            if showsClickEffect, let press = pointer.press {
                let pressTip = CGPoint(
                    x: cardSize.width / 2
                        + content.width * state.magnification * (press.location.x - state.anchor.x),
                    y: cardSize.height / 2
                        + content.height * state.magnification * (press.location.y - state.anchor.y)
                )
                let effect = PointerPressEffectStyle.geometry(
                    progress: press.progress,
                    referenceHeight: content.height,
                    cursorScale: cursorScale
                )
                let accent = PointerPressEffectStyle.color
                Circle()
                    .fill(
                        Color(red: accent.red, green: accent.green, blue: accent.blue)
                            .opacity(effect.impactOpacity)
                    )
                    .frame(width: effect.impactRadius * 2, height: effect.impactRadius * 2)
                    .position(x: pressTip.x, y: pressTip.y)
                Circle()
                    .stroke(
                        Color(red: accent.red, green: accent.green, blue: accent.blue)
                            .opacity(effect.rippleOpacity),
                        lineWidth: effect.rippleLineWidth
                    )
                    .frame(width: effect.rippleRadius * 2, height: effect.rippleRadius * 2)
                    .position(x: pressTip.x, y: pressTip.y)
            }

            if let artwork,
               let image = StudioCursorImageCache.image(for: artwork) {
                let anchor = artwork.normalizedAnchor
                let height = content.height
                    * PointerArtworkMetrics.heightRatio
                    * cursorScale
                    * artwork.intrinsicScale
                let size = CGSize(
                    width: height * artwork.aspectRatio,
                    height: height
                )
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(
                        CGFloat(pointer.magnification),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .rotationEffect(
                        .degrees(pointer.tiltDegrees),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .position(
                        x: tip.x + (0.5 - anchor.x) * size.width,
                        y: tip.y + (0.5 - anchor.y) * size.height
                    )
                    .opacity(pointer.opacity)
                    .blur(radius: CGFloat(pointer.blurRadius))
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .allowsHitTesting(false)
    }
}

/// The keystroke caption pill: one rounded container with the chord's
/// modifiers and key. Geometry comes from KeystrokeCaptionMetrics so the
/// exporter draws the identical pill.
private struct StudioKeystrokeCaptionView: View {
    let caption: KeystrokeCaptionFrame
    let placement: RecordingKeystrokePlacement
    let cardSize: CGSize

    var body: some View {
        let metrics = KeystrokeCaptionMetrics(cardHeight: cardSize.height)
        let (modifiers, key) = KeystrokeCaptionMetrics.text(for: caption)

        (Text(modifiers).foregroundStyle(.white.opacity(KeystrokeCaptionMetrics.modifierAlpha))
            + Text(key).foregroundStyle(.white))
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, metrics.paddingHorizontal)
            .padding(.vertical, metrics.paddingVertical)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(.black.opacity(KeystrokeCaptionMetrics.backgroundAlpha))
            )
            .scaleEffect(caption.scale)
            .opacity(caption.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
            .padding(metrics.margin)
            .frame(width: cardSize.width, height: cardSize.height)
            .allowsHitTesting(false)
    }
}

/// The narration subtitle bar: rounded black bar, white text, center-locked
/// horizontally at the style's vertical position on the full canvas
/// (background included). Geometry comes from SubtitleBarMetrics so the
/// exporter draws the identical bar.
private struct StudioSubtitleBarView: View {
    let text: String
    var karaokeLine: KaraokeTimeline.Line?
    let style: SubtitleBarStyle
    let canvasSize: CGSize

    var body: some View {
        let metrics = SubtitleBarMetrics(canvasSize: canvasSize, style: style)

        barText
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
            // Long lines wrap into centered lines on narrow canvases,
            // matching the exporter's framesetter layout; the scale
            // factor only kicks in past the shared line cap.
            .lineLimit(SubtitleBarMetrics.maximumLineCount)
            .multilineTextAlignment(.center)
            .lineSpacing(metrics.fontSize * (SubtitleBarMetrics.lineSpacingFactor - 1))
            .minimumScaleFactor(0.4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, metrics.paddingHorizontal)
            .padding(.vertical, metrics.paddingVertical)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(.black.opacity(SubtitleBarMetrics.backgroundAlpha))
            )
            // Invisible width cap: constrains where the text wraps while
            // the pill above hugs the text, so the bar never spans the
            // canvas.
            .frame(
                maxWidth: metrics.maximumTextWidth(canvasWidth: canvasSize.width)
                    + metrics.paddingHorizontal * 2
            )
            .position(
                x: canvasSize.width / 2,
                y: canvasSize.height * CGFloat(style.clampedVerticalPosition)
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
            .allowsHitTesting(false)
    }

    /// Plain white cue text, or karaoke-colored words matching the
    /// exporter's palette exactly (SubtitleBarMetrics.karaoke*).
    private var barText: Text {
        guard let karaokeLine, !karaokeLine.words.isEmpty else {
            return Text(text).foregroundStyle(.white)
        }
        var combined = Text(verbatim: "")
        for (index, word) in karaokeLine.words.enumerated() {
            let color: Color
            if index == karaokeLine.activeIndex {
                color = Color(cgColor: SubtitleBarMetrics.karaokeAccent)
            } else if index < karaokeLine.spokenCount {
                color = .white
            } else {
                color = .white.opacity(SubtitleBarMetrics.karaokeUpcomingAlpha)
            }
            let piece = Text(verbatim: index > 0 ? " \(word)" : word)
                .foregroundStyle(color)
            combined = combined + piece
        }
        return combined
    }
}

/// One editable subtitle line: a timestamp plus the cue text as a free-form
/// field. Hovering a row skims the preview to that cue, clicking or editing
/// commits the playhead there (paused), and the row under the playhead is
/// highlighted so the list follows the video.
private struct StudioSubtitleRow: View {
    @Bindable var model: RecordingStudioModel
    let cue: RecordingSubtitleCue
    let isActive: Bool

    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.seekToSubtitle(cue)
            } label: {
                Text(timestamp ?? "–:––")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(editorTime == nil)
            .help(editorTime == nil ? "This subtitle's audio was cut out" : "Jump to this subtitle")

            TextField(
                "Subtitle",
                text: Binding(
                    get: { cue.text },
                    set: { model.updateSubtitleText(id: cue.id, text: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.inspectorValue)
            .focused($isEditing)
            .onChange(of: isEditing) { _, editing in
                // Starting to edit parks the paused preview on this cue so
                // the correction is visible in context while typing.
                if editing {
                    model.seekToSubtitle(cue)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isActive ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .opacity(editorTime == nil ? 0.5 : 1)
        .onTapGesture {
            model.seekToSubtitle(cue)
        }
        .onHover { hovering in
            // Hover skims the paused preview like the timeline strip does;
            // leaving hands the frame back to the real playhead.
            guard !model.isPlaying, let editorTime else { return }
            if hovering {
                model.hoverPreviewTime = editorTime
            } else if model.hoverPreviewTime == editorTime {
                model.hoverPreviewTime = nil
            }
        }
    }

    /// Where this cue lands on the edited timeline; nil when its audio was
    /// cut out entirely.
    private var editorTime: TimeInterval? {
        model.editorTime(forSourceTime: cue.start)
            ?? model.editorTime(forSourceTime: (cue.start + cue.end) / 2)
    }

    private var timestamp: String? {
        guard let editorTime else { return nil }
        let total = max(0, Int(editorTime.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Descript-style transcript editing: the narration as flowing words.
/// Clicking a word jumps the playhead there, shift-clicking selects a
/// passage, and cutting the selection removes that stretch of the video.
/// Words whose footage is already cut render struck-through; filler words
/// carry a dotted underline so the bulk action's targets are visible.
private struct StudioTranscriptEditPanel: View {
    @Bindable var model: RecordingStudioModel

    @State private var selection: ClosedRange<Int>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    transcriptFlow
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
                        .fill(InspectorControlPalette.trackFill(for: colorScheme))
                )
                .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous))
                .onChange(of: model.activeTranscriptWordIndex) { _, activeIndex in
                    // Follow playback through the transcript, but never yank
                    // it around while the user is selecting a passage.
                    guard let activeIndex, model.isPlaying, selection == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }

            if let selection {
                cutSelectionRow(selection)
            }
        }
        .onDeleteCommand(perform: cutSelection)
        .onExitCommand { selection = nil }
    }

    private var transcriptFlow: some View {
        let activeIndex = model.activeTranscriptWordIndex
        return TranscriptFlowLayout() {
            ForEach(model.transcriptWords.indices, id: \.self) { index in
                StudioTranscriptWordView(
                    text: model.transcriptWords[index].displayText,
                    isSelected: selection?.contains(index) ?? false,
                    isActive: index == activeIndex,
                    isCut: !model.transcriptWordSurvives(index),
                    isFiller: model.isFillerWord(index)
                ) {
                    handleTap(on: index)
                }
                .id(index)
            }
        }
    }

    private func cutSelectionRow(_ selection: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            InspectorActionButton(
                selection.count == 1 ? "Cut Word" : "Cut \(selection.count) Words",
                systemImage: "scissors",
                role: .destructive,
                action: cutSelection
            )

            InspectorClearButton(help: "Clear selection") {
                self.selection = nil
            }
        }
    }

    private func handleTap(on index: Int) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld, let selection {
            self.selection = min(selection.lowerBound, index)...max(selection.upperBound, index)
        } else {
            selection = index...index
            model.seekToTranscriptWord(at: index)
        }
    }

    private func cutSelection() {
        guard let selection else { return }
        model.cutTranscriptWords(in: selection)
        self.selection = nil
    }
}

/// One word in the transcript editor, drawn so the flow reads as a plain
/// paragraph: the chip's side padding doubles as the inter-word space
/// (layout spacing is zero), which also makes a multi-word selection's
/// highlight contiguous like real text selection. The font weight never
/// changes with state - a width change would reflow the whole paragraph
/// on every playback tick. Kept to plain stored values so ticks only
/// re-render the words whose state actually changed.
private struct StudioTranscriptWordView: View {
    let text: String
    let isSelected: Bool
    let isActive: Bool
    let isCut: Bool
    let isFiller: Bool
    let action: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(foreground)
            .strikethrough(isCut, color: .secondary.opacity(0.6))
            .padding(.horizontal, 1.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var foreground: Color {
        isCut ? Color.secondary.opacity(0.45) : Color.primary
    }

    private var background: Color {
        if isSelected {
            Color.accentColor.opacity(isCut ? 0.12 : 0.24)
        } else if isActive, !isCut {
            Color.accentColor.opacity(0.2)
        } else if isFiller, !isCut {
            Color.orange.opacity(0.16)
        } else {
            Color.clear
        }
    }
}

/// Minimal left-aligned wrapping layout for the transcript's word chips.
/// Horizontal spacing lives inside the chips (see StudioTranscriptWordView),
/// so the layout only separates lines.
private struct TranscriptFlowLayout: Layout {
    var spacingX: CGFloat = 0
    var spacingY: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacingY
                rowHeight = 0
            }
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacingY
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension RecordingKeystrokePlacement {
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }
}

@MainActor
private enum StudioCursorImageCache {
    private static var capturedImages: [String: NSImage] = [:]

    static func image(for artwork: PointerArtwork) -> NSImage? {
        let cacheKey = "\(artwork.artworkID)-\(artwork.imageData.hashValue)"
        if let cached = capturedImages[cacheKey] {
            return cached
        }
        guard let image = NSImage(data: artwork.imageData) else { return nil }
        capturedImages[cacheKey] = image
        return image
    }
}

/// The draggable talking-head bubble. It snaps to the canvas corners, edge
/// midpoints and center lines (inside the same safe margin the layout keeps),
/// drawing a guide for each axis it has snapped on.
private struct StudioCameraBubble: View {
    @Bindable var model: RecordingStudioModel
    let layout: RecordingStudioLayout

    private static let snapDistance: CGFloat = 8
    private static let hoverRingPadding: CGFloat = 3

    private struct SnapGuides: Equatable {
        var x: CGFloat?
        var y: CGFloat?
    }

    /// Bubble center in canvas points when the drag began.
    @State private var dragStartCenter: CGPoint?
    @State private var guides = SnapGuides()
    @State private var isHovering = false

    var body: some View {
        let rect = layout.bubbleRect
        let canvas = layout.canvasSize
        let isActive = isHovering || dragStartCenter != nil

        ZStack(alignment: .topLeading) {
            guideLines(in: canvas)

            StudioPlayerLayerView(player: model.cameraPlayer, gravity: .resizeAspectFill)
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                }
                .overlay {
                    if isActive {
                        // Nested radius: the ring sits `hoverRingPadding` outside.
                        RoundedRectangle(
                            cornerRadius: layout.bubbleCornerRadius + Self.hoverRingPadding,
                            style: .continuous
                        )
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-Self.hoverRingPadding)
                        .allowsHitTesting(false)
                    }
                }
                .shadow(
                    color: .black.opacity(0.35),
                    radius: min(canvas.width, canvas.height) * 0.022,
                    y: min(canvas.width, canvas.height) * 0.009
                )
                .contentShape(RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous))
                .onHover { isHovering = $0 }
                .pointerStyle(dragStartCenter == nil ? PointerStyle.grabIdle : .grabActive)
                // Swallow clicks so they don't toggle playback underneath.
                .onTapGesture {}
                .gesture(dragGesture(rect: rect, canvas: canvas))
                .help("Drag to place the camera")
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func guideLines(in canvas: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let x = guides.x {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1, height: canvas.height)
                    .offset(x: x - 0.5)
            }
            if let y = guides.y {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: canvas.width, height: 1)
                    .offset(y: y - 0.5)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func dragGesture(rect: CGRect, canvas: CGSize) -> some Gesture {
        // Global coordinates: the bubble moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStartCenter == nil {
                    // Start from where the bubble is drawn, not the stored
                    // center, which the layout may have clamped.
                    dragStartCenter = CGPoint(x: rect.midX, y: rect.midY)
                }
                guard let start = dragStartCenter, canvas.width > 0, canvas.height > 0 else { return }
                let proposed = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                let margin = RecordingStudioLayout.bubbleMargin(
                    forMinDimension: min(canvas.width, canvas.height)
                )
                let (snappedX, guideX) = Self.snap(
                    proposed.x,
                    radius: rect.width / 2,
                    length: canvas.width,
                    margin: margin
                )
                let (snappedY, guideY) = Self.snap(
                    proposed.y,
                    radius: rect.height / 2,
                    length: canvas.height,
                    margin: margin
                )
                guides = SnapGuides(x: guideX, y: guideY)
                model.style.camera.center = CGPoint(
                    x: min(max(snappedX / canvas.width, 0), 1),
                    y: min(max(snappedY / canvas.height, 0), 1)
                )
            }
            .onEnded { _ in
                dragStartCenter = nil
                withAnimation(.easeOut(duration: 0.15)) {
                    guides = SnapGuides()
                }
            }
    }

    /// Snaps one axis of the bubble center to the near edge, the middle, or
    /// the far edge. Returns the snapped center and where to draw the guide.
    private static func snap(
        _ center: CGFloat,
        radius: CGFloat,
        length: CGFloat,
        margin: CGFloat
    ) -> (CGFloat, CGFloat?) {
        let targets: [(center: CGFloat, guide: CGFloat)] = [
            (margin + radius, margin),
            (length / 2, length / 2),
            (length - margin - radius, length - margin)
        ]
        guard let nearest = targets.min(by: { abs($0.center - center) < abs($1.center - center) }),
              abs(nearest.center - center) <= snapDistance else {
            return (center, nil)
        }
        return (nearest.center, nearest.guide)
    }
}

/// Renders an AnnotationBackgroundStyle as a live SwiftUI layer.
private struct StudioBackgroundView: View {
    let style: AnnotationBackgroundStyle

    var body: some View {
        switch style {
        case .none:
            Color(white: 0.04)
        case .solid(let color):
            color.color
        case .gradient(let gradient):
            LinearGradient(
                colors: gradient.colors.map(\.color),
                startPoint: gradient.startPoint,
                endPoint: gradient.endPoint
            )
        case .customWallpaper(let wallpaper):
            if let image = NSImage(contentsOf: wallpaper.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.04)
            }
        }
    }
}

/// AVPlayerLayer host for the preview canvas.
private struct StudioPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> StudioPlayerContainerView {
        let view = StudioPlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ nsView: StudioPlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.playerLayer.videoGravity = gravity
    }
}

final class StudioPlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The video only displays; every click and drag on the card belongs to
    /// the SwiftUI gestures above it. Left hit-testable, AppKit routed
    /// mouse-downs inside the (projected) player to this view first, so the
    /// canvas's pose and crop drags never started.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Timeline

private struct StudioTimelineEditor: View {
    @Bindable var model: RecordingStudioModel

    /// Horizontal scale of the lanes, as a multiplier over "the whole
    /// recording fits the viewport". Zoom 1 is the timeline's original
    /// fixed-width layout; anything above it scrolls.
    @State private var zoom: Double = 1
    @State private var viewportWidth: CGFloat = 1
    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var isResetClipsConfirmationPresented = false
    @State private var mutedAudioVolume: CGFloat?

    /// Step per zoom button press / keyboard shortcut.
    private static let zoomStep: Double = 1.6
    /// How close to the viewport edge the playhead may drift before the
    /// lanes scroll to keep it in sight.
    private static let followMargin: CGFloat = 48

    private var scale: StudioTimelineScale {
        StudioTimelineScale(
            viewportWidth: viewportWidth,
            duration: model.duration,
            zoom: zoom
        )
    }

    var body: some View {
        VStack(spacing: StudioTimelineMetrics.rowSpacing) {
            transport
            HStack(alignment: .top, spacing: StudioTimelineMetrics.headerSpacing) {
                laneHeaders
                lanes
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
    }

    private var lanes: some View {
        GeometryReader { proxy in
            // The proxy width leads the stored one by a frame, so lay the
            // lanes out from it and keep the state copy for the controls.
            let scale = StudioTimelineScale(
                viewportWidth: max(proxy.size.width, 1),
                duration: model.duration,
                zoom: zoom
            )

            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.playheadLaneHeight)

                StudioTimelineRuler(
                    duration: model.duration,
                    pointsPerSecond: scale.pointsPerSecond,
                    scrollX: scrollX
                )
                .frame(height: StudioTimelineMetrics.rulerHeight)

                scrollingLanes(scale: scale)
            }
            .overlay {
                StudioTimelinePlayhead(
                    time: model.currentTime,
                    scale: scale,
                    scrollX: scrollX
                ) { time in
                    model.pause()
                    model.seek(to: time)
                }
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                viewportWidth = max(width, 1)
                clampZoom()
            }
        }
        .frame(height: StudioTimelineMetrics.lanesHeight(lanes: visibleLanes))
        .onChange(of: model.duration) { _, _ in clampZoom() }
        .onChange(of: model.currentTime) { _, time in followPlayhead(to: time) }
    }

    /// The two lanes that carry real edit targets live in a horizontal scroll
    /// view sized to the zoomed timeline. The ruler, playhead and lane chrome
    /// stay viewport-sized and redraw against `scrollX` instead - a rounded
    /// rectangle or Canvas tens of thousands of points wide would be a single
    /// oversized layer, while an AppKit view only ever draws its visible rect.
    private func scrollingLanes(scale: StudioTimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.clipLaneHeight)
                if showsAudioLane {
                    StudioAudioLane(
                        waveform: model.audioWaveform,
                        timeline: model.clipTimeline,
                        replacementName: model.replacementAudio?.displayName,
                        isMuted: model.audioVolume <= 0,
                        scale: scale,
                        scrollX: scrollX
                    )
                    .frame(height: StudioTimelineMetrics.audioLaneHeight)
                }
                StudioZoomLaneBackground(
                    showsHint: model.zoomEnabled && model.zoomTimelineBlocks.isEmpty
                )
                    .frame(height: StudioTimelineMetrics.zoomLaneHeight)
                if showsCaptionLane {
                    StudioCaptionLaneBackground(isEmpty: !model.hasSubtitles)
                        .frame(height: StudioTimelineMetrics.captionLaneHeight)
                }
                StudioMotionLaneBackground(
                    showsHint: model.motionTimelineBlocks.isEmpty
                )
                    .frame(height: StudioTimelineMetrics.motionLaneHeight)
                Color.clear
                    .frame(height: StudioTimelineMetrics.scrollerGutter)
            }

            ScrollView(.horizontal) {
                VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                    clipLane
                        .frame(
                            width: scale.contentWidth,
                            height: StudioTimelineMetrics.clipLaneHeight
                        )

                    if showsAudioLane {
                        Color.clear
                            .frame(
                                width: scale.contentWidth,
                                height: StudioTimelineMetrics.audioLaneHeight
                            )
                    }

                    StudioZoomLane(
                        model: model,
                        scale: scale,
                        visibleRange: scale.visibleRange(scrollX: scrollX)
                    )
                    .frame(
                        width: scale.contentWidth,
                        height: StudioTimelineMetrics.zoomLaneHeight
                    )

                    if showsCaptionLane {
                        StudioCaptionLane(
                            model: model,
                            scale: scale,
                            visibleRange: scale.visibleRange(scrollX: scrollX)
                        )
                        .frame(
                            width: scale.contentWidth,
                            height: StudioTimelineMetrics.captionLaneHeight
                        )
                    }

                    StudioMotionLane(
                        model: model,
                        scale: scale,
                        visibleRange: scale.visibleRange(scrollX: scrollX)
                    )
                    .frame(
                        width: scale.contentWidth,
                        height: StudioTimelineMetrics.motionLaneHeight
                    )

                    Color.clear
                        .frame(height: StudioTimelineMetrics.scrollerGutter)
                }
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(scale.isScrollable ? .visible : .never)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                if abs(offset - scrollX) > 0.01 {
                    scrollX = offset
                }
            }

            // An unused caption lane offers to fill itself. It sits over the
            // scroll view, centered in the viewport rather than in a lane
            // that may be many screens wide.
            if showsCaptionLane, !model.hasSubtitles {
                VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                    Color.clear
                        .frame(height: captionLaneOffset)
                        .allowsHitTesting(false)
                    StudioCaptionLanePrompt(model: model)
                        .frame(height: StudioTimelineMetrics.captionLaneHeight)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(height: StudioTimelineMetrics.scrollingLanesHeight(lanes: visibleLanes))
    }

    /// Recorded sound is drawn inside the clips; a lane of its own only
    /// appears for a replacement file, which no longer follows the picture.
    private var showsAudioLane: Bool {
        model.replacementAudio != nil
    }

    private var showsCaptionLane: Bool {
        model.canTranscribe || model.hasSubtitles
    }

    private var visibleLanes: StudioTimelineMetrics.Lanes {
        StudioTimelineMetrics.Lanes(
            audio: showsAudioLane,
            captions: showsCaptionLane
        )
    }

    /// Height above the caption lane inside the scrolling block.
    private var captionLaneOffset: CGFloat {
        StudioTimelineMetrics.clipLaneHeight
            + (showsAudioLane ? StudioTimelineMetrics.audioLaneHeight + StudioTimelineMetrics.rowSpacing : 0)
            + StudioTimelineMetrics.zoomLaneHeight
            + StudioTimelineMetrics.rowSpacing
    }

    private var showsClipWaveform: Bool {
        model.replacementAudio == nil && model.hasRecordedAudio
    }

    /// Mute keeps the level it replaced, so unmuting restores it rather
    /// than jumping to full volume.
    private var audioOnBinding: Binding<Bool> {
        Binding(
            get: { model.audioVolume > 0 },
            set: { isOn in
                if isOn {
                    model.audioVolume = mutedAudioVolume ?? 1
                    mutedAudioVolume = nil
                } else {
                    mutedAudioVolume = model.audioVolume
                    model.audioVolume = 0
                }
            }
        )
    }

    /// Names each lane so the tracks read without hovering, with the switch
    /// that turns that lane's effect on or off beside it. The corner above
    /// them adds the lanes a recording doesn't show yet.
    private var laneHeaders: some View {
        VStack(alignment: .leading, spacing: StudioTimelineMetrics.rowSpacing) {
            addTrackMenu
                .frame(
                    height: StudioTimelineMetrics.playheadLaneHeight
                        + StudioTimelineMetrics.rulerHeight
                        + StudioTimelineMetrics.rowSpacing,
                    alignment: .bottomLeading
                )

            if showsClipWaveform {
                StudioLaneHeader(
                    title: "Video",
                    systemImage: "film",
                    tint: .accentColor,
                    isOn: audioOnBinding,
                    toggleHelp: model.audioVolume > 0 ? "Mute" : "Unmute",
                    onSymbol: "speaker.wave.2",
                    offSymbol: "speaker.slash",
                    dimsWhenOff: false
                )
                .frame(height: StudioTimelineMetrics.clipLaneHeight)
            } else {
                StudioLaneHeader(title: "Video", systemImage: "film", tint: .accentColor)
                    .frame(height: StudioTimelineMetrics.clipLaneHeight)
            }

            if showsAudioLane {
                StudioLaneHeader(
                    title: "Audio",
                    systemImage: "waveform",
                    tint: StudioAudioLane.tint,
                    isOn: audioOnBinding,
                    toggleHelp: model.audioVolume > 0 ? "Mute" : "Unmute",
                    onSymbol: "speaker.wave.2",
                    offSymbol: "speaker.slash"
                )
                .frame(height: StudioTimelineMetrics.audioLaneHeight)
            }

            StudioLaneHeader(
                title: "Zoom",
                systemImage: "plus.magnifyingglass",
                tint: .accentColor,
                isOn: $model.zoomEnabled,
                toggleHelp: model.zoomEnabled ? "Turn Zooms Off" : "Turn Zooms On"
            )
            .frame(height: StudioTimelineMetrics.zoomLaneHeight)

            if showsCaptionLane {
                if model.hasSubtitles {
                    StudioLaneHeader(
                        title: "Captions",
                        systemImage: "captions.bubble",
                        tint: StudioCaptionLane.tint,
                        isOn: $model.showsSubtitles,
                        toggleHelp: model.showsSubtitles ? "Hide Subtitles" : "Show Subtitles"
                    )
                    .frame(height: StudioTimelineMetrics.captionLaneHeight)
                } else {
                    StudioLaneHeader(
                        title: "Captions",
                        systemImage: "captions.bubble",
                        tint: StudioCaptionLane.tint
                    )
                    .frame(height: StudioTimelineMetrics.captionLaneHeight)
                }
            }

            StudioLaneHeader(
                title: "3D Motion",
                systemImage: "rotate.3d",
                tint: StudioMotionCueBlock.tint
            )
            .frame(height: StudioTimelineMetrics.motionLaneHeight)
        }
        .frame(width: StudioTimelineMetrics.headerWidth, alignment: .leading)
    }

    /// Lanes that stay hidden until used. Each item starts the thing that
    /// fills its lane, which is what makes the lane appear.
    private var addTrackMenu: some View {
        Menu {
            Button {
                model.transcribe()
            } label: {
                Label("Captions", systemImage: "captions.bubble")
            }
            .disabled(!model.canTranscribe || model.hasSubtitles || model.transcriptionState.isTranscribing)

            Button {
                model.chooseReplacementAudio()
            } label: {
                Label("Replacement Audio…", systemImage: "music.note")
            }
            .disabled(model.replacementAudio != nil)
        } label: {
            Label("Add Track", systemImage: "plus")
                .font(.system(size: 11.5, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(TransportTextButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.isLoaded)
        .help("Add a caption or audio track")
    }

    private var clipLane: some View {
        RecordingClipTimelineView(
            selectedClipID: $model.selectedClipID,
            playheadTime: $model.currentTime,
            timeline: model.clipTimeline,
            sourceDuration: model.sourceDuration,
            thumbnails: model.timelineThumbnails,
            waveform: showsClipWaveform ? model.audioWaveform : nil,
            isAudioMuted: model.audioVolume <= 0,
            onSelect: { model.selectClip(id: $0) },
            onSeek: { time in
                model.pause()
                model.seek(to: time)
            },
            onHover: { time in
                model.timelineHoverTime = time
                model.hoverPreviewTime = time
            },
            onSplit: { model.splitClip(at: $0) },
            onDelete: { deleteSelection() },
            onTrim: { model.trimClip($0) },
            onZoom: { factor, anchorTime in
                applyZoom(factor: factor, anchorTime: anchorTime)
            },
            onStep: { seconds in
                model.pause()
                model.seek(to: model.currentTime + seconds)
            }
        )
    }

    // MARK: Zoom & scroll

    /// Rescales around `anchorTime`, keeping that moment under the same
    /// screen position so pinching or ⌘-scrolling doesn't shove the edit
    /// you were aiming at out of the viewport.
    private func applyZoom(factor: Double, anchorTime: TimeInterval?) {
        let current = scale
        guard current.duration > 0, factor.isFinite, factor > 0 else { return }
        let anchor = anchorTime ?? current.time(forX: scrollX + viewportWidth / 2)
        let anchorViewportX = current.x(for: anchor) - scrollX
        let next = min(max(zoom * factor, 1), current.maxZoom)
        guard abs(next - zoom) > 0.0001 else { return }

        // A pinch arrives as dozens of small steps; let the storyboard scale
        // with the lane and resample once the gesture settles.
        model.timelineThumbnails.deferSampling()
        zoom = next
        var zoomed = current
        zoomed.zoom = next
        scroll(to: zoomed.x(for: anchor) - anchorViewportX, in: zoomed)
    }

    private func fitTimeline() {
        guard zoom > 1 else { return }
        zoom = 1
        scrollX = 0
        scrollPosition.scrollTo(edge: .leading)
    }

    /// Keeps the zoom inside range after the viewport or the edited duration
    /// changes - a cut or a wider window can leave the old scale past the cap.
    private func clampZoom() {
        let clamped = min(max(zoom, 1), scale.maxZoom)
        if abs(clamped - zoom) > 0.0001 {
            zoom = clamped
        }
    }

    private func followPlayhead(to time: TimeInterval) {
        let current = scale
        guard current.isScrollable else { return }
        let x = current.x(for: time)
        guard x < scrollX + Self.followMargin
            || x > scrollX + viewportWidth - Self.followMargin else { return }
        // While playing, land the playhead a third in so there is room to
        // watch what is coming; a seek just centers it.
        let inset = model.isPlaying ? viewportWidth / 3 : viewportWidth / 2
        scroll(to: x - inset, in: current)
    }

    private func scroll(to x: CGFloat, in scale: StudioTimelineScale) {
        let clamped = min(max(x, 0), max(0, scale.contentWidth - scale.viewportWidth))
        scrollX = clamped
        scrollPosition.scrollTo(x: clamped)
    }

    /// Zoom buttons keep the playhead pinned when it is on screen, so the
    /// scale grows around the edit point rather than the viewport middle.
    private var buttonZoomAnchor: TimeInterval {
        let x = scale.x(for: model.currentTime)
        if x >= scrollX, x <= scrollX + viewportWidth {
            return model.currentTime
        }
        return scale.time(forX: scrollX + viewportWidth / 2)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            timelineButton("Zoom Out (⌘-)", systemImage: "minus.magnifyingglass") {
                applyZoom(factor: 1 / Self.zoomStep, anchorTime: buttonZoomAnchor)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= 1.0001)

            // Logarithmic, so each stretch of the slider zooms by the same
            // ratio however long the recording is.
            Slider(value: zoomSliderBinding, in: 0...1)
                .controlSize(.mini)
                .frame(width: 84)
                .disabled(scale.maxZoom <= 1.0001)
                .help("Timeline Zoom")
                .accessibilityLabel("Timeline Zoom")

            timelineButton("Zoom In (⌘=)", systemImage: "plus.magnifyingglass") {
                applyZoom(factor: Self.zoomStep, anchorTime: buttonZoomAnchor)
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(zoom >= scale.maxZoom - 0.0001)

            Button("Fit") {
                fitTimeline()
            }
            .buttonStyle(TransportTextButtonStyle())
            .keyboardShortcut("0", modifiers: .command)
            .disabled(zoom <= 1.0001)
            .help("Fit Timeline (⌘0)")
        }
    }

    private var zoomSliderBinding: Binding<Double> {
        Binding(
            get: {
                let maxZoom = scale.maxZoom
                guard maxZoom > 1.0001 else { return 0 }
                return log(zoom) / log(maxZoom)
            },
            set: { fraction in
                let target = pow(scale.maxZoom, min(max(fraction, 0), 1))
                applyZoom(factor: target / zoom, anchorTime: buttonZoomAnchor)
            }
        )
    }

    private var editControls: some View {
        HStack(spacing: 2) {
            timelineButton("Split at Playhead (⌘B)", systemImage: "scissors") {
                model.splitClip(at: model.currentTime)
            }
            .keyboardShortcut("b", modifiers: .command)

            timelineButton("Delete Selection (⌫)", systemImage: "trash") {
                deleteSelection()
            }
            .disabled(!canDeleteSelection)

            speedMenu

            timelineButton("Reset All Clip Edits…", systemImage: "arrow.counterclockwise") {
                isResetClipsConfirmationPresented = true
            }
            .disabled(!model.hasClipEdits)
            .confirmationDialog(
                "Reset all clip edits?",
                isPresented: $isResetClipsConfirmationPresented
            ) {
                Button("Reset Clips", role: .destructive) {
                    model.resetClips()
                }
            } message: {
                Text("Every split, trim, deletion and speed change goes back to the original recording. You can undo this.")
            }
        }
    }

    /// Playback rate of the selected clip, offered beside the cut tools so a
    /// slow stretch can be sped up without leaving the timeline.
    private var speedMenu: some View {
        let clip = model.selectedClip
        return Menu {
            if let clip {
                Picker("Speed", selection: Binding(
                    get: { clip.speed },
                    set: { model.setClipSpeed($0, forClipID: clip.id) }
                )) {
                    ForEach(Self.clipSpeedPresets, id: \.self) { speed in
                        Text(Self.speedLabel(speed)).tag(speed)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 11, weight: .medium))
                Text(Self.speedLabel(clip?.speed ?? 1))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.system(size: 11.5, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(TransportTextButtonStyle())
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(clip == nil)
        .help(clip == nil ? "Select a clip to change its speed" : "Clip Speed")
        .accessibilityLabel("Clip Speed")
    }

    /// The inspector's whole-number rates, within `RecordingClipSegment`'s
    /// 1...8 range.
    private static let clipSpeedPresets: [Double] = [1, 2, 3, 4, 6, 8]

    private static func speedLabel(_ speed: Double) -> String {
        InspectorValueFormat.magnification(fractionDigits: 0).displayString(for: speed)
    }

    /// Where the playhead is against the length of the cut, on the leading
    /// edge where the eye starts reading the transport.
    private var timecode: some View {
        HStack(spacing: 4) {
            Text(studioPreciseTimecode(model.displayTime))
                .foregroundStyle(.primary.opacity(0.9))
            Text(verbatim: "/")
                .foregroundStyle(.tertiary)
            Text(studioPreciseTimecode(model.duration))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .accessibilityElement(children: .combine)
    }

    private var playbackControls: some View {
        HStack(spacing: 6) {
            timelineButton("Previous Edit Point", systemImage: "backward.end.fill") {
                model.pause()
                model.seek(to: previousEditPoint)
            }

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.85)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .disabled(!model.isLoaded)

            timelineButton("Next Edit Point", systemImage: "forward.end.fill") {
                model.pause()
                model.seek(to: nextEditPoint)
            }
        }
    }

    /// Clip boundaries plus both ends of the cut, in editor time.
    private var editPoints: [TimeInterval] {
        var points: [TimeInterval] = [0]
        var editorTime: TimeInterval = 0
        for segment in model.clipTimeline.segments {
            editorTime += segment.editorDuration
            points.append(editorTime)
        }
        points.append(model.duration)
        return points
    }

    /// A little slack so pressing again from a boundary moves on to the
    /// next one rather than landing where it already is.
    private static let editPointTolerance: TimeInterval = 0.05

    private var previousEditPoint: TimeInterval {
        editPoints.last { $0 < model.currentTime - Self.editPointTolerance } ?? 0
    }

    private var nextEditPoint: TimeInterval {
        editPoints.first { $0 > model.currentTime + Self.editPointTolerance } ?? model.duration
    }

    /// Time and the cut tools on the leading edge, playback in the middle,
    /// and the timeline scale on the trailing edge. The cut tools are
    /// icon-only so the row still clears the centered playback buttons at
    /// the window's minimum width.
    private var transport: some View {
        ZStack {
            HStack(spacing: 0) {
                timecode
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 8)
                editControls
                Spacer(minLength: 0)
                zoomControls
            }

            playbackControls
        }
        .frame(height: 36)
    }

    private var canDeleteSelection: Bool {
        model.selectedCueID != nil || model.selectedMotionCueID != nil || model.canDeleteSelectedClip
    }

    private func deleteSelection() {
        if let cueID = model.selectedCueID {
            model.removeZoomCue(id: cueID)
        } else if let motionCueID = model.selectedMotionCueID {
            model.removeMotionCue(id: motionCueID)
        } else if model.selectedClipID != nil {
            model.deleteSelectedClip()
        }
    }

    private func timelineButton(
        _ help: LocalizedStringResource,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(TransportIconButtonStyle())
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

private enum StudioTransportMetrics {
    static let buttonRadius: CGFloat = 6
}

private struct TransportIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                .primary.opacity(
                    isEnabled ? (configuration.isPressed || isHovering ? 0.95 : 0.78) : 0.25
                )
            )
            .background {
                RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous)
                    .fill(Color.primary.opacity(
                        isEnabled ? (configuration.isPressed ? 0.1 : isHovering ? 0.06 : 0) : 0
                    ))
            }
            .onHover { isHovering = $0 }
    }
}

/// Borderless transport button with a title, hover-filled like the icon
/// buttons beside it.
private struct TransportTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .frame(height: 26)
            .foregroundStyle(
                .primary.opacity(
                    isEnabled ? (configuration.isPressed || isHovering ? 0.95 : 0.8) : 0.3
                )
            )
            .background {
                RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous)
                    .fill(Color.primary.opacity(
                        isEnabled ? (configuration.isPressed ? 0.1 : isHovering ? 0.06 : 0) : 0
                    ))
            }
            .contentShape(RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

private enum StudioTimelineMetrics {
    static let rowSpacing: CGFloat = 4
    static let playheadLaneHeight: CGFloat = 14
    static let rulerHeight: CGFloat = 16
    static let clipLaneHeight: CGFloat = 54
    static let zoomLaneHeight: CGFloat = 24
    static let captionLaneHeight: CGFloat = 24
    static let motionLaneHeight: CGFloat = 24
    /// Lane name column to the left of the tracks.
    static let headerWidth: CGFloat = 104
    static let headerSpacing: CGFloat = 8
    /// Room under the lanes for the horizontal scroller, so it never sits on
    /// top of a zoom block.
    static let scrollerGutter: CGFloat = 8

    static let audioLaneHeight: CGFloat = 22

    /// The optional lanes on show. The audio lane appears for replacement
    /// audio and captions for narrated recordings; the video, zoom and 3D
    /// motion lanes are always there.
    struct Lanes: Equatable {
        var audio: Bool
        var captions: Bool
    }

    static func scrollingLanesHeight(lanes: Lanes) -> CGFloat {
        clipLaneHeight + zoomLaneHeight + motionLaneHeight + scrollerGutter + rowSpacing * 3
            + (lanes.audio ? audioLaneHeight + rowSpacing : 0)
            + (lanes.captions ? captionLaneHeight + rowSpacing : 0)
    }

    static func lanesHeight(lanes: Lanes) -> CGFloat {
        playheadLaneHeight + rulerHeight
            + scrollingLanesHeight(lanes: lanes)
            + rowSpacing * 2
    }
}

/// Recorded sound under the clip lane, drawn through the clip edits so cuts
/// and speed changes line up with the picture. Like the ruler it is
/// viewport-sized and redraws against `scrollX`.
private struct StudioAudioLane: View {
    static let tint = Color.green

    let waveform: RecordingAudioWaveform?
    let timeline: RecordingClipTimeline
    /// Name of a file that replaces the recorded sound, shown instead of the
    /// recording's waveform since that is no longer what plays.
    let replacementName: String?
    let isMuted: Bool
    let scale: StudioTimelineScale
    let scrollX: CGFloat

    private static let barPitch: CGFloat = 3
    private static let barWidth: CGFloat = 2

    var body: some View {
        RoundedRectangle(cornerRadius: StudioZoomLaneMetrics.laneCornerRadius, style: .continuous)
            .fill(Self.tint.opacity(0.07))
            .overlay {
                if let replacementName {
                    Label(replacementName, systemImage: "music.note")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                } else if let waveform {
                    bars(for: waveform)
                }
            }
            .opacity(isMuted ? 0.45 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func bars(for waveform: RecordingAudioWaveform) -> some View {
        Canvas { context, size in
            guard scale.pointsPerSecond > 0, size.width > 0 else { return }
            let midY = size.height / 2
            let maxHalfHeight = size.height / 2 - 2
            let contentEnd = scale.x(for: scale.duration) - scrollX
            var path = Path()
            var x = -scrollX.truncatingRemainder(dividingBy: Self.barPitch)
            while x < min(size.width, contentEnd) {
                let startTime = scale.time(forX: x + scrollX)
                let endTime = scale.time(forX: x + scrollX + Self.barPitch)
                let sourceStart = timeline.sourceTime(at: startTime)
                // A bar straddling a cut would otherwise read the deleted
                // span between the two clips; cap it at the fastest speed.
                let maxSpan = (endTime - startTime) * RecordingClipSegment.maximumSpeed
                let sourceEnd = min(
                    max(timeline.sourceTime(at: endTime), sourceStart),
                    sourceStart + maxSpan
                )
                let peak = CGFloat(waveform.peak(from: sourceStart, to: sourceEnd))
                let half = max(0.75, peak * maxHalfHeight)
                path.addRoundedRect(
                    in: CGRect(x: x, y: midY - half, width: Self.barWidth, height: half * 2),
                    cornerSize: CGSize(width: 1, height: 1)
                )
                x += Self.barPitch
            }
            context.fill(path, with: .color(Self.tint.opacity(0.75)))
        }
    }
}

/// Name, icon chip and optional on/off switch for one timeline lane. The
/// chip carries the lane's colour, so a lane reads as the same thing as its
/// blocks and the canvas marks they produce.
private struct StudioLaneHeader: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .secondary
    var isOn: Binding<Bool>?
    var toggleHelp: LocalizedStringKey = ""
    var onSymbol = "eye"
    var offSymbol = "eye.slash"
    /// Whether switching off greys the lane out. The video lane's switch
    /// mutes its sound, which leaves the picture as it was.
    var dimsWhenOff = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isActive ? tint : Color.secondary.opacity(0.6))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill((isActive ? tint : Color.secondary).opacity(0.15))
                )
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if let isOn {
                Button {
                    isOn.wrappedValue.toggle()
                } label: {
                    Image(systemName: isOn.wrappedValue ? onSymbol : offSymbol)
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .help(Text(toggleHelp))
                .accessibilityLabel(Text(toggleHelp))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var isActive: Bool {
        guard dimsWhenOff else { return true }
        return isOn?.wrappedValue ?? true
    }
}

/// Shared horizontal scale for every lane in the Studio timeline. `zoom` is a
/// multiplier over "the whole recording fits the viewport", so zoom 1 keeps
/// the original fixed-width timeline and higher values widen the lanes into a
/// scrolling surface where cuts, trim handles and zoom blocks stay grabbable
/// on long recordings.
private struct StudioTimelineScale: Equatable {
    /// Finest scale worth offering; past this a single frame is wider than a
    /// thumbnail tile.
    static let maximumPointsPerSecond: CGFloat = 240
    /// Ceiling on lane width, which is what actually bounds the scale on long
    /// recordings. A 30-minute take still reaches ~55 points per second here.
    static let maximumContentWidth: CGFloat = 100_000

    var viewportWidth: CGFloat
    var duration: TimeInterval
    var zoom: Double

    var contentWidth: CGFloat {
        max(viewportWidth, viewportWidth * CGFloat(zoom))
    }

    var pointsPerSecond: CGFloat {
        duration > 0 ? contentWidth / CGFloat(duration) : 0
    }

    var secondsPerPoint: Double {
        pointsPerSecond > 0 ? 1 / Double(pointsPerSecond) : 0
    }

    var isScrollable: Bool {
        contentWidth > viewportWidth + 0.5
    }

    var maxZoom: Double {
        guard duration > 0, viewportWidth > 1 else { return 1 }
        let widest = min(
            Self.maximumContentWidth,
            Self.maximumPointsPerSecond * CGFloat(duration)
        )
        return max(1, Double(widest / viewportWidth))
    }

    func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time, 0), duration)) * pointsPerSecond
    }

    func time(forX x: CGFloat) -> TimeInterval {
        guard pointsPerSecond > 0 else { return 0 }
        return min(max(Double(x / pointsPerSecond), 0), duration)
    }

    /// Editor time span currently on screen, padded a little so lane content
    /// culled against it never pops in at the edges.
    func visibleRange(scrollX: CGFloat) -> ClosedRange<TimeInterval> {
        let margin: CGFloat = 120
        let lower = time(forX: scrollX - margin)
        let upper = time(forX: scrollX + viewportWidth + margin)
        return lower...max(lower, upper)
    }
}

/// Full-height playhead with a grabbable crown pin in the lane above the
/// ruler. The crown is the only hit target - everywhere else the overlay
/// passes clicks through to the tracks underneath.
private struct StudioTimelinePlayhead: View {
    let time: TimeInterval
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let onScrub: (TimeInterval) -> Void

    private enum Metrics {
        static let crownWidth: CGFloat = 11
        static let crownHeight: CGFloat = 13
        static let hitWidth: CGFloat = 26
        static let hitHeight: CGFloat = 22
        static let lineWidth: CGFloat = 1.5
    }

    private static let coordinateSpace = "studio.playheadLane"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            // Viewport space: the playhead overlay never scrolls, it just
            // tracks the scrolled lanes underneath it.
            let x = scale.x(for: time) - scrollX
            let isVisible = x >= -Metrics.lineWidth && x <= width + Metrics.lineWidth

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(
                        width: Metrics.lineWidth,
                        height: max(0, proxy.size.height - Metrics.crownHeight + 2)
                    )
                    .offset(x: x - Metrics.lineWidth / 2, y: Metrics.crownHeight - 2)
                    .allowsHitTesting(false)
                    .opacity(isVisible ? 1 : 0)

                Color.clear
                    .frame(width: Metrics.hitWidth, height: Metrics.hitHeight)
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        PlayheadCrownShape()
                            .fill(Color.accentColor)
                            .frame(width: Metrics.crownWidth, height: Metrics.crownHeight)
                            .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    }
                    .offset(x: x - Metrics.hitWidth / 2, y: 0)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .gesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .named(Self.coordinateSpace)
                        )
                        .onChanged { value in
                            onScrub(scale.time(forX: value.location.x + scrollX))
                        }
                    )
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
    }
}

/// Rounded flag with a pointed tail, the classic editor playhead pin.
private struct PlayheadCrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat = 3
        let tailHeight: CGFloat = 4
        let bodyBottom = rect.maxY - tailHeight

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: bodyBottom),
            control: CGPoint(x: rect.maxX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: bodyBottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyBottom - cornerRadius),
            control: CGPoint(x: rect.minX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Absolute-time ruler above the clip lane. The ruler itself never scrolls: it
/// draws only the time span currently on screen, so a deeply zoomed timeline
/// costs the same to render as a fitted one.
private struct StudioTimelineRuler: View {
    let duration: Double
    let pointsPerSecond: CGFloat
    let scrollX: CGFloat

    var body: some View {
        Canvas { context, size in
            guard duration > 0.2, pointsPerSecond > 0, size.width > 60 else { return }

            let step = Self.labelStep(forPointsPerSecond: pointsPerSecond)
            let startTime = max(0, Double(scrollX / pointsPerSecond))
            let endTime = min(duration, Double((scrollX + size.width) / pointsPerSecond))
            let endpointLabel = Self.label(for: duration, step: step)
            var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude

            func x(for time: Double) -> CGFloat {
                CGFloat(time) * pointsPerSecond - scrollX
            }

            /// `anchorX` is the tick position. Labels sit just right of
            /// their tick so the first one is never clipped at the lane edge;
            /// `trailing` right-aligns the endpoint label so it stays inside
            /// the viewport.
            func drawLabel(_ text: String, at anchorX: CGFloat, trailing: Bool = false) {
                let label = context.resolve(
                    Text(text)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.secondary)
                )
                let labelSize = label.measure(in: size)
                let labelX = trailing ? anchorX - labelSize.width - 3 : anchorX + 3
                let clampedX = min(max(labelX, 0), max(0, size.width - labelSize.width))
                guard clampedX >= lastLabelMaxX + 8 else { return }
                context.draw(label, in: CGRect(
                    x: clampedX,
                    y: size.height - 1 - labelSize.height,
                    width: labelSize.width,
                    height: labelSize.height
                ))
                lastLabelMaxX = clampedX + labelSize.width
            }

            var index = max(0, Int(floor(startTime / step)))
            let lastIndex = Int(ceil(endTime / step))
            while index <= lastIndex {
                let time = Double(index) * step
                index += 1
                guard time <= duration else { break }
                let tickX = x(for: time)

                context.fill(
                    Path(CGRect(x: tickX - 0.5, y: size.height - 4, width: 1, height: 4)),
                    with: .color(.primary.opacity(0.30))
                )

                let minorTime = time + step / 2
                if minorTime < duration {
                    context.fill(
                        Path(CGRect(
                            x: x(for: minorTime) - 0.5,
                            y: size.height - 2.5,
                            width: 1,
                            height: 2.5
                        )),
                        with: .color(.primary.opacity(0.16))
                    )
                }

                // A final whole-second tick can format identically to a
                // fractional endpoint (for example 4.2 -> 00:04). Let the
                // actual endpoint own that label.
                let timeLabel = Self.label(for: time, step: step)
                if time == 0 || timeLabel != endpointLabel {
                    drawLabel(timeLabel, at: tickX)
                }
            }

            // The end of the recording always gets a tick, right-aligned when
            // it lands at the trailing edge of the viewport.
            let endpointX = x(for: duration)
            if endpointX >= -1, endpointX <= size.width + 1 {
                context.fill(
                    Path(CGRect(
                        x: min(endpointX, size.width - 0.5) - 0.5,
                        y: size.height - 4,
                        width: 1,
                        height: 4
                    )),
                    with: .color(.primary.opacity(0.30))
                )
                drawLabel(endpointLabel, at: endpointX, trailing: true)
            }
        }
    }

    /// Smallest "nice" interval whose labels stay comfortably apart at the
    /// current scale. Sub-second steps unlock once a zoomed lane spreads a
    /// single second across most of the viewport.
    private static func labelStep(forPointsPerSecond pointsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [
            0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800
        ]
        for candidate in candidates where CGFloat(candidate) * pointsPerSecond >= 64 {
            return candidate
        }
        return candidates.last ?? 60
    }

    private static func label(for time: Double, step: Double) -> String {
        step < 1 ? studioPreciseTimecode(time) : studioTimecode(time)
    }
}

private func studioTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let total = Int(safe.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainingSeconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        : String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func studioPreciseTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let totalMinutes = Int(safe) / 60
    let remaining = safe.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", totalMinutes, remaining)
}

/// Frame around the zoom lane. It stays pinned to the viewport while the cue
/// blocks scroll inside it, so the lane reads as a fixed track no matter how
/// far the timeline is zoomed.
private struct StudioZoomLaneBackground: View {
    /// An empty lane explains itself instead of reading as dead space.
    var showsHint = false

    var body: some View {
        RoundedRectangle(
            cornerRadius: StudioZoomLaneMetrics.laneCornerRadius,
            style: .continuous
        )
            .fill(Color.primary.opacity(0.055))
            .overlay {
                if showsHint {
                    Label("Drag here to add a zoom", systemImage: "plus.magnifyingglass")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
    }
}

private struct StudioZoomLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>

    /// Below this many dragged points, a gesture on blank lane space is
    /// still treated as a click-to-seek rather than a zoom-creating drag.
    private static let dragCreateThreshold: CGFloat = 4

    /// Held as a time rather than a position so a zoom change mid-drag can't
    /// reinterpret where the drag began.
    @State private var dragStartTime: TimeInterval?
    @State private var pendingZoomRange: ClosedRange<TimeInterval>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Contentless hit surface: the lane can be tens of thousands of
            // points wide, and the visible frame is drawn by the chrome behind
            // the scroll view.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale.pointsPerSecond > 0 else { return }
                            let time = scale.time(forX: value.location.x)

                            if dragStartTime == nil {
                                model.pause()
                                dragStartTime = time
                            }
                            guard let startTime = dragStartTime else { return }

                            if pendingZoomRange == nil,
                               abs(value.location.x - scale.x(for: startTime))
                                   < Self.dragCreateThreshold {
                                // Still within click tolerance: scrub the
                                // playhead, same as a plain click always has.
                                model.seek(to: time)
                                return
                            }

                            pendingZoomRange = pendingRange(from: startTime, to: time)
                        }
                        .onEnded { _ in
                            // A range clamped to nothing means the drag ran
                            // entirely into a neighboring block; there is no
                            // gap here to put a zoom in.
                            if let range = pendingZoomRange,
                               range.upperBound - range.lowerBound > 0.001 {
                                model.addZoomCue(
                                    fromEditorTime: range.lowerBound,
                                    toEditorTime: range.upperBound
                                )
                            }
                            dragStartTime = nil
                            pendingZoomRange = nil
                        }
                )

            if let pendingZoomRange {
                let lowX = scale.x(for: pendingZoomRange.lowerBound)
                let highX = scale.x(for: pendingZoomRange.upperBound)
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(2, highX - lowX), height: StudioZoomLaneMetrics.blockHeight)
                    .offset(x: lowX, y: StudioZoomLaneMetrics.blockInset)
                    .allowsHitTesting(false)
            }

            // Click ticks and cue blocks are culled to the visible span: an
            // hour-long take can hold thousands of clicks, and only a screenful
            // of them can ever be seen.
            ForEach(Array(visiblePressTimes.enumerated()), id: \.offset) { _, pressTime in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.38))
                    .frame(width: 1, height: 10)
                    .offset(x: scale.x(for: pressTime), y: 11)
                    .allowsHitTesting(false)
            }

            ForEach(visibleBlocks) { block in
                StudioZoomCueBlock(model: model, block: block, scale: scale)
            }
        }
        .contextMenu {
            Button("Add Zoom at Playhead") {
                model.addZoomCue(at: model.currentTime)
            }
        }
    }

    /// The range a drag-created zoom would cover, stopped at the blocks on
    /// either side of where the drag began so the preview matches the cue the
    /// model will actually allow.
    private func pendingRange(
        from startTime: TimeInterval,
        to currentTime: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        let blocks = model.zoomTimelineBlocks
        let lowerLimit = blocks
            .filter { $0.editorEnd <= startTime }
            .map(\.editorEnd)
            .max() ?? 0
        let upperLimit = blocks
            .filter { $0.editorStart >= startTime }
            .map(\.editorStart)
            .min() ?? model.duration
        let low = max(min(startTime, currentTime), lowerLimit)
        let high = min(max(startTime, currentTime), upperLimit)
        return low...max(low, high)
    }

    private var visiblePressTimes: [TimeInterval] {
        model.visibleRecordedPressTimes.filter { visibleRange.contains($0) }
    }

    private var visibleBlocks: [RecordingZoomTimelineBlock] {
        model.zoomTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

private enum StudioZoomLaneMetrics {
    static let laneInset: CGFloat = 3
    static let blockCornerRadius: CGFloat = 5
    static let laneCornerRadius = blockCornerRadius + laneInset
    static let selectionRingPadding: CGFloat = 1
    static let selectionRingCornerRadius = blockCornerRadius + selectionRingPadding
    static let blockHeight: CGFloat = 18
    static let blockInset: CGFloat = 3
    static let minimumLabelledBlockWidth: CGFloat = 48
}

private struct StudioZoomCueBlock: View {
    @Bindable var model: RecordingStudioModel
    let block: RecordingZoomTimelineBlock
    let scale: StudioTimelineScale

    /// Frozen at drag start. The live block re-derives on every model update,
    /// so measuring the drag against it would compound the translation each
    /// event and send the block flying.
    private struct DragBase {
        let cue: ZoomCue
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    @State private var dragBase: DragBase?

    private var isSelected: Bool {
        model.selectedCueID == block.cue.id
    }

    var body: some View {
        guard scale.pointsPerSecond > 0 else { return AnyView(EmptyView()) }

        let cue = block.cue
        let blockDuration = block.editorEnd - block.editorStart
        // Short cues keep a grabbable minimum width even when the timeline is
        // fitted; zooming in is what makes them accurate to work with.
        let width = min(
            scale.contentWidth,
            max(24, CGFloat(blockDuration) * scale.pointsPerSecond)
        )
        let x = min(
            max(scale.x(for: block.editorStart), 0),
            max(0, scale.contentWidth - width)
        )

        return AnyView(
            HStack(spacing: 0) {
                resizeHandle(edge: .leading)
                Spacer(minLength: 0)
                // Too narrow for the label: show the block bare rather
                // than a truncated "…".
                if width >= StudioZoomLaneMetrics.minimumLabelledBlockWidth {
                    Text(String(format: "%.1f×", cue.zoom))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                resizeHandle(edge: .trailing)
            }
            .frame(width: width, height: StudioZoomLaneMetrics.blockHeight)
            .background(
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(Color.accentColor.opacity(isSelected ? 0.95 : 0.72))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: StudioZoomLaneMetrics.selectionRingCornerRadius,
                        style: .continuous
                    )
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        .padding(-StudioZoomLaneMetrics.selectionRingPadding)
                }
            }
            .offset(x: x, y: StudioZoomLaneMetrics.blockInset)
            .gesture(
                // Global coordinates: the block moves under the pointer while
                // dragging, so a local-space translation would chase its own
                // updates and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var moved = dragBase.cue
                        let length = dragBase.cue.duration
                        let baseBlockDuration = dragBase.editorEnd - dragBase.editorStart
                        let editorStart = min(
                            max(0, dragBase.editorStart + delta),
                            max(0, model.duration - baseBlockDuration)
                        )
                        moved.start = min(
                            max(0, model.sourceTime(atEditorTime: editorStart)),
                            max(0, model.sourceDuration - length)
                        )
                        moved.end = min(model.sourceDuration, moved.start + length)
                        model.moveZoomCue(moved)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endZoomCueEdit(actionName: String(localized: "Move Zoom"))
                    }
            )
            .onTapGesture {
                model.selectZoomCue(id: cue.id)
            }
            .contextMenu {
                Button("Remove Zoom", role: .destructive) {
                    model.removeZoomCue(id: cue.id)
                }
            }
        )
    }

    private func resizeHandle(edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10, height: StudioZoomLaneMetrics.blockHeight)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(Color.white.opacity(isSelected ? 0.9 : 0.45))
                    .frame(width: 2.5, height: 12)
            }
            .contentShape(Rectangle())
            .gesture(
                // Global coordinates - the handle itself moves while resizing,
                // so local-space translations feed back into the drag and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: block.cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: block.cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var resized = dragBase.cue
                        switch edge {
                        case .leading:
                            let editorTime = dragBase.editorStart + delta
                            let sourceTime = model.sourceTime(atEditorTime: editorTime)
                            resized.start = min(
                                max(0, sourceTime),
                                dragBase.cue.end - ZoomCue.minimumDuration
                            )
                        case .trailing:
                            let editorTime = dragBase.editorEnd + delta
                            let sourceTime = model.sourceTime(atEditorTime: editorTime)
                            resized.end = max(
                                dragBase.cue.start + ZoomCue.minimumDuration,
                                min(model.sourceDuration, sourceTime)
                            )
                        }
                        model.updateZoomCue(resized)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endZoomCueEdit(actionName: String(localized: "Resize Zoom"))
                    }
            )
    }
}

// MARK: - Motion lane

/// Frame of the caption lane, drawn behind the scroll view like the other
/// lanes. An empty lane is dashed so it reads as a slot waiting to be used.
private struct StudioCaptionLaneBackground: View {
    var isEmpty = false

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: StudioZoomLaneMetrics.laneCornerRadius,
            style: .continuous
        )
        Group {
            if isEmpty {
                shape.strokeBorder(
                    Color.primary.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            } else {
                shape.fill(Color.primary.opacity(0.055))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Says what the empty caption lane is for and starts the transcription
/// from where the captions will appear.
private struct StudioCaptionLanePrompt: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.transcriptionState {
            case .transcribing:
                ProgressView()
                    .controlSize(.mini)
                Text("Transcribing narration…")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
                Text("Couldn't transcribe the narration")
                    .foregroundStyle(.secondary)
                promptButton("Try Again")
            case .idle:
                Text("Turn the narration into captions")
                    .foregroundStyle(.tertiary)
                promptButton("Transcribe")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func promptButton(_ title: LocalizedStringKey) -> some View {
        Button(title) {
            model.transcribe()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(!model.isLoaded)
    }
}

/// Transcribed captions on the edited timeline. A cue cut in two by an edit
/// still reads as one block, the same way zoom blocks merge across cuts.
/// Clicking a block jumps to it; blank space seeks like the other lanes.
private struct StudioCaptionLane: View {
    static let tint = Color.teal

    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>

    private struct Block: Identifiable {
        let id: UUID
        let text: String
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale.pointsPerSecond > 0 else { return }
                            model.pause()
                            model.seek(to: scale.time(forX: value.location.x))
                        }
                )

            ForEach(visibleBlocks) { block in
                blockView(block)
            }
        }
    }

    private func blockView(_ block: Block) -> some View {
        let minX = scale.x(for: block.editorStart)
        let width = max(2, scale.x(for: block.editorEnd) - minX - 2)
        let isCurrent = (block.editorStart..<block.editorEnd).contains(model.currentTime)
        return Text(block.text)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(width: width, height: StudioZoomLaneMetrics.blockHeight, alignment: .leading)
            .foregroundStyle(isCurrent ? Color.white : Color.primary.opacity(0.8))
            .background(
                RoundedRectangle(cornerRadius: StudioZoomLaneMetrics.blockCornerRadius, style: .continuous)
                    .fill(Self.tint.opacity(isCurrent ? 0.85 : 0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioZoomLaneMetrics.blockCornerRadius, style: .continuous)
                    .strokeBorder(Self.tint.opacity(isCurrent ? 0 : 0.4), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                model.pause()
                model.seek(to: block.editorStart)
            }
            .offset(x: minX + 1, y: StudioZoomLaneMetrics.blockInset)
            .help(block.text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(block.text))
            .accessibilityAddTraits(.isButton)
    }

    private var visibleBlocks: [Block] {
        let timeline = model.clipTimeline
        return model.subtitleCues.compactMap { cue in
            let slices = timeline.slices(overlapping: cue.start, sourceEnd: cue.end)
            guard let first = slices.first, let last = slices.last,
                  last.editorEnd >= visibleRange.lowerBound,
                  first.editorStart <= visibleRange.upperBound else { return nil }
            return Block(id: cue.id, text: cue.text, editorStart: first.editorStart, editorEnd: last.editorEnd)
        }
    }
}

private struct StudioMotionLaneBackground: View {
    var showsHint = false

    var body: some View {
        RoundedRectangle(
            cornerRadius: StudioZoomLaneMetrics.laneCornerRadius,
            style: .continuous
        )
            .fill(Color.primary.opacity(0.055))
            .overlay {
                if showsHint {
                    Label("Drag here to add 3D motion", systemImage: "rotate.3d")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
    }
}

/// Timed 3D motion cues. Blank space seeks on a click and draws a new motion
/// on a drag, like the zoom lane; blocks move and resize like zoom blocks,
/// and their ramps show the entrance and exit as they play.
private struct StudioMotionLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>

    /// Below this many dragged points, a gesture on blank lane space is
    /// still treated as a click-to-seek rather than a motion-creating drag.
    private static let dragCreateThreshold: CGFloat = 4
    /// A drawn motion starts as this preset; the inspector opens on it to
    /// pick another.
    private static let drawnPreset: RecordingMotionPreset = .tiltLeft

    /// Held as a time rather than a position so a zoom change mid-drag can't
    /// reinterpret where the drag began.
    @State private var dragStartTime: TimeInterval?
    @State private var pendingMotionRange: ClosedRange<TimeInterval>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale.pointsPerSecond > 0 else { return }
                            let time = scale.time(forX: value.location.x)

                            if dragStartTime == nil {
                                model.pause()
                                dragStartTime = time
                            }
                            guard let startTime = dragStartTime else { return }

                            if pendingMotionRange == nil,
                               abs(value.location.x - scale.x(for: startTime))
                                   < Self.dragCreateThreshold {
                                model.seek(to: time)
                                return
                            }

                            pendingMotionRange = pendingRange(from: startTime, to: time)
                        }
                        .onEnded { _ in
                            // A range clamped to nothing means the drag ran
                            // entirely into a neighboring block.
                            if let range = pendingMotionRange,
                               range.upperBound - range.lowerBound > 0.001 {
                                model.addMotionCue(
                                    preset: Self.drawnPreset,
                                    fromEditorTime: range.lowerBound,
                                    toEditorTime: range.upperBound
                                )
                            }
                            dragStartTime = nil
                            pendingMotionRange = nil
                        }
                )

            if let pendingMotionRange {
                let lowX = scale.x(for: pendingMotionRange.lowerBound)
                let highX = scale.x(for: pendingMotionRange.upperBound)
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(StudioMotionCueBlock.tint.opacity(0.35))
                    .frame(width: max(2, highX - lowX), height: StudioZoomLaneMetrics.blockHeight)
                    .offset(x: lowX, y: StudioZoomLaneMetrics.blockInset)
                    .allowsHitTesting(false)
            }

            ForEach(visibleBlocks) { block in
                StudioMotionCueBlock(model: model, block: block, scale: scale)
            }
        }
        .contextMenu {
            Menu("Add Motion at Playhead") {
                ForEach(RecordingMotionPreset.allCases) { preset in
                    Button {
                        model.addMotionCue(preset: preset, at: model.currentTime)
                    } label: {
                        Label(preset.title, systemImage: preset.systemImage)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("3D motion track")
    }

    /// The range a drag-created motion would cover, stopped at the blocks on
    /// either side of where the drag began so the preview matches the cue the
    /// model will actually allow.
    private func pendingRange(
        from startTime: TimeInterval,
        to currentTime: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        let blocks = model.motionTimelineBlocks
        let lowerLimit = blocks
            .filter { $0.editorEnd <= startTime }
            .map(\.editorEnd)
            .max() ?? 0
        let upperLimit = blocks
            .filter { $0.editorStart >= startTime }
            .map(\.editorStart)
            .min() ?? model.duration
        let low = max(min(startTime, currentTime), lowerLimit)
        let high = min(max(startTime, currentTime), upperLimit)
        return low...max(low, high)
    }

    private var visibleBlocks: [RecordingMotionTimelineBlock] {
        model.motionTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

private struct StudioMotionCueBlock: View {
    @Bindable var model: RecordingStudioModel
    let block: RecordingMotionTimelineBlock
    let scale: StudioTimelineScale

    private struct DragBase {
        let cue: RecordingMotionCue
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    @State private var dragBase: DragBase?

    private var isSelected: Bool {
        model.selectedMotionCueID == block.cue.id
    }

    static let tint = Color.indigo

    var body: some View {
        guard scale.pointsPerSecond > 0 else { return AnyView(EmptyView()) }

        let cue = block.cue
        let blockDuration = max(block.editorEnd - block.editorStart, 0.0001)
        let width = min(
            scale.contentWidth,
            max(24, CGFloat(blockDuration) * scale.pointsPerSecond)
        )
        let x = min(
            max(scale.x(for: block.editorStart), 0),
            max(0, scale.contentWidth - width)
        )
        // The ramps use the transitions as they will actually play.
        let segment = RecordingMotionTimeline.segment(for: cue, clipTimeline: model.clipTimeline)
        let enterWidth = width * CGFloat((segment?.enter ?? 0) / blockDuration)
        let exitWidth = width * CGFloat((segment?.exit ?? 0) / blockDuration)
        let opacity = cue.isEnabled ? (isSelected ? 0.95 : 0.72) : 0.3

        return AnyView(
            HStack(spacing: 0) {
                resizeHandle(edge: .leading)
                Spacer(minLength: 0)
                if width >= StudioZoomLaneMetrics.minimumLabelledBlockWidth {
                    Label(cue.title, systemImage: cue.isEnabled ? "rotate.3d" : "eye.slash")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                resizeHandle(edge: .trailing)
            }
            .frame(width: width, height: StudioZoomLaneMetrics.blockHeight)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(
                        cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                        style: .continuous
                    )
                        .fill(Self.tint.opacity(opacity))
                    // Entrance and exit ramps, lighter than the hold.
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [Color.white.opacity(0.32), Color.white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(0, enterWidth))
                        Spacer(minLength: 0)
                        LinearGradient(
                            colors: [Color.white.opacity(0), Color.white.opacity(0.32)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(0, exitWidth))
                    }
                    .clipShape(RoundedRectangle(
                        cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                        style: .continuous
                    ))
                }
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: StudioZoomLaneMetrics.selectionRingCornerRadius,
                        style: .continuous
                    )
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        .padding(-StudioZoomLaneMetrics.selectionRingPadding)
                }
            }
            .offset(x: x, y: StudioZoomLaneMetrics.blockInset)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginMotionEdit()
                            model.selectMotionCue(id: cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var moved = dragBase.cue
                        let length = dragBase.cue.duration
                        let baseBlockDuration = dragBase.editorEnd - dragBase.editorStart
                        let editorStart = min(
                            max(0, dragBase.editorStart + delta),
                            max(0, model.duration - baseBlockDuration)
                        )
                        moved.start = min(
                            max(0, model.sourceTime(atEditorTime: editorStart)),
                            max(0, model.sourceDuration - length)
                        )
                        moved.end = min(model.sourceDuration, moved.start + length)
                        model.moveMotionCue(moved)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endMotionEdit(actionName: String(localized: "Move Motion"))
                    }
            )
            .onTapGesture(count: 2) {
                model.beginPoseAdjustment(.cue(cue.id))
            }
            .onTapGesture {
                model.selectMotionCue(id: cue.id)
            }
            .contextMenu {
                Button("Adjust on Canvas") {
                    model.beginPoseAdjustment(.cue(cue.id))
                }
                Button(cue.isEnabled ? "Disable Motion" : "Enable Motion") {
                    var updated = cue
                    updated.isEnabled.toggle()
                    model.updateMotionCue(updated)
                }
                Button("Duplicate Motion") {
                    model.duplicateMotionCue(id: cue.id)
                }
                Divider()
                Button("Remove Motion", role: .destructive) {
                    model.removeMotionCue(id: cue.id)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(cue.title))
            .accessibilityValue(Text(cue.isEnabled ? "On" : "Off"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selectMotionCue(id: cue.id) }
        )
    }

    private func resizeHandle(edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10, height: StudioZoomLaneMetrics.blockHeight)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(Color.white.opacity(isSelected ? 0.9 : 0.45))
                    .frame(width: 2.5, height: 12)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: block.cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginMotionEdit()
                            model.selectMotionCue(id: block.cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var resized = dragBase.cue
                        switch edge {
                        case .leading:
                            let sourceTime = model.sourceTime(atEditorTime: dragBase.editorStart + delta)
                            resized.start = min(
                                max(0, sourceTime),
                                dragBase.cue.end - RecordingMotionCue.minimumDuration
                            )
                        case .trailing:
                            let sourceTime = model.sourceTime(atEditorTime: dragBase.editorEnd + delta)
                            resized.end = max(
                                dragBase.cue.start + RecordingMotionCue.minimumDuration,
                                min(model.sourceDuration, sourceTime)
                            )
                        }
                        model.updateMotionCue(resized)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endMotionEdit(actionName: String(localized: "Resize Motion"))
                    }
            )
    }
}

// MARK: - Inspector

private extension ZoomAnchorMode {
    var inspectorTitle: String {
        switch self {
        case .pointerAnchor: String(localized: "Pointer")
        case .smartAnchor: String(localized: "Smart")
        case .pinnedAnchor: String(localized: "Fixed")
        }
    }
}

/// The Studio inspector splits by what a setting changes: the frame the video
/// sits in, timed camera effects, things drawn over the video, and the cut
/// and its sound.
/// Cutting lives on the timeline itself, so the inspector's tabs cover only
/// what the timeline can't show: the look, motion, overlays and sound.
private enum StudioInspectorTab: Hashable, CaseIterable {
    case canvas
    case animation
    case overlays
    case audio

    var title: String {
        switch self {
        case .canvas: String(localized: "Canvas")
        case .animation: String(localized: "Animation")
        case .overlays: String(localized: "Overlays")
        case .audio: String(localized: "Audio")
        }
    }
}

/// Aspect choice drawn as its frame shape over the ratio, so the options
/// read at a glance.
private struct AspectPresetLabel: View {
    let preset: ExportAspectPreset
    let sourceSize: CGSize

    private static let box: CGFloat = 16

    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(lineWidth: 1.2)
                .frame(width: shapeSize.width, height: shapeSize.height)
                .frame(width: Self.box + 4, height: Self.box)
            Text(preset.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var shapeSize: CGSize {
        let ratio = preset.ratio
            ?? (sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 16.0 / 10.0)
        let box = Self.box
        return ratio >= 1
            ? CGSize(width: box + 4, height: (box + 4) / ratio)
            : CGSize(width: box * ratio, height: box)
    }
}

private struct StudioInspector: View {
    /// Whole-number playback rates offered for a clip, within
    /// `RecordingClipSegment`'s 1...8 range.
    private static let clipSpeedPresets: [Double] = [1, 2, 3, 4, 6, 8]

    @Bindable var model: RecordingStudioModel
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var stylePresetStore = RecordingStudioStylePresetStore.shared
    @State private var selectedTab: StudioInspectorTab = .canvas
    @State private var showsBasePoseControls = false
    @State private var isAudioExportOptionsPresented = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// Whatever the timeline has selected, for scrolling its controls in.
    private var selectionKey: UUID? {
        model.selectedCueID ?? model.selectedMotionCueID ?? model.selectedClipID
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                selectionSection

                switch selectedTab {
                case .canvas:
                    canvasTab
                case .animation:
                    animationTab
                case .overlays:
                    overlaysTab
                case .audio:
                    audioTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, PreviewPeekTab.pillHeight * 1.1)
        }
        .scrollPosition($scrollPosition)
        // A timeline selection is edited above whichever tab is open; bring
        // it into view even when the panel was scrolled down.
        .onChange(of: selectionKey) { _, key in
            guard key != nil else { return }
            scrollToTop(animated: true)
        }
        .onChange(of: model.activePoseAdjustment) { _, target in
            if target != nil {
                selectedTab = .animation
            }
        }
        .onChange(of: selectedTab) { _, _ in
            scrollToTop(animated: false)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // Presets span the Canvas and Overlays tabs, so they sit above both.
                RecordingStudioStylePresetBar(model: model, presetStore: stylePresetStore)

                tabPicker

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 0.5)
            }
            .background(sidebarBackground)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .background(sidebarBackground)
        .inspectorColumnWidth(
            min: InspectorMetrics.columnMinWidth,
            ideal: InspectorMetrics.columnIdealWidth,
            max: InspectorMetrics.columnMaxWidth
        )
        .frame(
            minWidth: InspectorMetrics.columnMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task {
            await wallpaperStore.reload()
        }
    }

    private var tabPicker: some View {
        InspectorSegmented(
            options: StudioInspectorTab.allCases,
            isSelected: { $0 == selectedTab },
            onTap: { selectedTab = $0 },
            label: { tab in
                Text(tab.title)
                    .font(.inspectorSegment)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        )
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private func scrollToTop(animated: Bool) {
        if animated, !accessibilityReduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .top)
            }
        } else {
            scrollPosition.scrollTo(edge: .top)
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private var canvasTab: some View {
        InspectorSection(
            title: "Composition",
            accessory: {
                if !usesDefaultComposition {
                    InspectorResetButton(help: "Reset composition") {
                        model.exportAspect = .original
                        model.exportAspectMode = .fill
                        model.style.padding = RecordingStudioStyle().padding
                    }
                }
            }
        ) {
            compositionControls
        }

        InspectorSectionDivider()

        InspectorSection("Background") {
            backgroundControls
        }

        InspectorSectionDivider()

        InspectorSection(
            title: "Video Card",
            accessory: {
                if !usesDefaultVideoCard {
                    InspectorResetButton(help: "Reset video card") {
                        let defaults = RecordingStudioStyle()
                        model.style.cornerRadius = defaults.cornerRadius
                        model.style.shadow = defaults.shadow
                    }
                }
            }
        ) {
            videoCardControls
        }
    }

    @ViewBuilder
    private var animationTab: some View {
        InspectorSection(
            title: "Zoom",
            accessory: {
                InspectorToggle("Enable zooms", isOn: $model.zoomEnabled)
            }
        ) {
            if model.zoomEnabled {
                zoomControls
            }
        }

        InspectorSectionDivider()

        InspectorSection(
            title: "3D Motion",
            accessory: {
                InspectorToggle("Enable 3D motion", isOn: $model.motionEnabled)
            }
        ) {
            if model.motionEnabled {
                cardMotionControls
            }
        }
    }

    /// Whatever is selected on the timeline, edited above the open tab and
    /// marked with its lane's colour so it reads as the selected block.
    @ViewBuilder
    private var selectionSection: some View {
        if model.selectedCue != nil || model.selectedMotionCue != nil || model.selectedClip != nil {
            VStack(alignment: .leading, spacing: 0) {
                selectionControls
            }
            .background(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(selectionTint)
                    .frame(width: 3)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 0.5)
            }
        }
    }

    private var selectionTint: Color {
        if model.selectedCue != nil { return .accentColor }
        if model.selectedMotionCue != nil { return StudioMotionCueBlock.tint }
        return .secondary
    }

    @ViewBuilder
    private var selectionControls: some View {
        if let selected = model.selectedCue {
            InspectorSection(
                title: "Selected Zoom",
                accessory: {
                    InspectorToggle(
                        "Use this zoom",
                        isOn: Binding(
                            get: { selected.isEnabled },
                            set: { isEnabled in
                                var updated = selected
                                updated.isEnabled = isEnabled
                                model.updateZoomCue(updated)
                            }
                        )
                    )
                }
            ) {
                selectedZoomControls(for: selected)
            }
        } else if let selectedMotion = model.selectedMotionCue {
            InspectorSection(
                title: "Selected Motion",
                accessory: {
                    InspectorToggle(
                        "Use this motion",
                        isOn: Binding(
                            get: { selectedMotion.isEnabled },
                            set: { isEnabled in
                                var updated = selectedMotion
                                updated.isEnabled = isEnabled
                                model.updateMotionCue(updated)
                            }
                        )
                    )
                }
            ) {
                selectedMotionControls(for: selectedMotion)
            }
        } else if let selectedClip = model.selectedClip {
            InspectorSection("Selected Clip") {
                selectedClipControls(for: selectedClip)
            }
        }
    }

    @ViewBuilder
    private var overlaysTab: some View {
        if !hasOverlays {
            InspectorSection("Overlays") {
                InspectorHint("This recording has no pointer, keystrokes, narration or camera to show.")
            }
        }

        if model.pointerIsSynthesized {
            InspectorSection(
                title: "Cursor",
                accessory: {
                    HStack(spacing: 5) {
                        if model.style.cursorScale != RecordingStudioStyle.defaultCursorScale {
                            InspectorResetButton(help: "Reset cursor size") {
                                model.style.cursorScale = RecordingStudioStyle.defaultCursorScale
                            }
                        }
                        InspectorToggle(
                            "Show mouse pointer",
                            isOn: Binding(
                                get: { !model.style.hidesCursor },
                                set: { model.style.hidesCursor = !$0 }
                            )
                        )
                    }
                }
            ) {
                if !model.style.hidesCursor {
                    cursorControls
                }
            }
            InspectorSectionDivider()
        }

        if model.hasKeystrokes {
            InspectorSection(
                title: "Keystrokes",
                accessory: {
                    InspectorToggle("Show keystrokes", isOn: $model.showsKeystrokes)
                }
            ) {
                if model.showsKeystrokes {
                    keystrokeControls
                }
            }
            InspectorSectionDivider()
        }

        if model.canTranscribe || model.hasSubtitles {
            InspectorSection(
                title: "Captions",
                accessory: {
                    if model.transcriptionState.isTranscribing {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                    } else if model.hasSubtitles {
                        InspectorToggle("Show subtitles", isOn: $model.showsSubtitles)
                    }
                }
            ) {
                captionSectionControls
            }
            InspectorSectionDivider()
        }

        if model.hasCameraVideo {
            InspectorSection(
                title: "Camera",
                accessory: {
                    InspectorToggle("Show camera", isOn: $model.style.camera.isVisible)
                }
            ) {
                if model.style.camera.isVisible {
                    cameraControls
                }
            }
        }
    }

    @ViewBuilder
    private var audioTab: some View {
        if model.canTranscribe || model.hasSubtitles {
            InspectorSection("Edit by Text") {
                editByTextControls
            }
            InspectorSectionDivider()
        }

        InspectorSection(
            title: "Audio",
            accessory: {
                if model.replacementAudio != nil {
                    if model.hasRecordedAudio {
                        InspectorResetButton(help: "Use the recorded audio again") {
                            model.removeReplacementAudio()
                        }
                    } else {
                        InspectorClearButton(help: "Remove this audio") {
                            model.removeReplacementAudio()
                        }
                    }
                }
            }
        ) {
            audioControls
        }
    }

    private var hasOverlays: Bool {
        model.pointerIsSynthesized
            || model.hasKeystrokes
            || model.canTranscribe
            || model.hasSubtitles
            || model.hasCameraVideo
    }

    // MARK: Background

    private var compositionControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorSegmented(
                    options: ExportAspectPreset.allCases,
                    isSelected: { $0 == model.exportAspect },
                    onTap: { model.exportAspect = $0 },
                    label: { preset in
                        AspectPresetLabel(preset: preset, sourceSize: model.videoSize)
                            .help(preset.help)
                    },
                    height: 42
                )
                .accessibilityLabel("Aspect ratio")

                if model.exportAspect != .original {
                    InspectorSegmented(
                        options: ExportAspectContentMode.allCases,
                        isSelected: { $0 == model.exportAspectMode },
                        onTap: { model.exportAspectMode = $0 },
                        label: { mode in
                            Text(mode.title)
                                .font(.inspectorSegment)
                                .help(mode.help)
                        }
                    )
                }
            }

            InspectorSlider(
                "Padding",
                value: $model.style.padding,
                range: 0...0.18,
                format: .percent()
            )
        }
    }

    private var backgroundControls: some View {
        InspectorBackgroundFillPicker(
            style: $model.style.background,
            rememberedWallpaper: nil,
            wallpaperStore: wallpaperStore,
            onEditorAction: {},
            onPickWallpaper: pickWallpaper,
            showsNoneTile: true
        )
    }

    private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = String(localized: "Choose Video Background Wallpaper")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            wallpaperStore.addRecentWallpaper(url)
            model.style.background = .customWallpaper(AnnotationCustomWallpaper(url: url))
        }
    }

    // MARK: Video card

    private var videoCardControls: some View {
        InspectorFieldPair {
            InspectorSlider(
                "Corners",
                value: $model.style.cornerRadius,
                range: 0...0.08,
                format: .percent()
            )
        } trailing: {
            InspectorSlider(
                "Shadow",
                value: $model.style.shadow,
                range: 0...1,
                format: .percent()
            )
        }
    }

    // MARK: Zoom

    private var zoomControls: some View {
        let pressCount = model.recordedPressTimes.count
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                InspectorActionButton("Auto Zoom", systemImage: "pointer.arrow.rays") {
                    model.resynthesizeZoomCues()
                }
                .disabled(pressCount == 0)
                .help(autoZoomHelp(pressCount: pressCount))

                InspectorActionButton("Add Zoom", systemImage: "plus.magnifyingglass") {
                    model.addZoomCue(at: model.currentTime)
                }
                .help("Add a zoom at the playhead, or drag across the zoom lane")
            }

            if model.zoomCues.isEmpty {
                InspectorHint(
                    pressCount > 0
                        ? "Auto Zoom turns your recorded clicks into camera moves."
                        : "Drag across the zoom lane on the timeline to add a zoom."
                )
            }
        }
    }

    private func selectedZoomControls(for selected: ZoomCue) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Camera focus")

                InspectorSegmented(
                    options: ZoomAnchorMode.allCases,
                    isSelected: { $0 == selected.anchorMode },
                    onTap: { anchorMode in
                        var updated = selected
                        updated.anchorMode = anchorMode
                        if anchorMode == .pinnedAnchor,
                           let pointer = model.pointerLocation(at: model.currentTime) {
                            updated.pinnedPoint = pointer
                        }
                        model.updateZoomCue(updated)
                    },
                    label: { Text($0.inspectorTitle).font(.inspectorSegment) }
                )
            }

            if selected.anchorMode == .pinnedAnchor {
                zoomAmountSlider(for: selected)

                VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                    HStack(spacing: 8) {
                        InspectorGroupLabel("Target position")
                        Spacer(minLength: 0)
                        Text(zoomTargetPositionText(selected.pinnedPoint))
                            .font(.inspectorNumeric)
                            .foregroundStyle(.tertiary)
                    }

                    RecordingZoomFocusPad(
                        position: Binding(
                            get: { selected.pinnedPoint },
                            set: { target in
                                var updated = selected
                                updated.pinnedPoint = target
                                model.updateZoomCue(updated)
                            }
                        ),
                        magnification: selected.zoom
                    )
                }
            } else {
                InspectorFieldPair {
                    zoomAmountSlider(for: selected)
                } trailing: {
                    InspectorSlider(
                        "Edge",
                        value: Binding(
                            get: { CGFloat(selected.boundsBias) },
                            set: { boundsBias in
                                var updated = selected
                                updated.boundsBias = Double(boundsBias)
                                model.updateZoomCue(updated)
                            }
                        ),
                        range: 0...1,
                        format: .percent()
                    )
                    .help("How much of the frame's edge stays in view while zoomed")
                }
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if selected.anchorMode == .pinnedAnchor {
                    InspectorActionButton("Target Pointer", systemImage: "scope") {
                        guard let pointer = model.pointerLocation(at: model.currentTime) else { return }
                        var updated = selected
                        updated.pinnedPoint = pointer
                        model.updateZoomCue(updated)
                    }
                    .help("Aim the zoom at the pointer's position under the playhead")
                }

                InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                    model.removeZoomCue(id: selected.id)
                }
                .help("Remove the selected zoom")
            }
        }
        .disabled(!model.zoomEnabled)
        .opacity(model.zoomEnabled ? 1 : 0.48)
    }

    private func zoomAmountSlider(for selected: ZoomCue) -> some View {
        InspectorSlider(
            "Zoom",
            value: Binding(
                get: { CGFloat(selected.zoom) },
                set: { newValue in
                    var updated = selected
                    updated.zoom = Double(newValue)
                    model.updateZoomCue(updated)
                }
            ),
            range: 1.1...3,
            format: .magnification(fractionDigits: 1)
        )
    }

    private func zoomTargetPositionText(_ position: CGPoint) -> String {
        let x = Int((position.x * 100).rounded())
        let y = Int((position.y * 100).rounded())
        return "\(x), \(y)"
    }

    // MARK: 3D motion

    private static let secondsFormat = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 1,
        suffix: " s",
        showsPositiveSign: false,
        step: 0.1,
        acceptedSuffixes: ["seconds", "second", "sec", "s"]
    )

    private var cardMotionControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                adjustOnCanvasButton(for: .base)

                InspectorActionButton("Fit to Canvas", systemImage: "arrow.down.right.and.arrow.up.left") {
                    model.fitMotionToCanvas()
                }
                .disabled(!model.motionExceedsCanvas)
                .help("Scale the base pose and every motion so the card stays inside the canvas")
            }

            if model.motionExceedsCanvas {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Part of the card reaches past the canvas and will be cropped.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.inspectorLabel)
                .accessibilityElement(children: .combine)
            }

            basePoseDisclosure

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Add motion at playhead")
                InspectorSegmented(
                    options: RecordingMotionPreset.allCases,
                    isSelected: { _ in false },
                    onTap: { preset in
                        model.addMotionCue(preset: preset, at: model.currentTime)
                    },
                    label: { preset in
                        Image(systemName: preset.systemImage)
                            .font(.inspectorSegment)
                            .help(preset.title)
                            .accessibilityLabel(Text(preset.title))
                    }
                )
            }
        }
    }

    /// The base pose sliders fold away: most edits happen on the canvas or
    /// through motions, so they stay one click from view.
    private var basePoseDisclosure: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.18)) {
                        showsBasePoseControls.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsBasePoseControls ? 90 : 0))
                            .frame(width: 12)
                        InspectorGroupLabel("Base pose")
                        Text(model.motion.basePose.isIdentity ? String(localized: "Flat") : String(localized: "Tilted"))
                            .font(.inspectorLabel)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Base pose")
                .accessibilityValue(showsBasePoseControls ? Text("Expanded") : Text("Collapsed"))

                if !model.motion.basePose.isIdentity {
                    InspectorResetButton(help: "Reset Pose") {
                        model.resetMotionBasePose()
                    }
                }
            }

            if showsBasePoseControls {
                poseControls(current: { model.motionBasePose }) { pose in
                    model.motionBasePose = pose
                }
                .transition(.opacity)
            }
        }
    }

    private func selectedMotionControls(for cue: RecordingMotionCue) -> some View {
        let segment = model.selectedMotionSegment
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Preset")
                InspectorSegmented(
                    options: RecordingMotionPreset.allCases,
                    isSelected: { $0 == cue.preset },
                    onTap: { model.applyMotionPreset($0, toCueID: cue.id) },
                    label: { preset in
                        Image(systemName: preset.systemImage)
                            .font(.inspectorSegment)
                            .help(preset.title)
                            .accessibilityLabel(Text(preset.title))
                    }
                )
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Target pose")
                adjustOnCanvasButton(for: .cue(cue.id))
                poseControls(current: { currentMotionCue(id: cue.id)?.targetPose ?? cue.targetPose }) { pose in
                    guard var updated = currentMotionCue(id: cue.id) else { return }
                    updated.targetPose = pose
                    updated.preset = nil
                    model.updateMotionCue(updated, coalesces: true)
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Timing")
                InspectorFieldPair {
                    motionTimingSlider("In", cue: cue, keyPath: \.enterDuration)
                } trailing: {
                    motionTimingSlider("Out", cue: cue, keyPath: \.exitDuration)
                }
                if let segment {
                    Text(motionTimingSummary(cue: cue, segment: segment))
                        .font(.inspectorLabel)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                InspectorActionButton("Duplicate", systemImage: "plus.square.on.square") {
                    model.duplicateMotionCue(id: cue.id)
                }
                .help("Copy this motion into the next free space")

                InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                    model.removeMotionCue(id: cue.id)
                }
                .help("Remove the selected motion")
            }
        }
        .disabled(!model.motionEnabled)
        .opacity(model.motionEnabled ? 1 : 0.48)
    }

    /// Toggles direct manipulation of a pose on the canvas.
    private func adjustOnCanvasButton(for target: RecordingPoseAdjustmentTarget) -> some View {
        let isActive = model.activePoseAdjustment == target
        return InspectorActionButton(
            isActive ? "Done Adjusting" : "Adjust on Canvas",
            systemImage: isActive ? "checkmark" : "rotate.3d"
        ) {
            if isActive {
                model.endPoseAdjustment()
            } else {
                model.beginPoseAdjustment(target)
            }
        }
        .help(isActive
            ? "Finish adjusting the pose on the canvas (Esc)"
            : "Drag the card on the canvas to turn, tilt, rotate, scale and move it")
    }

    private func currentMotionCue(id: UUID) -> RecordingMotionCue? {
        model.motion.cues.first { $0.id == id }
    }

    /// Hold length, and the transitions actually played when a cut or speed
    /// change left the cue shorter than its requested entrance and exit.
    private func motionTimingSummary(
        cue: RecordingMotionCue,
        segment: RecordingMotionTimeline.Segment
    ) -> String {
        let format = Self.secondsFormat
        let hold = max(0, segment.editorEnd - segment.editorStart - segment.enter - segment.exit)
        let holdText = String(localized: "Holds \(format.displayString(for: CGFloat(hold)))")
        let shortened = segment.enter < cue.enterDuration - 0.005 || segment.exit < cue.exitDuration - 0.005
        guard shortened else { return holdText }
        let inText = format.displayString(for: CGFloat(segment.enter))
        let outText = format.displayString(for: CGFloat(segment.exit))
        return String(localized: "Shortened to fit: in \(inText), out \(outText)")
    }

    private func motionTimingSlider(
        _ title: LocalizedStringResource,
        cue: RecordingMotionCue,
        keyPath: WritableKeyPath<RecordingMotionCue, TimeInterval>
    ) -> some View {
        let range = RecordingMotionCue.transitionRange
        return InspectorSlider(
            title,
            value: Binding(
                get: { CGFloat(cue[keyPath: keyPath]) },
                set: { newValue in
                    guard var updated = currentMotionCue(id: cue.id) else { return }
                    updated[keyPath: keyPath] = Double(newValue)
                    model.updateMotionCue(updated, coalesces: true)
                }
            ),
            range: CGFloat(range.lowerBound)...CGFloat(range.upperBound),
            format: Self.secondsFormat
        )
    }

    /// Turn, tilt, rotate, scale and offset for one pose. Reads the live pose
    /// on every change so scrubbing one value never resets another.
    private func poseControls(
        current: @escaping () -> RecordingCardPose,
        set: @escaping (RecordingCardPose) -> Void
    ) -> some View {
        let pose = current()
        func slider(
            _ title: LocalizedStringResource,
            _ keyPath: WritableKeyPath<RecordingCardPose, Double>,
            range: ClosedRange<Double>,
            format: InspectorValueFormat
        ) -> InspectorSlider {
            InspectorSlider(
                title,
                value: Binding(
                    get: { CGFloat(pose[keyPath: keyPath]) },
                    set: { newValue in
                        var updated = current()
                        updated[keyPath: keyPath] = Double(newValue)
                        set(updated)
                    }
                ),
                range: CGFloat(range.lowerBound)...CGFloat(range.upperBound),
                format: format
            )
        }

        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                slider("Turn", \.yawDegrees, range: RecordingCardPose.yawRange, format: .degrees(signed: true))
                    .help("Turn the card left or right")
            } trailing: {
                slider("Tilt", \.pitchDegrees, range: RecordingCardPose.pitchRange, format: .degrees(signed: true))
                    .help("Tilt the card toward or away from you")
            }
            InspectorFieldPair {
                slider("Rotate", \.rollDegrees, range: RecordingCardPose.rollRange, format: .degrees(signed: true))
                    .help("Rotate the card in the screen plane")
            } trailing: {
                slider("Scale", \.scale, range: RecordingCardPose.scaleRange, format: .percent())
                    .help("Card size, separate from zooms")
            }
            InspectorFieldPair {
                slider("X", \.translationX, range: RecordingCardPose.translationRange, format: .percent(signed: true))
                    .help("Horizontal offset, as a share of the canvas width")
            } trailing: {
                slider("Y", \.translationY, range: RecordingCardPose.translationRange, format: .percent(signed: true))
                    .help("Vertical offset, as a share of the canvas height")
            }
        }
    }

    // MARK: Selected clip

    private func selectedClipControls(for clip: RecordingClipSegment) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Speed")

                InspectorSegmented(
                    options: Self.clipSpeedPresets,
                    isSelected: { abs($0 - clip.speed) < 0.001 },
                    onTap: { model.setClipSpeed($0, forClipID: clip.id) },
                    label: { speed in
                        Text(InspectorValueFormat.magnification(fractionDigits: 0).displayString(for: speed))
                            .font(.inspectorSegment)
                    }
                )
                .help("Audio speeds up with the clip")
            }

            if model.canDeleteSelectedClip {
                InspectorActionButton("Delete Clip", systemImage: "trash", role: .destructive) {
                    model.deleteSelectedClip()
                }
                .help("Remove this part of the video")
            }
        }
    }

    // MARK: Cursor

    private var cursorControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Size",
                value: $model.style.cursorScale,
                range: 1...4,
                format: .magnification(fractionDigits: 1)
            )

            if model.canShowPressEffects {
                InspectorToggleRow("Click highlights", isOn: $model.showsClickEffects)
            }
        }
    }

    // MARK: Keystrokes

    private var keystrokeControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Top") {
                keystrokePlacementRow([.topLeft, .topCenter, .topRight])
            }
            InspectorRow("Bottom") {
                keystrokePlacementRow([.bottomLeft, .bottomCenter, .bottomRight])
            }
        }
        .help("Shortcuts you pressed while recording appear as a caption")
    }

    private func keystrokePlacementRow(
        _ options: [RecordingKeystrokePlacement]
    ) -> some View {
        InspectorSegmented(
            options: options,
            isSelected: { $0 == model.keystrokePlacement },
            onTap: { model.keystrokePlacement = $0 },
            label: { Text($0.title).font(.inspectorSegment) }
        )
    }

    // MARK: Transcription

    /// Transcribing, failed, or not yet transcribed: shared by Captions and
    /// Edit by Text, which both need a transcript.
    @ViewBuilder
    private var transcriptionStatus: some View {
        switch model.transcriptionState {
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                InspectorHint("Transcribing narration…")
            }
        case .failed(let message):
            InspectorHint(message, tint: .orange)

            InspectorActionButton("Try Again", systemImage: "waveform") {
                model.transcribe()
            }
        case .idle:
            InspectorActionButton("Transcribe Narration", systemImage: "waveform") {
                model.transcribe()
            }
            .help("Turn your microphone narration into subtitles, transcribed on this Mac")
        }
    }

    private var hasIdleTranscript: Bool {
        guard case .idle = model.transcriptionState else { return false }
        return model.hasSubtitles
    }

    private var captionSectionControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if hasIdleTranscript {
                if model.showsSubtitles {
                    captionControls
                }
                transcriptionActions
            } else {
                transcriptionStatus
            }
        }
    }

    private var editByTextControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if hasIdleTranscript {
                transcriptEditControls
            } else {
                transcriptionStatus
                InspectorHint("Transcribe the narration to cut the video by editing its text.")
            }
        }
    }

    private var transcriptionActions: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
            if model.canTranscribe {
                InspectorActionButton("Transcribe Again", systemImage: "arrow.clockwise") {
                    model.transcribe()
                }
            }

            InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                model.removeTranscription()
            }
            .help("Remove the subtitles")
        }
    }

    private var captionControls: some View {
        let verticalRange = SubtitleBarStyle.verticalRange
        let fontScaleRange = SubtitleBarStyle.fontScaleRange
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                InspectorSlider(
                    "Position",
                    value: Binding(
                        get: { CGFloat(model.subtitleStyle.verticalPosition) },
                        set: { model.subtitleStyle.verticalPosition = Double($0) }
                    ),
                    range: CGFloat(verticalRange.lowerBound)...CGFloat(verticalRange.upperBound),
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Size",
                    value: Binding(
                        get: { CGFloat(model.subtitleStyle.fontScale) },
                        set: { model.subtitleStyle.fontScale = Double($0) }
                    ),
                    range: CGFloat(fontScaleRange.lowerBound)...CGFloat(fontScaleRange.upperBound),
                    format: .magnification(fractionDigits: 1)
                )
            }

            if model.hasTranscriptWords {
                InspectorToggleRow(
                    "Highlight spoken word",
                    isOn: $model.subtitleStyle.highlightsSpokenWord
                )
            }

            subtitleList
                .help("Click a timestamp to jump there. Edit any line to fix the transcription.")
        }
    }

    @ViewBuilder
    private var transcriptEditControls: some View {
        if model.hasTranscriptWords {
            StudioTranscriptEditPanel(model: model)

            if model.removableFillerWordCount > 0 || model.trimmableSilenceCount > 0 {
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    if model.removableFillerWordCount > 0 {
                        InspectorActionButton(
                            "Fillers (\(model.removableFillerWordCount))",
                            systemImage: "scissors"
                        ) {
                            model.removeFillerWords()
                        }
                        .help("Cut every filler word, like “um” and “uh”")
                    }

                    if model.trimmableSilenceCount > 0 {
                        InspectorActionButton(
                            "Silences (\(model.trimmableSilenceCount))",
                            systemImage: "waveform.badge.minus"
                        ) {
                            model.trimNarrationSilences()
                        }
                        .help("Trim long pauses in the narration")
                    }
                }
            }

            InspectorHint("Click a word to jump there. Shift-click to select a passage, then cut it.")
        } else {
            InspectorHint("This transcription predates editing by text. Transcribe again to cut the video from its transcript.")
        }
    }

    private var subtitleList: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    let cues = model.subtitleCues
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        StudioSubtitleRow(
                            model: model,
                            cue: cue,
                            isActive: model.activeSubtitleCue?.id == cue.id
                        )
                        .id(cue.id)

                        if index < cues.count - 1 {
                            Divider()
                                .padding(.leading, 10)
                                .opacity(0.6)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
            .clipShape(shape)
            .onChange(of: model.activeSubtitleCue?.id) { _, activeID in
                // Follow playback through the list, but never yank the list
                // around while the user is scrubbing or editing.
                guard let activeID, model.isPlaying else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    // MARK: Camera

    private var cameraControls: some View {
        InspectorFieldPair {
            InspectorSlider(
                "Size",
                value: $model.style.camera.size,
                range: 0.12...0.45,
                format: .percent()
            )
        } trailing: {
            InspectorSlider(
                "Rounding",
                value: $model.style.camera.roundness,
                range: 0.05...0.5,
                format: .percent()
            )
        }
        .help("Drag the camera directly on the canvas to place it")
    }

    // MARK: Audio

    /// The round trip around tools that clean up speech but offer no API:
    /// write the cut's soundtrack out, run it through the tool, bring the
    /// result back in as the project's audio. Two buttons and a file chip -
    /// the explaining is left to tooltips.
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            // A silent recording has nothing to send out, but it can still
            // be given a soundtrack - so only the export half is withheld.
            if model.hasAudio {
                InspectorSlider("Volume", value: $model.audioVolume, range: 0...2, format: .percent())
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if model.hasAudio {
                    audioExportButton
                }

                InspectorActionButton(
                    model.hasRecordedAudio ? "Replace" : "Add",
                    systemImage: "waveform.badge.plus"
                ) {
                    pickReplacementAudio()
                }
                .help(
                    model.hasRecordedAudio
                        ? "Swap in an audio file, aligned to the start of the edited timeline"
                        : "Lay an audio file over this silent recording"
                )
            }

            if let replacement = model.replacementAudio {
                replacementChip(for: replacement)
            }

            if let message = model.replacementAudioError {
                InspectorHint(message, tint: .orange)
            }
        }
    }

    /// One button carrying the whole export state, so progress and results
    /// never cost the section an extra row. The format is asked for at export
    /// time, the same way video export asks for its options.
    @ViewBuilder
    private var audioExportButton: some View {
        switch model.audioExportState {
        case .idle:
            InspectorActionButton("Export…", systemImage: "arrow.down.circle") {
                isAudioExportOptionsPresented = true
            }
            .help("Export just the soundtrack of the current cut")
            .popover(isPresented: $isAudioExportOptionsPresented, arrowEdge: .bottom) {
                StudioAudioExportOptions(format: $model.audioExportFormat) {
                    isAudioExportOptionsPresented = false
                    model.exportAudio()
                }
            }
        case .exporting(let progress):
            audioExportChrome(help: String(localized: "Cancel")) {
                model.cancelAudioExport()
            } label: {
                StudioProgressRing(progress: progress, size: 12)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.inspectorValue.monospacedDigit())
                    .contentTransition(.numericText())
            }
        case .finished(let url):
            audioExportChrome(help: String(localized: "Reveal \(url.lastPathComponent) in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                Text("Reveal")
                    .font(.inspectorValue)
            }
        case .failed(let message):
            audioExportChrome(help: message) {
                model.exportAudio()
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                Text("Retry")
                    .font(.inspectorValue)
            }
        }
    }

    /// Matches `InspectorActionButton`'s chrome for the export button's
    /// non-idle states, which carry richer content than a symbol and a title.
    private func audioExportChrome<Label: View>(
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label()
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .inspectorField()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func replacementChip(for replacement: RecordingReplacementAudio) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text(replacement.displayName)
                .font(.inspectorValue)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let drift = model.replacementAudioDrift {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .help(
                        drift > 0
                            ? "Runs \(Self.spanText(drift)) longer than the cut - the tail is dropped"
                            : "Runs \(Self.spanText(-drift)) shorter than the cut - the end plays silent"
                    )
            }

            Text(Self.clockText(replacement.duration))
                .font(.inspectorLabel.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorField()
        .help(replacement.displayName)
    }

    private func pickReplacementAudio() {
        model.chooseReplacementAudio()
    }

    private static func clockText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Short spans read better in seconds than as 0:00 timecode.
    private static func spanText(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return value < 60 ? String(format: "%.1fs", value) : clockText(value)
    }

    private func autoZoomHelp(pressCount: Int) -> String {
        switch pressCount {
        case 0: String(localized: "No clicks were recorded")
        case 1: String(localized: "Turn the recorded click into smooth camera moves")
        default: String(localized: "Turn the \(pressCount) recorded clicks into smooth camera moves")
        }
    }

    // MARK: Helpers

    private var usesDefaultComposition: Bool {
        model.exportAspect == .original
            && model.exportAspectMode == .fill
            && abs(model.style.padding - RecordingStudioStyle().padding) < 0.0001
    }

    private var usesDefaultVideoCard: Bool {
        let defaults = RecordingStudioStyle()
        return abs(model.style.cornerRadius - defaults.cornerRadius) < 0.0001
            && abs(model.style.shadow - defaults.shadow) < 0.0001
    }

    private var sidebarBackground: Color {
        InspectorControlPalette.panelBackground(for: colorScheme)
    }

}

/// Asks for the soundtrack format at export time.
private struct StudioAudioExportOptions: View {
    @Binding var format: RecordingAudioFormat
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Text("Export Audio")
                .font(.inspectorSectionHeader)
                .padding(.bottom, 2)

            InspectorSegmented(
                options: RecordingAudioFormat.allCases,
                isSelected: { $0 == format },
                onTap: { format = $0 },
                label: { Text($0.title).font(.inspectorSegment) }
            )

            InspectorHint(
                format == .m4a
                    ? "Compact AAC audio, accepted by most enhancement tools."
                    : "Uncompressed, for tools that accept nothing else."
            )

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export", action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(InspectorMetrics.horizontalPadding)
        .frame(width: 240)
        .presentationBackground(InspectorControlPalette.panelBackground(for: colorScheme))
    }
}

private extension RecordingStudioModel {
    /// Asks for a sound file to play instead of the recorded audio; shared by
    /// the Audio inspector and the timeline's Add Track menu.
    func chooseReplacementAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingAudioFormat.importContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = String(localized: "Choose Replacement Audio")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.replaceAudio(with: url)
        }
    }
}

