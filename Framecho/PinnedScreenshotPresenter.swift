//
//  PinnedScreenshotPresenter.swift
//  Framecho
//

import AppKit
import ImageIO
import SwiftUI

/// Pins a screenshot to the screen as a floating, always-on-top window the user
/// can keep around for reference while they work. Supports multiple pins.
@MainActor
final class PinnedScreenshotPresenter {
    static let shared = PinnedScreenshotPresenter()

    private var pins: [PinnedScreenshotController] = []

    private init() {}

    /// - Parameters:
    ///   - frame: Where on screen the pin goes, at that size: over the area
    ///     it was captured from. Cascaded from the centre when nil.
    ///   - editingCapture: Opens straight into annotating a fresh capture,
    ///     with the toolbar whose ✓ copies and closes.
    func pin(url: URL, frame: CGRect? = nil, editingCapture: Bool = false) {
        guard let controller = PinnedScreenshotController(url: url) else { return }
        controller.onClose = { [weak self, weak controller] in
            self?.pins.removeAll { $0 === controller }
        }
        if let frame {
            controller.show(in: frame)
        } else {
            controller.show(at: cascadedOrigin(for: controller.panel.frame.size))
        }
        pins.append(controller)
        // Selected straight away, so its keys work without a click first.
        controller.panel.makeKey()
        if editingCapture {
            controller.beginEditingCapture()
        }
    }

    /// Shows `url` as a pin translating its text where it was captured.
    /// - Parameter ownsFile: The capture was made only to be translated; the
    ///   pin deletes it unless 📌 keeps the result.
    func translate(url: URL, frame: CGRect? = nil, ownsFile: Bool = false) {
        guard let controller = PinnedScreenshotController(url: url) else {
            if ownsFile { try? FileManager.default.removeItem(at: url) }
            NSSound.beep()
            return
        }
        controller.onClose = { [weak self, weak controller] in
            self?.pins.removeAll { $0 === controller }
        }
        if let frame {
            controller.show(in: frame)
        } else {
            controller.show(at: cascadedOrigin(for: controller.panel.frame.size))
        }
        pins.append(controller)
        controller.panel.makeKey()
        controller.beginTranslating(.standalone(ownsFile: ownsFile))
    }

    /// Pins the newest screenshot in History, the one just taken.
    func pinLatestScreenshot() {
        guard let item = ScreenshotHistoryStore.shared.items.first(where: { !$0.isVideo }) else {
            NSSound.beep()
            return
        }
        pin(url: item.url)
    }

    /// Picks up annotations saved to `url`, wherever they were made.
    func reloadPins(showing url: URL) {
        for controller in pins where controller.pin.url == url {
            controller.reloadImage(from: url)
        }
    }

    private func cascadedOrigin(for size: NSSize) -> CGPoint {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 100, y: 100, width: 800, height: 600)
        let offset = CGFloat(pins.count % 8) * 28
        return CGPoint(
            x: visible.midX - size.width / 2 + offset,
            y: visible.midY - size.height / 2 - offset
        )
    }
}

// MARK: - Pin state

enum PinnedScreenshotFeedback: Equatable {
    /// Percent of the image's actual size.
    case zoom(Int)
    case opacity(Int)
    case recognizing
    case translating
    /// Something worth knowing that went fine, such as a copy.
    case note(String)
    /// Why a translation didn't happen.
    case message(String)
}

/// A pin showing a translation of its image, with its own toolbar. How it
/// was opened decides what ✕ and 📌 do.
@MainActor
struct PinnedTranslationMode {
    enum Entry: Equatable {
        /// Capture and Translate, or a preview card: ✕ closes the pin,
        /// ✓ copies and closes, 📌 keeps the result in History.
        /// `ownsFile` marks a capture made only for this, deleted on close.
        case standalone(ownsFile: Bool)
        /// An existing pin: ✕ goes back to its image, 📌 replaces it.
        case pinned
    }

    let model: ScreenshotTranslation
    let entry: Entry

    var isStandalone: Bool {
        if case .standalone = entry { true } else { false }
    }
}

/// What a pin's image view and its toolbar both show.
@MainActor
@Observable
final class PinnedScreenshot {
    fileprivate(set) var url: URL
    private(set) var image: NSImage
    /// Bumped when `image` is replaced, so Live Text analyses the new pixels.
    private(set) var imageRevision = 0
    /// The pin is the key window: its toolbar is up and keys act on it.
    fileprivate(set) var isSelected = false
    var isLiveTextActive = false
    var hasText = false
    fileprivate(set) var didCopy = false
    /// Shown briefly after a zoom or a change of opacity.
    fileprivate(set) var feedback: PinnedScreenshotFeedback?
    /// Mirrors the window's alpha, for the toolbar's opacity menu.
    fileprivate(set) var opacity: CGFloat = 1
    /// Present while annotating in place.
    fileprivate(set) var editor: AnnotationEditorModel?
    /// Annotating a capture just taken with Capture Area and Pin: one flat
    /// toolbar, where ✓ copies the result and closes the pin.
    fileprivate(set) var isEditingCapture = false
    /// Present while the capture is being translated in place.
    fileprivate(set) var translation: ScreenshotTranslation?
    /// Present while the pin shows a translation of its image.
    fileprivate(set) var translationMode: PinnedTranslationMode?
    /// Space is held: the original shows through the translation.
    fileprivate(set) var isPeekingOriginal = false

    init(url: URL, image: NSImage) {
        self.url = url
        self.image = image
    }

    fileprivate func replaceImage(_ image: NSImage, url: URL) {
        self.image = image
        self.url = url
        hasText = false
        imageRevision &+= 1
    }
}

// MARK: - Pin window

/// One pin: the image window, the toolbar that follows it, and its keys.
@MainActor
final class PinnedScreenshotController: NSObject, NSWindowDelegate {
    let pin: PinnedScreenshot
    let panel: PinnedPanel
    var onClose: (() -> Void)?

    private let toolbarPanel = PinnedToolbarPanel()
    private var pixelSize: CGSize
    private var keyMonitor: Any?
    private var copyFeedbackTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?

    private static let previewPixelSize: CGFloat = 1600
    private static let toolbarGap: CGFloat = 8

    init?(url: URL) {
        guard let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: Self.previewPixelSize) else {
            return nil
        }
        pixelSize = ScreenshotImageLoader.imageSize(at: url) ?? image.size
        pin = PinnedScreenshot(url: url, image: image)

        let contentSize = PinnedScreenshotGeometry.displaySize(
            forPixelSize: pixelSize,
            backingScale: NSScreen.main?.backingScaleFactor ?? 2
        )
        panel = PinnedPanel(contentRect: NSRect(origin: .zero, size: contentSize))
        panel.contentAspectRatio = contentSize
        super.init()

        panel.delegate = self
        panel.onZoom = { [weak self] factor, anchor in
            self?.zoom(by: factor, around: anchor, animated: false)
        }
        panel.onFade = { [weak self] delta in
            guard let self else { return }
            self.setOpacity(self.panel.alphaValue + delta)
        }
        panel.contentView = NSHostingView(rootView: PinnedScreenshotView(pin: pin, controller: self))
        toolbarPanel.setContent(PinnedScreenshotToolbar(pin: pin, controller: self)) { [weak self] in
            self?.layoutToolbar()
        }
        installKeyMonitor()
    }

    func show(at origin: CGPoint) {
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// Shows the pin at `frame`'s size rather than the usual one.
    func show(in frame: CGRect) {
        panel.contentAspectRatio = frame.size
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        copyFeedbackTask?.cancel()
        feedbackTask?.cancel()
        translationTask?.cancel()
        if case .standalone(ownsFile: true) = pin.translationMode?.entry {
            try? FileManager.default.removeItem(at: pin.url)
        }
        pin.translationMode = nil
        pin.editor?.releaseEditorResources()
        pin.editor = nil
        setToolbarVisible(false)
        panel.orderOut(nil)
        // Views hold the controller; dropping them breaks the cycle.
        panel.contentView = nil
        toolbarPanel.contentView = nil
        onClose?()
    }

    // MARK: Actions

    var menuEntries: [LiveTextMenuEntry] {
        [
            .action(String(localized: "Annotate"), { [weak self] in self?.beginAnnotating() }),
            .action(String(localized: "Open in Editor"), { [weak self] in self?.openInEditor() }),
            .separator,
            .action(String(localized: "Copy"), { [weak self] in self?.copyImage() }),
            .action(String(localized: "Copy Text from Image"), { [weak self] in self?.copyText() }),
            .action(String(localized: "Translate Image"), { [weak self] in self?.translate() }),
            .action(String(localized: "Save…"), { [weak self] in self?.save() }),
            .separator,
            .action(String(localized: "Zoom In (⌘+)"), { [weak self] in self?.zoom(by: Self.zoomStep) }),
            .action(String(localized: "Zoom Out (⌘−)"), { [weak self] in self?.zoom(by: 1 / Self.zoomStep) }),
            .action(String(localized: "Actual Size (⌘0)"), { [weak self] in self?.zoomToActualSize() }),
            .separator,
            .action(String(localized: "Close Pin"), { [weak self] in self?.close() }),
        ]
    }

    func copyImage() {
        do {
            try ScreenshotFileActions.copyPNGToClipboard(from: pin.url)
            showCopyFeedback()
        } catch {
            print("Failed to copy pinned screenshot: \(error)")
        }
    }

    func copyText() {
        let url = pin.url
        Task {
            await CaptureCoordinator.shared.copyRecognizedText(at: url, from: .image)
        }
    }

    func translate() {
        beginTranslating(.pinned)
    }

    func save() {
        let url = pin.url
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        savePanel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: url)
        savePanel.canCreateDirectories = true
        savePanel.title = String(localized: "Save Screenshot")
        savePanel.begin { response in
            guard response == .OK, let destURL = savePanel.url else { return }
            do {
                try ScreenshotFileActions.save(from: url, to: destURL)
            } catch {
                print("Failed to save pinned screenshot: \(error)")
            }
        }
    }

    func toggleLiveText() {
        pin.isLiveTextActive.toggle()
        updateToolbarVisibility()
    }

    func openInEditor() {
        PreviewPanelPresenter.shared.onAnnotate?(pin.url)
    }

    private func showCopyFeedback() {
        withAnimation { pin.didCopy = true }
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { self?.pin.didCopy = false }
        }
    }

    // MARK: Annotating

    /// Swaps the image for the annotation canvas, editing the same document
    /// the full editor uses, so either can pick up where the other left off.
    func beginAnnotating(with tool: AnnotationTool? = nil) {
        if let editor = pin.editor {
            if let tool { editor.selectTool(tool) }
            return
        }
        let editor = AnnotationEditorModel()
        editor.load(url: pin.url, appliesBackgroundPreset: false)
        guard editor.previewImage != nil, editor.imageSize != .zero else {
            editor.releaseEditorResources()
            NSSound.beep()
            return
        }
        if let tool { editor.selectTool(tool) }

        pin.isLiveTextActive = false
        pin.editor = editor
        panel.makeKey()
        updateToolbarVisibility()
    }

    // MARK: Translating

    /// Shows the image translated where it is. The original shows first and
    /// the translation fades in over it; progress and errors use the pin's
    /// own badge. The view runs the Translation session, which only a
    /// SwiftUI modifier can create.
    func beginTranslating(_ entry: PinnedTranslationMode.Entry) {
        guard pin.editor == nil, pin.translationMode == nil else { return }
        guard let source = CGImageSourceCreateWithURL(pin.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            if entry != .pinned { close() }
            NSSound.beep()
            return
        }
        let model = ScreenshotTranslation(image: image, pointSize: actualSize)
        pin.isLiveTextActive = false
        pin.translationMode = PinnedTranslationMode(model: model, entry: entry)
        panel.makeKey()
        updateToolbarVisibility()
        translationPhaseChanged()
        translationTask = Task { await model.start() }
    }

    /// Keeps the badge in step with the translation.
    func translationPhaseChanged() {
        guard let model = pin.translationMode?.model else { return }
        switch model.phase {
        case .recognizing:
            showFeedback(.recognizing, for: nil)
        case .translating:
            showFeedback(.translating, for: nil)
        case .translated:
            feedbackTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { pin.feedback = nil }
        case .nothingToTranslate:
            showFeedback(.note(String(
                localized: "The text is already in \(ScreenshotTranslation.displayName(for: model.target))."
            )), for: .seconds(3))
        case .failed(let message):
            // Stays until the user acts: it explains why nothing changed.
            showFeedback(.message(message), for: nil)
        }
    }

    func translate(to target: String) {
        guard let model = pin.translationMode?.model else { return }
        translationTask?.cancel()
        translationTask = Task { await model.translate(to: target) }
    }

    func setShowsOriginal(_ showsOriginal: Bool) {
        guard let model = pin.translationMode?.model, model.phase == .translated else { return }
        withAnimation(Self.translationFade) { model.showsOriginal = showsOriginal }
    }

    /// Instant, unlike the toggle: a peek is a glance, not a change.
    fileprivate func setPeekingOriginal(_ peeking: Bool) {
        guard pin.isPeekingOriginal != peeking else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pin.isPeekingOriginal = peeking }
    }

    static var translationFade: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.2)
    }

    func copyTranslatedText() {
        guard let model = pin.translationMode?.model, model.phase == .translated else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.translatedText, forType: .string)
        showFeedback(.note(String(localized: "Copied")))
    }

    /// ⌘C: copies what the pin shows and leaves it up.
    func copyTranslationImage() {
        guard let url = pin.translationMode?.model.writeDisplayedImage() else { return NSSound.beep() }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            try ScreenshotFileActions.copyPNGToClipboard(from: url)
            showFeedback(.note(String(localized: "Copied")))
        } catch {
            NSSound.beep()
        }
    }

    /// ✓: copies what the pin shows and closes it.
    func copyTranslationAndClose() {
        guard pin.translationMode?.isStandalone == true,
              let url = pin.translationMode?.model.writeDisplayedImage() else { return NSSound.beep() }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            try ScreenshotFileActions.copyPNGToClipboard(from: url)
            close()
        } catch {
            FailureAlert.present(message: String(localized: "Failed to copy image"), error: error)
        }
    }

    /// Saves what the pin shows to a file the user picks, and to History:
    /// a translation worth saving is worth finding again.
    func saveTranslation() {
        guard let url = pin.translationMode?.model.writeDisplayedImage() else { return NSSound.beep() }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        savePanel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: url)
        savePanel.canCreateDirectories = true
        savePanel.title = String(localized: "Save Screenshot")
        savePanel.begin { response in
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            guard response == .OK, let destination = savePanel.url else { return }
            do {
                try ScreenshotFileActions.save(from: url, to: destination)
                _ = ScreenshotHistoryStore.shared.importScreenshot(from: url)
            } catch {
                FailureAlert.present(message: String(localized: "Failed to save image"), error: error)
            }
        }
    }

    /// 📌: what the pin shows becomes the pin's image, kept in History, and
    /// the pin stays where it is.
    func keepTranslation() {
        guard let mode = pin.translationMode else { return }
        let showsTranslation = mode.model.translatedImage != nil && !mode.model.showsOriginal
        // An existing pin already shows its original; nothing to keep.
        guard showsTranslation || mode.isStandalone else { return endTranslating() }
        guard let url = mode.model.writeDisplayedImage() else { return NSSound.beep() }
        let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url, movingSource: true)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if case .standalone(ownsFile: true) = mode.entry {
            try? FileManager.default.removeItem(at: pin.url)
        }
        endTranslating()
        reloadImage(from: historyURL)
    }

    /// ✕ and Escape: a capture made to be translated goes; an existing pin
    /// goes back to its own image.
    func discardTranslation() {
        guard let mode = pin.translationMode else { return }
        if mode.isStandalone {
            close()
        } else {
            endTranslating()
        }
    }

    private func endTranslating() {
        translationTask?.cancel()
        translationTask = nil
        pin.translationMode = nil
        pin.isPeekingOriginal = false
        feedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { pin.feedback = nil }
        updateToolbarVisibility()
    }

    // MARK: Editing a capture

    func beginEditingCapture() {
        pin.isEditingCapture = true
        beginAnnotating()
        if pin.editor == nil { pin.isEditingCapture = false }
    }

    /// ✓: saves the annotations, copies the result and closes the pin, so
    /// marking up a capture and pasting it takes one click.
    func copyCaptureAndClose() {
        guard let editor = pin.editor, !editor.isCommitting else { return }
        editor.commitTextEditing()
        let url = pin.url
        Task {
            do {
                let resultURL = editor.hasUnsavedChanges ? try await editor.commitEdits() : nil
                try ScreenshotFileActions.copyPNGToClipboard(from: resultURL ?? url)
                close()
            } catch {
                FailureAlert.present(message: String(localized: "Failed to copy image"), error: error)
            }
        }
    }

    /// Translates the capture where it is: the translated picture takes the
    /// original's place under the annotations, so ✓ copies it and Undo
    /// brings the original back. The view runs the translation itself,
    /// since Apple's Translation sessions come from a SwiftUI modifier.
    func translateInPlace() {
        guard let editor = pin.editor, pin.translation == nil else { return }
        let url = editor.baseImageURL ?? pin.url
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSSound.beep()
            return
        }
        let translation = ScreenshotTranslation(image: image, pointSize: panel.frame.size)
        pin.translation = translation
        showFeedback(.translating, for: nil)
        Task {
            await translation.start()
            // When there is something to translate, the view's translation
            // task carries on and finishes it.
            if translation.phase != .translating { finishTranslation() }
        }
    }

    func finishTranslation() {
        guard let translation = pin.translation else { return }
        pin.translation = nil
        switch translation.phase {
        case .translated:
            guard let url = translation.writeDisplayedImage() else {
                showFeedback(.message(String(localized: "Unable to replace the image.")), for: .seconds(3))
                return
            }
            guard let editor = pin.editor else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            editor.replaceBaseImage(with: url)
            withAnimation(.easeOut(duration: 0.2)) { pin.feedback = nil }
        case .nothingToTranslate:
            showFeedback(.message(String(
                localized: "The text is already in \(ScreenshotTranslation.displayName(for: translation.target))."
            )), for: .seconds(3))
        case .failed(let message):
            showFeedback(.message(message), for: .seconds(3))
        case .recognizing, .translating:
            withAnimation(.easeOut(duration: 0.2)) { pin.feedback = nil }
        }
    }

    /// ✕: drops the pin and its annotations. The capture stays in History.
    func cancelEditingCapture() {
        guard pin.editor?.isCommitting != true else { return }
        close()
    }

    /// Pin: saves the annotations and keeps the capture pinned.
    func keepCapturePinned() {
        pin.isEditingCapture = false
        finishAnnotating()
    }

    /// Saves what the editor shows, annotations included, to a file the
    /// user picks, without leaving the editor.
    func saveAnnotatedImage() {
        guard let editor = pin.editor else { return }
        editor.commitTextEditing()
        let name = ScreenshotFileActions.exportFileName(for: pin.url)
        Task {
            do {
                let renderedURL = try await editor.renderCurrentImage()
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
                savePanel.nameFieldStringValue = name
                savePanel.canCreateDirectories = true
                savePanel.title = String(localized: "Save Screenshot")
                savePanel.begin { response in
                    defer { try? FileManager.default.removeItem(at: renderedURL) }
                    guard response == .OK, let destURL = savePanel.url else { return }
                    do {
                        try ScreenshotFileActions.save(from: renderedURL, to: destURL)
                    } catch {
                        print("Failed to save pinned screenshot: \(error)")
                    }
                }
            } catch {
                FailureAlert.present(message: String(localized: "Failed to save annotation"), error: error)
            }
        }
    }

    /// Saves the annotations into the screenshot and goes back to viewing.
    func finishAnnotating() {
        guard let editor = pin.editor, !editor.isCommitting else { return }
        editor.commitTextEditing()
        guard editor.hasUnsavedChanges else {
            endAnnotating()
            return
        }

        let originalURL = pin.url
        Task {
            do {
                if let resultURL = try await editor.commitEdits() {
                    pin.url = resultURL
                    // Updating a preview card reloads the pins too.
                    if ScreenshotPreviewStack.shared.items.contains(where: { $0.url == originalURL }) {
                        _ = ScreenshotPreviewStack.shared.applyAnnotation(
                            originalURL: originalURL,
                            historyURL: resultURL
                        )
                    } else {
                        PinnedScreenshotPresenter.shared.reloadPins(showing: resultURL)
                    }
                }
                endAnnotating()
            } catch {
                FailureAlert.present(message: String(localized: "Failed to save annotation"), error: error)
            }
        }
    }

    func discardAnnotating() {
        guard let editor = pin.editor, !editor.isCommitting else { return }
        if editor.hasUnsavedChanges {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "Discard your annotations?")
            alert.informativeText = String(localized: "The pinned screenshot stays as it was.")
            alert.addButton(withTitle: String(localized: "Discard"))
            alert.addButton(withTitle: String(localized: "Keep Editing"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        endAnnotating()
    }

    func copyAnnotatedImage() {
        guard let editor = pin.editor else { return }
        Task {
            do {
                let url = try await editor.renderCurrentImage()
                defer { try? FileManager.default.removeItem(at: url) }
                try ScreenshotFileActions.copyPNGToClipboard(from: url)
            } catch {
                FailureAlert.present(message: String(localized: "Failed to copy image"), error: error)
            }
        }
    }

    private func endAnnotating() {
        pin.editor?.releaseEditorResources()
        pin.editor = nil
        pin.isEditingCapture = false
        updateToolbarVisibility()
    }

    func reloadImage(from url: URL) {
        guard let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: Self.previewPixelSize) else {
            return
        }
        pixelSize = ScreenshotImageLoader.imageSize(at: url) ?? image.size
        pin.replaceImage(image, url: url)

        // Keep the width and top edge; follow the new aspect ratio, which a
        // background added in the editor can change.
        let frame = panel.frame
        let height = (frame.width * pixelSize.height / max(pixelSize.width, 1)).rounded()
        let size = NSSize(width: frame.width, height: height)
        panel.contentAspectRatio = size
        if abs(height - frame.height) >= 1 {
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: size.width, height: height), display: true)
        }
    }

    // MARK: Size and position

    func nudge(dx: CGFloat, dy: CGFloat) {
        var origin = panel.frame.origin
        origin.x += dx
        origin.y += dy
        panel.setFrameOrigin(origin)
    }

    static let zoomStep: CGFloat = 1.25

    /// - Parameter anchor: A screen point that stays put, such as the
    ///   pointer during a pinch. Defaults to the pin's center.
    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil, animated: Bool = true) {
        let frame = panel.frame
        resize(to: NSSize(width: frame.width * factor, height: frame.height * factor), around: anchor, animated: animated)
    }

    /// One image pixel per screen pixel, as far as the screen allows.
    func zoomToActualSize() {
        resize(to: actualSize, around: nil, animated: true)
    }

    private var actualSize: NSSize {
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    private func resize(to proposed: NSSize, around anchor: CGPoint?, animated: Bool) {
        let frame = panel.frame
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: proposed)
        guard let target = PinnedScreenshotGeometry.resizedFrame(
            frame, to: proposed, around: anchor, minSize: panel.minSize, visibleFrame: visibleFrame
        ) else { return }
        if target != frame {
            let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.setFrame(target, display: true, animate: animate)
        }
        if let percent = PinnedScreenshotGeometry.zoomPercent(width: target.width, actualWidth: actualSize.width) {
            showFeedback(.zoom(percent))
        }
    }

    // MARK: Opacity

    static let opacityStep: CGFloat = 0.1

    /// Fades the pin, never so far that it can't be found again.
    func setOpacity(_ opacity: CGFloat) {
        let opacity = PinnedScreenshotGeometry.clampedOpacity(opacity)
        panel.alphaValue = opacity
        pin.opacity = opacity
        showFeedback(.opacity(Int((opacity * 100).rounded())))
    }

    /// - Parameter duration: How long it stays up; nil keeps it until replaced.
    private func showFeedback(_ feedback: PinnedScreenshotFeedback, for duration: Duration? = .seconds(1.2)) {
        pin.feedback = feedback
        feedbackTask?.cancel()
        guard let duration else { return }
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self?.pin.feedback = nil }
        }
    }

    // MARK: Toolbar

    /// The toolbar is up while the pin is selected, and stays up while a mode
    /// that needs it is on, so the way back out is always visible.
    private func updateToolbarVisibility() {
        setToolbarVisible(pin.isSelected || pin.editor != nil || pin.isLiveTextActive || pin.translationMode != nil)
    }

    private func setToolbarVisible(_ visible: Bool) {
        if visible {
            guard toolbarPanel.parent == nil else { return }
            layoutToolbar()
            toolbarPanel.alphaValue = 0
            panel.addChildWindow(toolbarPanel, ordered: .above)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                toolbarPanel.animator().alphaValue = 1
            }
        } else {
            guard toolbarPanel.parent != nil else { return }
            panel.removeChildWindow(toolbarPanel)
            toolbarPanel.orderOut(nil)
        }
    }

    /// Below the pin's right edge, where it covers none of the image; above
    /// it when the pin sits at the bottom of the screen.
    private func layoutToolbar() {
        let size = toolbarPanel.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let pinFrame = panel.frame
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? pinFrame
        toolbarPanel.setFrame(
            PinnedScreenshotGeometry.toolbarFrame(size: size, pinFrame: pinFrame, visibleFrame: visibleFrame, gap: Self.toolbarGap),
            display: true
        )
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        withAnimation(.easeOut(duration: 0.15)) { pin.isSelected = true }
        updateToolbarVisibility()
    }

    func windowDidResignKey(_ notification: Notification) {
        setPeekingOriginal(false)
        withAnimation(.easeOut(duration: 0.15)) { pin.isSelected = false }
        updateToolbarVisibility()
    }

    func windowDidResize(_ notification: Notification) {
        if toolbarPanel.parent != nil { layoutToolbar() }
    }

    func windowDidMove(_ notification: Notification) {
        if toolbarPanel.parent != nil { layoutToolbar() }
    }

    // MARK: Keys

    /// Keys act on the selected pin only. While annotating, the canvas's own
    /// key handler takes everything but Escape.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if event.type == .keyUp {
                // Releasing Space ends a peek at the original.
                guard event.keyCode == 49, self.pin.isPeekingOriginal else { return event }
                self.setPeekingOriginal(false)
                return nil
            }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if let mode = pin.translationMode {
            switch (modifiers, event.keyCode, key) {
            case ([], 53, _):
                discardTranslation()
                return true
            case ([], 36, _), ([], 76, _):
                // Return does what the toolbar's last button does.
                if mode.isStandalone { copyTranslationAndClose() } else { keepTranslation() }
                return true
            case ([], 49, _):
                if mode.model.phase == .translated, !mode.model.showsOriginal {
                    setPeekingOriginal(true)
                }
                return true
            case (.command, _, "c"):
                copyTranslationImage()
                return true
            case ([.command, .shift], _, "c"):
                copyTranslatedText()
                return true
            case (.command, _, "s"):
                saveTranslation()
                return true
            default:
                // Zoom, nudge and opacity work as they do on any pin;
                // nothing starts annotating.
                break
            }
        }

        if pin.editor != nil {
            guard !(panel.firstResponder is NSTextView) else { return false }
            // A fresh capture: Return copies it, Escape throws it away.
            if pin.isEditingCapture {
                switch event.keyCode {
                case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty: copyCaptureAndClose()
                case 53: cancelEditingCapture()
                default: return false
                }
                return true
            }
            guard event.keyCode == 53 else { return false }
            finishAnnotating()
            return true
        }

        switch (modifiers, event.keyCode, key) {
        case ([], 53, _):
            // Escape leaves Live Text first, then closes.
            if pin.isLiveTextActive {
                pin.isLiveTextActive = false
                updateToolbarVisibility()
            } else {
                close()
            }
        case (.command, _, "w"):
            close()
        case (.command, _, "c"):
            // Live Text copies its own selection.
            guard !pin.isLiveTextActive else { return false }
            copyImage()
        case ([.command, .shift], _, "c"):
            copyText()
        case (.command, _, "s"):
            save()
        // By key code, so they work whatever the keyboard layout types, and
        // with or without Command since a pin has no text to type into.
        case (_, 24, _) where modifiers.subtracting([.command, .shift]).isEmpty,
             (_, 69, _) where modifiers.subtracting(.command).isEmpty:
            zoom(by: Self.zoomStep)   // = / +, keypad +
        case (_, 27, _) where modifiers.subtracting(.command).isEmpty,
             (_, 78, _) where modifiers.subtracting(.command).isEmpty:
            zoom(by: 1 / Self.zoomStep)   // -, keypad -
        case (_, 29, _) where modifiers.subtracting(.command).isEmpty,
             (_, 82, _) where modifiers.subtracting(.command).isEmpty:
            zoomToActualSize()   // 0, keypad 0
        case ([], 123, _), ([.shift], 123, _):
            nudge(dx: modifiers.contains(.shift) ? -10 : -1, dy: 0)
        case ([], 124, _), ([.shift], 124, _):
            nudge(dx: modifiers.contains(.shift) ? 10 : 1, dy: 0)
        case ([], 125, _), ([.shift], 125, _):
            nudge(dx: 0, dy: modifiers.contains(.shift) ? -10 : -1)
        case ([], 126, _), ([.shift], 126, _):
            nudge(dx: 0, dy: modifiers.contains(.shift) ? 10 : 1)
        case ([], 33, _):   // [
            setOpacity(panel.alphaValue - Self.opacityStep)
        case ([], 30, _):   // ]
            setOpacity(panel.alphaValue + Self.opacityStep)
        case ([], _, "e") where pin.translationMode == nil:
            beginAnnotating()
        default:
            // A tool's key starts annotating with that tool.
            guard !pin.isLiveTextActive, pin.translationMode == nil,
                  modifiers.subtracting(.shift).isEmpty,
                  key.count == 1,
                  let tool = AnnotationTool.forShortcut(key: key, shift: modifiers.contains(.shift)) else {
                return false
            }
            beginAnnotating(with: tool)
        }
        return true
    }
}

// MARK: - Panels

final class PinnedPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 80, height: 80)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Zoom by a factor around a screen point.
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    /// Change opacity by a delta.
    var onFade: ((CGFloat) -> Void)?

    /// Pinch to zoom around the pointer. While annotating too: the canvas
    /// leaves zooming to the pin, so the image keeps filling it.
    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification, NSEvent.mouseLocation)
    }

    /// Scroll over a pin to fade it in/out. Handled at the window level so it
    /// only fires when the cursor is over the pin, and applied via
    /// `alphaValue` so the compositor blends the existing buffer without
    /// re-rendering the SwiftUI image view.
    override func scrollWheel(with event: NSEvent) {
        // Ignore momentum coasting so a flick doesn't keep fading after release.
        guard event.momentumPhase.isEmpty else { return }

        // Command-scroll zooms around the pointer, like Command-plus and
        // minus; a plain scroll fades.
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 40
            let physicalUp = event.isDirectionInvertedFromDevice ? -delta : delta
            guard physicalUp != 0 else { return }
            onZoom?(exp(physicalUp * 0.004), NSEvent.mouseLocation)
            return
        }

        // Trackpads report pixel deltas; discrete wheels report lines, which
        // Apple docs say to scale by a line height for parity.
        // https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltay
        // One line ≈ 40pt, matching Chromium's kScrollbarPixelsPerCocoaTick.
        // https://codereview.chromium.org/2226933004/patch/160001/170001
        // At 0.002 sensitivity that's 0.08/notch (~10 clicks, full range).
        let rawDelta = event.scrollingDeltaY
        guard rawDelta != 0 else { return }
        let points = event.hasPreciseScrollingDeltas ? rawDelta : rawDelta * 40

        // `scrollingDeltaY` follows the user's Natural Scroll setting, so
        // un-invert it: physical scroll-up must always restore opacity.
        // https://developer.apple.com/documentation/appkit/nsevent/isdirectioninvertedfromdevice
        let physicalUp = event.isDirectionInvertedFromDevice ? -points : points

        let sensitivity: CGFloat = 0.002
        onFade?(physicalUp * sensitivity)
    }
}

/// The toolbar never takes key, so clicking it leaves the pin selected and
/// the pin's keys working.
private final class PinnedToolbarPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var fittingSize: NSSize { contentView?.fittingSize ?? .zero }

    func setContent(_ view: some View, onSizeChange: @escaping () -> Void) {
        let host = PinnedToolbarHostingView(rootView: AnyView(view))
        host.sizingOptions = [.intrinsicContentSize]
        host.onSizeChange = onSizeChange
        contentView = host
    }
}

private final class PinnedToolbarHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?

    /// Buttons answer the first click even though the panel is never key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI calls this when the toolbar changes between viewing and
    /// annotating; the panel is resized to match on the next pass.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}
