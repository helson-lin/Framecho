//
//  AnnotationEditorWindow.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnotationEditorWindow: View {
    @Binding var url: URL?

    @State private var model = AnnotationEditorModel()
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var backgroundPresetStore = AnnotationBackgroundPresetStore.shared
    @State private var isInspectorPresented = true
    @State private var isFinishing = false
    @State private var isSaving = false
    @State private var isUploading = false
    @State private var closeGuard = EditorCloseGuard()
    @State private var didCopyLink = false
    @State private var isCopying = false
    @State private var didCopyImage = false
    @State private var isShowingUploadOptions = false
    /// What Retry on the error banner repeats, and the message it belongs
    /// to: an error raised elsewhere afterwards must not inherit it.
    @State private var retryAction: (() -> Void)?
    @State private var retryMessage: String?
    @FocusState private var focusedField: AnnotationEditorFocusedField?
    @Environment(\.dismiss) private var dismissWindow

    private var isBusy: Bool { isSaving || isFinishing || isUploading || model.isCommitting }

    var body: some View {
        mainContent
            .disabled(model.isCommitting)
            .allowsHitTesting(!model.isCommitting)
            .modifier(CaptureLibraryEditorRegistration(url: url))
            .navigationTitle(windowTitle)
            .navigationSubtitle(windowSubtitle)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isCropping {
                        cropActions
                    } else {
                        editingActions.disabled(isBusy)
                    }
                }
            }
            .task(id: url) {
                clearInspectorFocus()
                model.load(url: url, dismiss: dismissWindow)
            }
            .onAppear {
                Task { await wallpaperStore.reload() }
                AnnotationEditorActivationPolicy.enter(hidePreview: true)
            }
            .onDisappear {
                closeGuard.detach()
                model.releaseEditorResources()
                AnnotationEditorActivationPolicy.leave(restorePreview: true)
            }
            .onWindowChange { window in
                guard let window else {
                    closeGuard.detach()
                    return
                }
                configureCloseGuard()
                closeGuard.attach(to: window)
                closeGuard.refreshDocumentEdited()
            }
            .onDeleteCommand {
                if !model.isCommitting { model.deleteSelectedAnnotation() }
            }
            .onChange(of: model.hasUnsavedChanges) { _, _ in
                closeGuard.refreshDocumentEdited()
            }
            .onChange(of: model.revision) { _, _ in
                closeGuard.refreshDocumentEdited()
                if didCopyLink { withAnimation(.snappy(duration: 0.2)) { didCopyLink = false } }
            }
            .onChange(of: model.backgroundSettings) { _, _ in
                closeGuard.refreshDocumentEdited()
                if didCopyLink { withAnimation(.snappy(duration: 0.2)) { didCopyLink = false } }
            }
            .onChange(of: model.baseImageURL) { _, _ in
                // Cropping replaces the base image rather than touching the
                // engine, so it never bumps `revision`.
                closeGuard.refreshDocumentEdited()
            }
            .background(AnnotationKeyCommandHandler(
                isEnabled: { !model.isCommitting },
                onDelete: model.deleteSelectedAnnotation,
                onSave: saveEdits,
                onSaveAs: saveAs,
                onCopy: copyImage,
                onUndo: model.undo,
                onRedo: model.redo,
                onSelectAll: model.selectAllAnnotations,
                onSelectTool: model.selectTool,
                onZoomIn: model.zoomIn,
                onZoomOut: model.zoomOut,
                onFitCanvas: model.fitCanvas,
                onActualSize: { model.setZoomPercent(100) },
                onToggleCrop: { withAnimation(.snappy(duration: 0.2)) { model.toggleCropping() } },
                onApplyCrop: { withAnimation(.snappy(duration: 0.2)) { model.applyCrop() } },
                onCancelCrop: { withAnimation(.snappy(duration: 0.2)) { model.cancelCrop() } },
                isCropping: { model.isCropping }
            ))
            .inspector(isPresented: $isInspectorPresented) {
                AnnotationEditorInspector(
                    model: model,
                    wallpaperStore: wallpaperStore,
                    backgroundPresetStore: backgroundPresetStore,
                    focusedField: $focusedField,
                    onEditorAction: clearInspectorFocus,
                    onPickWallpaper: pickCustomWallpaper
                )
                .disabled(model.isCropping || model.isCommitting)
            }
    }

    // MARK: Toolbar actions

    /// The standard trailing actions shown when not cropping: Crop, the
    /// Share menu (upload, save, save as), Copy, then Done as the one
    /// prominent action.
    @ViewBuilder
    private var editingActions: some View {
        Button(action: enterCrop) {
            Label("Crop", systemImage: "crop")
                .labelStyle(.titleAndIcon)
        }
        .help("Crop the screenshot (⇧⌘C)")
        .disabled(model.previewImage == nil || model.imageSize == .zero)

        shareMenu

        Button(action: copyImage) {
            Group {
                if isCopying {
                    ProgressView().controlSize(.small)
                } else if didCopyImage {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .labelStyle(.titleAndIcon)
            .frame(minWidth: 64)
        }
        .help("Copy the image (⌘C)")
        .disabled(model.previewImage == nil || isCopying)

        Button(action: finishEditing) {
            Text("Done")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Save and close (⌘↩)")

        Button {
            clearInspectorFocus()
            isInspectorPresented.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
    }

    /// Saving, exporting and uploading, grouped behind one button. Its label
    /// carries the progress of whichever of them is running.
    private var shareMenu: some View {
        Menu {
            if CloudUploader.shared.isConfigured {
                Button {
                    clearInspectorFocus()
                    isShowingUploadOptions = true
                } label: {
                    Label("Upload and Copy Link…", systemImage: "icloud.and.arrow.up")
                }
                .disabled(isUploading)

                Divider()
            }

            Button(action: saveEdits) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.hasUnsavedChanges || isSaving || isFinishing)

            Button(action: saveAs) {
                Label("Save As…", systemImage: "square.and.arrow.down.on.square")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        } label: {
            Group {
                if isUploading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Uploading...")
                    }
                } else if isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else if didCopyLink {
                    Label("Link copied", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .help("Save, export or upload")
        .popover(isPresented: $isShowingUploadOptions, arrowEdge: .bottom) {
            CloudUploadOptionsPopover(
                suggestedTitle: model.sourceURL?.deletingPathExtension().lastPathComponent ?? "",
                onConfirm: uploadAnnotation
            )
        }
    }

    /// The file being edited, so several editor windows stay distinguishable.
    private var windowTitle: String {
        model.sourceURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Framecho Annotate")
    }

    /// "3854 × 2566 · Edited": the size the export will have.
    private var windowSubtitle: String {
        let size = model.canvasPixelSize
        guard size.width > 0, size.height > 0 else { return "" }
        let dimensions = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        return model.hasUnsavedChanges
            ? "\(dimensions) · \(String(localized: "Edited"))"
            : dimensions
    }

    /// The crop controls that replace the trailing actions while cropping.
    @ViewBuilder
    private var cropActions: some View {
        Menu {
            Picker("Aspect Ratio", selection: aspectBinding) {
                ForEach(CropAspectRatio.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.cropAspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
        .help("Aspect ratio")

        Button {
            clearInspectorFocus()
            withAnimation(.snappy(duration: 0.18)) { model.resetCrop() }
        } label: {
            Text("Reset").padding(.horizontal, 6)
        }
        .help("Reset the selection to the whole image")

        Button(action: exitCrop) {
            Text("Cancel").padding(.horizontal, 6)
        }
        .keyboardShortcut(.cancelAction)

        Button(action: applyCropAction) {
            Text("Crop").padding(.horizontal, 8)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
    }

    private var aspectBinding: Binding<CropAspectRatio> {
        Binding(
            get: { model.cropAspect },
            set: { newValue in
                clearInspectorFocus()
                withAnimation(.snappy(duration: 0.18)) { model.setCropAspect(newValue) }
            }
        )
    }

    private func enterCrop() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.beginCropping() }
    }

    private func exitCrop() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.cancelCrop() }
    }

    private func applyCropAction() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.applyCrop() }
    }

    private var mainContent: some View {
        ZStack {
            AnnotationEditorWorkspaceBackground()

            if let previewImage = model.previewImage, model.imageSize != .zero {
                AnnotationCanvas(
                    model: model,
                    image: previewImage,
                    onEditorInteraction: clearInspectorFocus
                )
                // A fitted image starts below the floating tool strip.
                .padding(.top, AnnotationToolStrip.reservedHeight)
            } else if let errorMessage = model.errorMessage {
                // A load failure (missing/unreadable source file, e.g. a stale
                // URL replayed by macOS window restoration) should never sit
                // behind an unexplained spinner with no way out.
                AnnotationLoadFailureView(message: errorMessage, onClose: closeAfterLoadFailure)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .clipped()
        .overlay(alignment: .top) {
            if model.previewImage != nil, model.imageSize != .zero, !model.isCropping {
                AnnotationToolStrip(selectedTool: model.selectedTool) { tool in
                    clearInspectorFocus()
                    model.selectTool(tool)
                }
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.previewImage != nil, model.imageSize != .zero {
                HStack(spacing: 8) {
                    AnnotationHistoryControl(model: model, onAction: clearInspectorFocus)
                        .disabled(model.isCropping)
                    AnnotationZoomControl(model: model)

                    if model.isPreviewDownscaled {
                        LowResolutionPreviewNotice()
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isCropping, model.imageSize != .zero {
                CropResolutionBadge(size: model.cropPixelSize)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
            }
        }
        .overlay(alignment: .top) {
            // Only inline saves/copies/uploads (which fail with an image
            // already on screen) land here; a load failure shows the
            // full-canvas state above instead of a second copy of the message.
            if let errorMessage = model.errorMessage, model.previewImage != nil {
                AnnotationErrorBanner(
                    message: errorMessage,
                    onRetry: (retryMessage == errorMessage ? retryAction : nil).map { retry in
                        {
                            dismissError()
                            retry()
                        }
                    },
                    onDismiss: dismissError
                )
                .padding(.horizontal, 24)
                // Below the tool strip.
                .padding(.top, 12 + AnnotationToolStrip.reservedHeight + 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.errorMessage)
    }

    private func closeAfterLoadFailure() {
        model.releaseEditorResources()
        dismissWindow()
    }

    /// Copies what the editor shows. Unsaved edits are rendered to a
    /// temporary file rather than saved, so Copy never commits anything.
    private func copyImage() {
        clearInspectorFocus()
        guard !isCopying, let sourceURL = model.sourceURL, model.previewImage != nil else { return }
        isCopying = true
        Task {
            defer { isCopying = false }
            do {
                let url = model.hasUnsavedChanges ? try await model.renderCurrentImage() : sourceURL
                try ScreenshotFileActions.copyImageToClipboard(from: url)
                withAnimation(.snappy(duration: 0.2)) { didCopyImage = true }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.snappy(duration: 0.2)) { didCopyImage = false }
            } catch {
                fail(String(localized: "Failed to copy the image: \(error.localizedDescription)"), retry: copyImage)
            }
        }
    }

    private func saveAs() {
        clearInspectorFocus()
        guard !isBusy, let sourceURL = model.sourceURL else { return }
        let baseURL = model.baseImageURL ?? sourceURL

        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: sourceURL)
        panel.canCreateDirectories = true
        panel.title = String(localized: "Save Annotated Screenshot")

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            Task {
                do {
                    try await AnnotationRenderer.renderInBackground(
                        sourceURL: baseURL,
                        shapes: model.shapes,
                        backgroundSettings: model.backgroundSettings,
                        destinationURL: destinationURL,
                        contentType: ScreenshotFileActions.exportContentType
                    )
                } catch {
                    fail(String(localized: "Failed to save annotation: \(error.localizedDescription)"), retry: saveAs)
                }
            }
        }
    }

    private func pickCustomWallpaper() {
        clearInspectorFocus()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = String(localized: "Choose Background Wallpaper")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let wallpaper = AnnotationCustomWallpaper(url: url)
            wallpaperStore.addRecentWallpaper(url)
            model.backgroundSettings.customWallpaper = wallpaper
            model.backgroundSettings.style = .customWallpaper(wallpaper)
        }
    }

    private func uploadAnnotation(options: CloudUploadOptions) {
        clearInspectorFocus()
        guard model.sourceURL != nil, !isBusy else { return }

        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                // Persist the current annotations first so the uploaded file
                // matches what's saved in history, then upload that file. The
                // editor stays open.
                guard let sourceURL = model.sourceURL else { return }
                let resultURL = try await model.commitEdits() ?? sourceURL

                _ = ScreenshotPreviewStack.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL
                )

                let result = try await CloudUploader.shared.upload(
                    itemID: UUID(),
                    fileURL: resultURL,
                    title: options.trimmedTitleOrNil
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                ScreenshotHistoryStore.shared.setCloudURL(for: resultURL, cloudURL: result.url)
                withAnimation(.snappy(duration: 0.2)) { didCopyLink = true }
            } catch {
                fail(String(localized: "Upload failed: \(error.localizedDescription)"), retry: { uploadAnnotation(options: options) })
            }
        }
    }

    /// Cmd-S. Commits without closing, so long editing sessions have a
    /// checkpoint that isn't "press Done and start over".
    private func saveEdits() {
        clearInspectorFocus()
        // Committing re-renders the composite, so a Cmd-S with nothing
        // changed should cost nothing.
        guard model.sourceURL != nil, model.hasUnsavedChanges, !isBusy else { return }

        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                guard let sourceURL = model.sourceURL,
                      let resultURL = try await model.commitEdits() else { return }
                _ = ScreenshotPreviewStack.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL
                )
            } catch {
                fail(String(localized: "Failed to save annotation: \(error.localizedDescription)"), retry: saveEdits)
            }
        }
    }

    private func finishEditing() {
        clearInspectorFocus()
        guard let sourceURL = model.sourceURL else {
            model.releaseEditorResources()
            dismissWindow()
            return
        }

        guard !isBusy else { return }

        isFinishing = true
        Task {
            do {
                if let resultURL = try await model.commitEdits() {
                    let updatedExistingPreview = ScreenshotPreviewStack.shared.applyAnnotation(
                        originalURL: sourceURL,
                        historyURL: resultURL
                    )
                    if !updatedExistingPreview {
                        PreviewPanelPresenter.shared.show(displayID: nil)
                    }
                }
                guard !model.hasUnsavedChanges else {
                    isFinishing = false
                    return
                }
                model.releaseEditorResources()
                dismissWindow()
            } catch {
                isFinishing = false
                fail(String(localized: "Failed to finish annotation: \(error.localizedDescription)"), retry: finishEditing)
            }
        }
    }

    private func configureCloseGuard() {
        closeGuard.canClose = { [weak model] in model?.isCommitting != true }
        closeGuard.hasUnsavedChanges = { [weak model] in model?.hasUnsavedChanges ?? false }
        // A screenshot is already in History whether or not it is annotated,
        // so there is no "delete the whole thing" case here.
        closeGuard.offersDelete = { false }
        closeGuard.projectName = { [weak model] in model?.sourceURL?.lastPathComponent ?? String(localized: "this screenshot") }
        // Capture only the model, not this view and its @State close guard.
        closeGuard.onDecision = { [weak model] decision, done in
            guard let model else { return }
            switch decision {
            case .save:
                Task {
                    do {
                        if let sourceURL = model.sourceURL,
                           let resultURL = try await model.commitEdits() {
                            _ = ScreenshotPreviewStack.shared.applyAnnotation(
                                originalURL: sourceURL,
                                historyURL: resultURL
                            )
                        }
                        guard !model.hasUnsavedChanges else { return }
                        model.releaseEditorResources()
                        done()
                    } catch {
                        model.errorMessage = String(localized: "Failed to save annotation: \(error.localizedDescription)")
                    }
                }
            case .discard:
                model.releaseEditorResources()
                done()
            case .delete, .cancel:
                break
            }
        }
    }

    private func clearInspectorFocus() {
        focusedField = nil
    }

    private func fail(_ message: String, retry: (() -> Void)?) {
        retryAction = retry
        retryMessage = message
        model.errorMessage = message
    }

    private func dismissError() {
        model.errorMessage = nil
        retryAction = nil
        retryMessage = nil
    }
}

private struct AnnotationLoadFailureView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
    }
}
