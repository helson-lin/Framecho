//
//  ScrollingCapturePresenter.swift
//  Framecho
//
//  Scrolling Capture: the user draws an area, scrolls its content, and gets
//  one tall screenshot. The area stays highlighted while a small bar beside
//  it shows how far the capture has grown, scrolls for the user if asked,
//  and ends or cancels it.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI
import os

@MainActor
final class ScrollingCapturePresenter {
    static let shared = ScrollingCapturePresenter()
    private static let logger = Logger(subsystem: "com.jarinhe.Framecho", category: "ScrollingCapture")

    private(set) var isActive = false
    private let status = ScrollingCaptureStatus()
    private var panel: NSPanel?
    private var stream: ScrollingCaptureStream?
    private var completion: CheckedContinuation<Bool, Never>?
    /// The area being captured, in AppKit global coordinates.
    private var area = CGRect.zero
    private var autoScroll: Task<Void, Never>?
    private var userInputMonitor: Any?
    /// How many pixel rows a frame has.
    private var areaPixelHeight = 0

    private init() {}

    /// Runs a scrolling capture and returns the long screenshot as a PNG in
    /// the temporary folder, or nil when it was cancelled or failed.
    func capture() async -> URL? {
        guard !isActive else { return nil }
        isActive = true
        defer {
            isActive = false
            tearDown()
        }

        let content: SCShareableContent
        do {
            content = try await ScreenRecordingCapture.availableContent()
        } catch {
            FailureAlert.present(message: String(localized: "Couldn't start Scrolling Capture"), error: error)
            return nil
        }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first,
              let screen = ActiveDisplayResolver.screen(for: display.displayID) ?? NSScreen.main,
              let rect = await selectArea(on: display) else { return nil }

        status.reset()
        area = rect
        RecordingAreaHighlightPresenter.shared.show(display: display, rect: rect)
        showBar(beside: rect, on: screen)
        // The selection overlay fades out after it closes; a frame taken
        // during the fade is dimmed.
        try? await Task.sleep(for: .milliseconds(250))

        let stream = ScrollingCaptureStream()
        do {
            // Listed again so the highlight and the bar, now on screen, can
            // be left out of the frames.
            let content = try await ScreenRecordingCapture.availableContent()
            let freshDisplay = content.displays.first(where: { $0.displayID == display.displayID }) ?? display
            let filter = ScreenRecordingCapture.displayFilter(
                display: freshDisplay,
                content: content,
                includesAppWindows: PreviewWindowCaptureExclusion.includesAppWindowsInCaptures,
                excludedWindowIDs: PreviewWindowCaptureExclusion.shared.recorderControlWindowIDs
            )
            let sourceRect = ScreenRecordingManager.sourceRect(
                forAppKitSelectionRect: rect,
                screenFrame: screen.frame,
                contentRect: filter.contentRect
            )
            let status = status
            stream.onUpdate = { outcome, height in
                Task { @MainActor in status.update(outcome, height: height) }
            }
            stream.onError = { _ in
                Task { @MainActor in ScrollingCapturePresenter.shared.finish(keeping: true) }
            }
            let configuration = Self.configuration(
                sourceRect: sourceRect,
                scale: max(1, CGFloat(filter.pointPixelScale))
            )
            areaPixelHeight = configuration.height
            try await stream.start(filter: filter, configuration: configuration)
        } catch {
            FailureAlert.present(message: String(localized: "Couldn't start Scrolling Capture"), error: error)
            return nil
        }
        self.stream = stream

        let keep = await withCheckedContinuation { completion = $0 }
        // The bar goes first, so finishing a tall image doesn't look stuck.
        hideOverlays()
        let image = await stream.stop()
        self.stream = nil
        guard keep, let image else { return nil }
        return ScreenshotManager.shared.saveCapturedImage(image)
    }

    /// Ends the capture from the bar: `keeping` the image, or throwing it away.
    func finish(keeping: Bool) {
        stopAutoScroll()
        let completion = completion
        self.completion = nil
        completion?.resume(returning: keeping)
    }

    // MARK: - Auto scroll

    /// Scrolls the area's content a step at a time until it stops moving.
    /// It moves the scroll bar under the area through Accessibility, so the
    /// pointer stays with the user, and a click or key press anywhere stops it.
    func toggleAutoScroll() {
        if autoScroll != nil {
            stopAutoScroll()
            return
        }
        guard AppPermissionCenter.shared.ensureAccessibility() else {
            status.show(.needsAccessibility)
            return
        }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let center = CGPoint(x: area.midX, y: mainHeight - area.midY)
        guard let pid = Self.processOwningWindow(at: center),
              let bar = Self.verticalScrollBar(of: pid, at: center) else {
            status.show(.cantAutoScroll)
            return
        }
        status.isAutoScrolling = true
        userInputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { event in
            let type = event.type.rawValue
            Task { @MainActor in
                Self.logger.debug("Auto scroll stopped by user input \(type)")
                ScrollingCapturePresenter.shared.stopAutoScroll()
            }
        }
        autoScroll = Task { [weak self] in
            await self?.runAutoScroll(bar: bar)
        }
    }

    private func stopAutoScroll() {
        autoScroll?.cancel()
        autoScroll = nil
        if let userInputMonitor {
            NSEvent.removeMonitor(userInputMonitor)
            self.userInputMonitor = nil
        }
        status.isAutoScrolling = false
    }

    private func runAutoScroll(bar: AXUIElement) async {
        // A quarter of a frame per step leaves far more overlap than the
        // stitcher needs. The scroll bar's value runs 0...1 over the whole
        // document, so how far a change moves is measured, not known: the
        // step starts small and is adjusted only from steps that stitched.
        let targetRows = max(24, areaPixelHeight / 4)
        var delta = 0.01
        guard var accepted = Self.scrollValue(of: bar) else {
            stopAutoScroll()
            status.show(.cantAutoScroll)
            return
        }
        var stalls = 0
        var misses = 0
        while !Task.isCancelled {
            guard let value = Self.scrollValue(of: bar) else {
                stopAutoScroll()
                status.show(.cantAutoScroll)
                return
            }
            let before = status.height
            let missedBefore = status.missedFrames
            let moved = await setScrollValue(min(1, value + delta), of: bar)
            guard !Task.isCancelled else { return }
            if let after = Self.scrollValue(of: bar), after == value {
                // The app ignored the change, or the bar is at its end.
                stopAutoScroll()
                status.show(value >= 1 ? .reachedEnd : .cantAutoScroll)
                return
            }
            Self.logger.debug("Auto scroll step: value \(value) delta \(delta) moved \(moved) outcome \(String(describing: self.status.lastOutcome), privacy: .public) grown \(self.status.height - before)")

            guard moved else {
                // Nothing on screen changed, even after waiting.
                stalls += 1
                guard stalls < 2 else {
                    stopAutoScroll()
                    status.show(.reachedEnd)
                    return
                }
                continue
            }
            stalls = 0

            // Judged by what the step did overall: the last frame is often a
            // settled one that changed nothing.
            let grown = status.height - before
            if status.hint == .limit {
                stopAutoScroll()
                return
            }
            if grown == 0, status.missedFrames > missedBefore {
                // Lost the overlap: go back to the last frame that matched
                // and take smaller steps, but give up rather than bounce
                // forever.
                misses += 1
                Self.logger.debug("Auto scroll lost the overlap at \(value), back to \(accepted)")
                guard misses < 3 else {
                    stopAutoScroll()
                    status.show(.tooFast)
                    return
                }
                _ = await setScrollValue(accepted, of: bar)
                delta /= 2
                continue
            }
            if grown > 0 {
                misses = 0
                accepted = Self.scrollValue(of: bar) ?? accepted
                // Aim the next step at the target, changing by at most 2x.
                delta *= min(2, max(0.5, Double(targetRows) / Double(grown)))
            }
            if (Self.scrollValue(of: bar) ?? 0) >= 1 {
                stopAutoScroll()
                status.show(.reachedEnd)
                return
            }
        }
    }

    /// Moves the scroll bar and returns whether a frame showing the move
    /// was stitched within 1.5 seconds; an app in the background can be
    /// slow to redraw. Frames that change nothing, such as a caret
    /// blinking, don't count.
    private func setScrollValue(_ value: Double, of bar: AXUIElement) async -> Bool {
        let seen = status.movedFrames
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: value))
        for _ in 0..<50 where !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            if status.movedFrames != seen {
                // Let a frame captured mid-redraw be followed by the settled one.
                try? await Task.sleep(for: .milliseconds(60))
                return true
            }
        }
        return false
    }

    private static func scrollValue(of bar: AXUIElement) -> Double? {
        (attribute(kAXValueAttribute, of: bar) as? NSNumber)?.doubleValue
    }

    /// The vertical scroll bar of the scroll area at `point` (Quartz global
    /// coordinates) in `pid`'s windows. Asking the app rather than the
    /// system skips Framecho's overlays above it.
    private static func verticalScrollBar(of pid: pid_t, at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit
        ) == .success, var element = hit else { return nil }
        for _ in 0..<16 {
            if attribute(kAXRoleAttribute, of: element) as? String == kAXScrollAreaRole,
               let bar = attribute(kAXVerticalScrollBarAttribute, of: element),
               CFGetTypeID(bar) == AXUIElementGetTypeID() {
                return (bar as! AXUIElement)
            }
            guard let parent = attribute(kAXParentAttribute, of: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// The app whose window is frontmost at `point` (Quartz global
    /// coordinates), skipping Framecho's own overlays.
    private static func processOwningWindow(at point: CGPoint) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(point) else { continue }
            return pid
        }
        return nil
    }

    private static func configuration(sourceRect: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        // Stitching a frame takes tens of milliseconds; more frames than this
        // would only be dropped.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        return configuration
    }

    private func selectArea(on display: SCDisplay) async -> CGRect? {
        await withCheckedContinuation { continuation in
            RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
                continuation.resume(returning: rect)
            }
        }
    }

    // MARK: - Bar

    private static let barSize = NSSize(width: 420, height: 52)
    private static let barGap: CGFloat = 12

    private func showBar(beside rect: CGRect, on screen: NSScreen) {
        let size = Self.barSize
        let hostingView = NSHostingView(rootView: ScrollingCaptureBar(status: status, size: size))
        hostingView.sizingOptions = []

        let panel = ScrollingCaptureBarPanel(
            contentRect: NSRect(origin: Self.barOrigin(beside: rect, size: size, in: screen.visibleFrame), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the highlight, which sits at the screen saver level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        PreviewWindowCaptureExclusion.shared.registerRecorderControl(window: panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Below the area when there's room, else above it, else inside its
    /// bottom edge - never over the content being scrolled if avoidable.
    private static func barOrigin(beside rect: CGRect, size: NSSize, in visible: CGRect) -> CGPoint {
        let x = min(max(rect.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        if rect.minY - barGap - size.height >= visible.minY {
            return CGPoint(x: x, y: rect.minY - barGap - size.height)
        }
        if rect.maxY + barGap + size.height <= visible.maxY {
            return CGPoint(x: x, y: rect.maxY + barGap)
        }
        return CGPoint(x: x, y: max(rect.minY, visible.minY) + barGap)
    }

    private func hideOverlays() {
        panel?.orderOut(nil)
        panel = nil
        RecordingAreaHighlightPresenter.shared.hide()
    }

    private func tearDown() {
        stopAutoScroll()
        hideOverlays()
        finish(keeping: false)
    }
}

/// Clicks reach the bar without taking focus from the app being scrolled.
private final class ScrollingCaptureBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class ScrollingCaptureStatus {
    enum Hint {
        case scroll
        case scrollDown
        case tooFast
        case limit
        case reachedEnd
        case needsAccessibility
        case cantAutoScroll
    }

    private(set) var hint = Hint.scroll
    private(set) var height = 0
    /// Frames stitched so far in which something moved, and what the last
    /// frame did.
    private(set) var movedFrames = 0
    /// Frames that couldn't be matched.
    private(set) var missedFrames = 0
    private(set) var lastOutcome: ScrollingCaptureStitcher.Outcome?
    var isAutoScrolling = false

    func reset() {
        hint = .scroll
        height = 0
        movedFrames = 0
        missedFrames = 0
        lastOutcome = nil
        isAutoScrolling = false
    }

    func show(_ hint: Hint) {
        self.hint = hint
    }

    func update(_ outcome: ScrollingCaptureStitcher.Outcome, height: Int) {
        self.height = height
        if outcome != .unchanged { movedFrames += 1 }
        if outcome == .noMatch { missedFrames += 1 }
        lastOutcome = outcome
        switch outcome {
        // A blinking caret yields frames too; only movement clears a message.
        case .unchanged, .sizeMismatch: break
        case .started, .appended: hint = .scroll
        case .scrolledBackward: hint = .scrollDown
        case .noMatch: hint = .tooFast
        case .reachedLimit: hint = .limit
        }
    }
}

private struct ScrollingCaptureBar: View {
    let status: ScrollingCaptureStatus
    let size: NSSize

    private var hint: String {
        switch status.hint {
        case .scroll: String(localized: "Scroll slowly to capture more")
        case .scrollDown: String(localized: "Scroll down to continue")
        case .tooFast: String(localized: "Scrolled too fast - scroll back up a little")
        case .limit: String(localized: "Reached the maximum length")
        case .reachedEnd: String(localized: "Reached the end - click Done to save")
        case .needsAccessibility: String(localized: "Auto scroll needs Accessibility access")
        case .cantAutoScroll: String(localized: "Can't scroll this automatically - scroll by hand")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 1) {
                Text("Scrolling Capture · \(status.height) px")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(status.hint == .scroll || status.hint == .reachedEnd ? .white.opacity(0.65) : .yellow)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Button {
                ScrollingCapturePresenter.shared.toggleAutoScroll()
            } label: {
                Image(systemName: status.isAutoScrolling ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.white)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help(status.isAutoScrolling ? String(localized: "Stop auto scroll") : String(localized: "Auto scroll"))

            Button {
                ScrollingCapturePresenter.shared.finish(keeping: false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.white)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Cancel"))

            Button {
                ScrollingCapturePresenter.shared.finish(keeping: true)
            } label: {
                Text("Done")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(width: size.width, height: size.height)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.55))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        }
    }
}
