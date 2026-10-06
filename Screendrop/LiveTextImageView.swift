//
//  LiveTextImageView.swift
//  Framecho
//
//  An image view with Live Text: the text in the image can be selected,
//  copied, looked up, and translated in place, the way Preview and Photos
//  allow. Selection is behind an explicit mode so that a view the user
//  normally drags around - a pin is mostly text - still moves when dragged.
//

import AppKit
import SwiftUI
import VisionKit

/// One item in the view's context menu. Over recognised text in Live Text
/// mode the system's text menu (Copy, Look Up, Translate) shows instead.
enum LiveTextMenuEntry {
    case action(String, () -> Void)
    case separator
}

struct LiveTextImageView: NSViewRepresentable {
    let image: NSImage
    /// Analysed at full resolution, so text stays selectable even when
    /// `image` is a downsampled copy.
    let url: URL
    var cornerRadius: CGFloat = 0
    /// Text is selectable and highlighted only while this is on.
    var isLiveTextActive: Bool
    var menuEntries: [LiveTextMenuEntry] = []
    /// Called once analysis finishes, with whether the image has any text.
    var onAnalysisFinished: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> LiveTextImageContainer {
        let view = LiveTextImageContainer(image: image)
        view.analyze(imageAt: url, completion: onAnalysisFinished)
        return view
    }

    func updateNSView(_ view: LiveTextImageContainer, context: Context) {
        view.cornerRadius = cornerRadius
        view.isLiveTextActive = isLiveTextActive
        view.menuEntries = menuEntries
    }

    static func dismantleNSView(_ view: LiveTextImageContainer, coordinator: ()) {
        view.cancelAnalysis()
    }
}

final class LiveTextImageContainer: NSView {
    /// One analyzer for the app: it is thread-safe, and each instance holds
    /// on to its own recognition models.
    private static let analyzer = ImageAnalyzer()

    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private var analysisTask: Task<Void, Never>?

    var menuEntries: [LiveTextMenuEntry] = []

    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    var isLiveTextActive = false {
        didSet {
            guard isLiveTextActive != oldValue else { return }
            // Text and data detectors only: lifting a "subject" out of a
            // screenshot is not something anyone pins one for.
            overlay.preferredInteractionTypes = isLiveTextActive ? .automaticTextOnly : []
            overlay.selectableItemsHighlighted = isLiveTextActive
            if !isLiveTextActive {
                overlay.resetSelection()
            }
        }
    }

    init(image: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = []
        // The pin's own toolbar switches Live Text on and off; the system
        // button would duplicate it and crowd a small window.
        overlay.isSupplementaryInterfaceHidden = true
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func analyze(imageAt url: URL, completion: @escaping (Bool) -> Void) {
        guard ImageAnalyzer.isSupported else {
            completion(false)
            return
        }
        analysisTask = Task { [weak self] in
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            let analysis = try? await Self.analyzer.analyze(
                imageAt: url, orientation: .up, configuration: configuration
            )
            guard !Task.isCancelled, let self else { return }
            self.overlay.analysis = analysis
            completion(analysis?.hasResults(for: .text) ?? false)
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
    }

    // MARK: - Event routing

    /// Outside Live Text, and over parts of the image with nothing to
    /// select, clicks land on this view so a drag moves the window. The
    /// overlay only takes the events it can use.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        guard isLiveTextActive else { return self }

        // The overlay's point queries take a top-left origin even though the
        // view itself is not flipped.
        var overlayPoint = overlay.convert(local, from: self)
        if !overlay.isFlipped {
            overlayPoint.y = overlay.bounds.height - overlayPoint.y
        }
        if overlay.hasActiveTextSelection || overlay.hasInteractiveItem(at: overlayPoint) {
            return overlay.hitTest(point) ?? overlay
        }
        return self
    }

    /// Dragging moves the window. Asked for explicitly: the SwiftUI views
    /// hosting this one don't let the window's background drag through.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        appendEntries(to: menu)
        return menu.items.isEmpty ? nil : menu
    }

    private func appendEntries(to menu: NSMenu) {
        for entry in menuEntries {
            switch entry {
            case .action(let title, let handler):
                menu.addItem(ClosureMenuItem(title: title, handler: handler))
            case .separator:
                menu.addItem(.separator())
            }
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invokeHandler), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invokeHandler() {
        handler()
    }
}
