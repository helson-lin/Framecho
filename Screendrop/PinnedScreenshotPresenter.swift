//
//  PinnedScreenshotPresenter.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Pins a screenshot to the screen as a floating, always-on-top window the user
/// can keep around for reference while they work. Supports multiple pins.
@MainActor
final class PinnedScreenshotPresenter {
    static let shared = PinnedScreenshotPresenter()

    private var pins: [PinnedScreenshotController] = []

    private init() {}

    func pin(url: URL) {
        guard let controller = PinnedScreenshotController(url: url) else { return }
        controller.onClose = { [weak self, weak controller] in
            self?.pins.removeAll { $0 === controller }
        }
        controller.show(at: cascadedOrigin(for: controller.panel.frame.size))
        pins.append(controller)
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
    /// Present while annotating in place.
    fileprivate(set) var editor: AnnotationEditorModel?

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

    private static let previewPixelSize: CGFloat = 1600
    private static let toolbarGap: CGFloat = 8

    init?(url: URL) {
        guard let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: Self.previewPixelSize) else {
            return nil
        }
        pixelSize = ScreenshotImageLoader.imageSize(at: url) ?? image.size
        pin = PinnedScreenshot(url: url, image: image)

        let contentSize = Self.displaySize(forPixelSize: pixelSize)
        panel = PinnedPanel(contentRect: NSRect(origin: .zero, size: contentSize))
        panel.contentAspectRatio = contentSize
        super.init()

        panel.delegate = self
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

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        copyFeedbackTask?.cancel()
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
            .action(String(localized: "Save…"), { [weak self] in self?.save() }),
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

    func zoom(by factor: CGFloat) {
        let frame = panel.frame
        resize(to: NSSize(width: frame.width * factor, height: frame.height * factor))
    }

    /// One image pixel per screen pixel, as far as the screen allows.
    func zoomToActualSize() {
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        resize(to: NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale))
    }

    /// Resizes around the pin's center, kept between the minimum size and
    /// the screen it is on.
    private func resize(to proposed: NSSize) {
        guard proposed.width > 0, proposed.height > 0 else { return }
        let frame = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.size ?? proposed
        let grow = max(panel.minSize.width / proposed.width, panel.minSize.height / proposed.height, 1)
        let shrink = min(visible.width / proposed.width, visible.height / proposed.height, 1)
        let factor = grow > 1 ? grow : shrink
        let size = NSSize(width: (proposed.width * factor).rounded(), height: (proposed.height * factor).rounded())
        let target = NSRect(
            x: (frame.midX - size.width / 2).rounded(),
            y: (frame.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        panel.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Convert pixel dimensions to a sensible point size for the pinned window,
    /// scaled for the display and clamped so pins stay handy but readable.
    private static func displaySize(forPixelSize pixelSize: CGSize) -> NSSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var width = pixelSize.width / scale
        var height = pixelSize.height / scale
        guard width > 0, height > 0 else { return NSSize(width: 320, height: 240) }

        let longest = max(width, height)
        let maxLongest: CGFloat = 560
        let minLongest: CGFloat = 160
        let target = min(max(longest, minLongest), maxLongest)
        let factor = target / longest
        width *= factor
        height *= factor
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    // MARK: Toolbar

    /// The toolbar is up while the pin is selected, and stays up while a mode
    /// that needs it is on, so the way back out is always visible.
    private func updateToolbarVisibility() {
        setToolbarVisible(pin.isSelected || pin.editor != nil || pin.isLiveTextActive)
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
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? pinFrame
        let gap = Self.toolbarGap

        let x = min(max(pinFrame.maxX - size.width, screen.minX + gap), screen.maxX - size.width - gap)
        var y = pinFrame.minY - gap - size.height
        if y < screen.minY + gap {
            let above = pinFrame.maxY + gap
            y = above + size.height <= screen.maxY - gap ? above : pinFrame.minY + gap
        }
        toolbarPanel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        withAnimation(.easeOut(duration: 0.15)) { pin.isSelected = true }
        updateToolbarVisibility()
    }

    func windowDidResignKey(_ notification: Notification) {
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if pin.editor != nil {
            guard event.keyCode == 53, !(panel.firstResponder is NSTextView) else { return false }
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
        case (.command, _, "="), ([.command, .shift], _, "+"):
            zoom(by: 1.25)
        case (.command, _, "-"):
            zoom(by: 0.8)
        case (.command, _, "0"):
            zoomToActualSize()
        case ([], 123, _), ([.shift], 123, _):
            nudge(dx: modifiers.contains(.shift) ? -10 : -1, dy: 0)
        case ([], 124, _), ([.shift], 124, _):
            nudge(dx: modifiers.contains(.shift) ? 10 : 1, dy: 0)
        case ([], 125, _), ([.shift], 125, _):
            nudge(dx: 0, dy: modifiers.contains(.shift) ? -10 : -1)
        case ([], 126, _), ([.shift], 126, _):
            nudge(dx: 0, dy: modifiers.contains(.shift) ? 10 : 1)
        case ([], _, "e"):
            beginAnnotating()
        default:
            // A tool's key starts annotating with that tool.
            guard !pin.isLiveTextActive,
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

    /// Scroll over a pin to fade it in/out. Handled at the window level so it
    /// only fires when the cursor is over the pin, and applied via
    /// `alphaValue` so the compositor blends the existing buffer without
    /// re-rendering the SwiftUI image view.
    override func scrollWheel(with event: NSEvent) {
        // Ignore momentum coasting so a flick doesn't keep fading after release.
        guard event.momentumPhase.isEmpty else { return }

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
        alphaValue = min(1, max(0.2, alphaValue + physicalUp * sensitivity))
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
