//
//  AreaSelectionTracker.swift
//  Framecho
//
//  Follows the pointer while `screencapture -i` runs, which doesn't report
//  where the area it took was, so Capture Area and Pin can put the pin there.
//

import AppKit
import os

@MainActor
final class AreaSelectionTracker {
    private static let log = Logger(subsystem: "com.jarinhe.Framecho", category: "AreaSelection")

    private var timer: Timer?
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var isReleased = false

    /// Samples the mouse button and the pointer rather than watching events:
    /// screencapture's overlay takes the drag's events for itself, so other
    /// apps' event monitors never see them, but the button state and the
    /// cursor position still read true.
    func start() {
        stop()
        dragStart = nil
        dragEnd = nil
        isReleased = false
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard !isReleased else { return }
        let isPressed = CGEventSource.buttonState(.hidSystemState, button: .left)
        let location = NSEvent.mouseLocation
        if isPressed {
            if dragStart == nil { dragStart = location }
            dragEnd = location
        } else if dragStart != nil {
            // Released: the pointer is where the button came up.
            dragEnd = location
            isReleased = true
        }
    }

    /// Where the area captured to `url` was on screen, or nil when that
    /// can't be told, such as when a window was clicked instead.
    func capturedFrame(for url: URL) -> CGRect? {
        sample()
        stop()
        guard let dragStart, let dragEnd else {
            Self.log.info("No drag seen; the pin is placed as usual")
            return nil
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(dragStart) }),
              let pixelSize = ScreenshotImageLoader.imageSize(at: url) else { return nil }
        let frame = PinnedScreenshotGeometry.capturedAreaFrame(
            dragStart: dragStart,
            dragEnd: dragEnd,
            pixelSize: pixelSize,
            backingScale: screen.backingScaleFactor,
            screenFrame: screen.frame
        )
        Self.log.info("""
            Drag \(String(describing: dragStart), privacy: .public) → \(String(describing: dragEnd), privacy: .public), \
            \(Int(pixelSize.width))×\(Int(pixelSize.height)) px at \(screen.backingScaleFactor)x: \
            \(frame.map { String(describing: $0) } ?? "no frame", privacy: .public)
            """)
        return frame
    }
}
