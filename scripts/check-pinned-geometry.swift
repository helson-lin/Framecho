import CoreGraphics

// Compile the pin's real geometry without launching the app:
// xcrun swiftc -module-cache-path /tmp/framecho-pin-module-cache \
//   Framecho/PinnedScreenshotGeometry.swift scripts/check-pinned-geometry.swift \
//   -o /tmp/framecho-pin-check && /tmp/framecho-pin-check
@main
struct PinnedGeometryChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func same(_ actual: CGRect?, _ expected: CGRect, _ message: String) {
        expect(actual == expected, "\(message): expected \(expected), got \(String(describing: actual))")
    }

    static func same(_ actual: CGSize, _ expected: CGSize, _ message: String) {
        expect(actual == expected, "\(message): expected \(expected), got \(actual)")
    }

    // A 1728 × 1117 pt screen with a 25 pt menu bar.
    static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1092)
    static let minSize = CGSize(width: 80, height: 80)

    static func main() {
        checkDisplaySize()
        checkResize()
        checkToolbar()
        checkOpacityAndPercent()
        print("Pinned geometry checks passed (\(checks) assertions).")
    }

    static func checkDisplaySize() {
        // A full Retina screenshot comes in at most 560 pt on its long side.
        same(PinnedScreenshotGeometry.displaySize(forPixelSize: CGSize(width: 3456, height: 2234), backingScale: 2),
             CGSize(width: 560, height: 362), "Large capture is capped")
        // A tiny one is enlarged to 160 pt, aspect kept.
        same(PinnedScreenshotGeometry.displaySize(forPixelSize: CGSize(width: 100, height: 50), backingScale: 2),
             CGSize(width: 160, height: 80), "Tiny capture is enlarged")
        // In range: shown at its size on screen.
        same(PinnedScreenshotGeometry.displaySize(forPixelSize: CGSize(width: 600, height: 400), backingScale: 2),
             CGSize(width: 300, height: 200), "Mid-sized capture keeps its size")
        same(PinnedScreenshotGeometry.displaySize(forPixelSize: CGSize(width: 1000, height: 1000), backingScale: 1),
             CGSize(width: 560, height: 560), "Non-Retina capture")
        same(PinnedScreenshotGeometry.displaySize(forPixelSize: CGSize(width: 600, height: 400), backingScale: 0),
             CGSize(width: 300, height: 200), "An unknown scale counts as 2x")
        same(PinnedScreenshotGeometry.displaySize(forPixelSize: .zero, backingScale: 2),
             CGSize(width: 320, height: 240), "An unreadable size falls back")
    }

    static func resized(_ frame: CGRect, by factor: CGFloat, around anchor: CGPoint? = nil) -> CGRect? {
        PinnedScreenshotGeometry.resizedFrame(
            frame,
            to: CGSize(width: frame.width * factor, height: frame.height * factor),
            around: anchor,
            minSize: minSize,
            visibleFrame: screen
        )
    }

    static func checkResize() {
        let pin = CGRect(x: 100, y: 100, width: 400, height: 200)

        // Keys zoom around the centre.
        same(resized(pin, by: 1.25), CGRect(x: 50, y: 75, width: 500, height: 250), "Zoom in keeps the centre")
        same(resized(pin, by: 0.8), CGRect(x: 140, y: 120, width: 320, height: 160), "Zoom out keeps the centre")

        // A pinch keeps the point under the pointer where it is.
        same(resized(pin, by: 2, around: CGPoint(x: 100, y: 100)),
             CGRect(x: 100, y: 100, width: 800, height: 400), "Anchored at the bottom-left corner")
        let centred = CGRect(x: 300, y: 300, width: 400, height: 200)
        same(resized(centred, by: 1.5, around: CGPoint(x: 600, y: 350)),
             CGRect(x: 150, y: 275, width: 600, height: 300), "The pointer stays over the same spot")

        // Never smaller than the minimum, aspect intact.
        let tiny = resized(pin, by: 0.05)!
        same(tiny.size, CGSize(width: 160, height: 80), "Shrinking stops at the minimum size")

        // Never larger than the screen, and pulled back onto it.
        let huge = resized(pin, by: 10)!
        same(huge.size, CGSize(width: 1728, height: 864), "Growing stops at the screen")
        expect(screen.contains(huge), "A pin grown to the screen's width stays on it: \(huge)")

        let nearEdge = CGRect(x: 1600, y: 500, width: 100, height: 100)
        let grown = resized(nearEdge, by: 2)!
        same(grown, CGRect(x: 1528, y: 450, width: 200, height: 200), "Growing past the right edge pulls back")

        // Shrinking leaves a pin the user parked half off screen where it is.
        let parked = CGRect(x: 1700, y: 500, width: 400, height: 200)
        same(resized(parked, by: 0.5), CGRect(x: 1800, y: 550, width: 200, height: 100),
             "Shrinking doesn't move a parked pin")

        expect(PinnedScreenshotGeometry.resizedFrame(pin, to: .zero, around: nil, minSize: minSize, visibleFrame: screen) == nil,
               "An empty size is ignored")
    }

    static func checkToolbar() {
        let size = CGSize(width: 232, height: 36)
        let gap: CGFloat = 8
        func toolbar(_ pin: CGRect) -> CGRect {
            PinnedScreenshotGeometry.toolbarFrame(size: size, pinFrame: pin, visibleFrame: screen, gap: gap)
        }

        // Below the pin, right edges aligned.
        same(toolbar(CGRect(x: 584, y: 510, width: 560, height: 63)),
             CGRect(x: 912, y: 466, width: 232, height: 36), "Below the pin's right edge")

        // A pin at the bottom of the screen gets it above.
        same(toolbar(CGRect(x: 584, y: 10, width: 560, height: 63)),
             CGRect(x: 912, y: 81, width: 232, height: 36), "Above a pin at the bottom")

        // A pin as tall as the screen: inside its bottom edge.
        same(toolbar(CGRect(x: 584, y: 0, width: 560, height: 1092)),
             CGRect(x: 912, y: 8, width: 232, height: 36), "Inside a full-height pin")

        // Never off screen sideways.
        expect(toolbar(CGRect(x: -40, y: 500, width: 160, height: 160)).minX == gap,
               "Kept off the left edge under a narrow pin")
        expect(toolbar(CGRect(x: 1650, y: 500, width: 160, height: 160)).maxX == screen.maxX - gap,
               "Kept off the right edge")
    }

    static func checkOpacityAndPercent() {
        expect(PinnedScreenshotGeometry.clampedOpacity(0.05) == PinnedScreenshotGeometry.minimumOpacity,
               "Fading stops at the minimum")
        expect(PinnedScreenshotGeometry.clampedOpacity(1.5) == 1, "Opacity tops out at 1")
        expect(PinnedScreenshotGeometry.clampedOpacity(0.55) == 0.55, "In-range opacity is kept")

        expect(PinnedScreenshotGeometry.zoomPercent(width: 560, actualWidth: 1728) == 32, "Percent of actual size")
        expect(PinnedScreenshotGeometry.zoomPercent(width: 1728, actualWidth: 1728) == 100, "Actual size is 100%")
        expect(PinnedScreenshotGeometry.zoomPercent(width: 560, actualWidth: 0) == nil, "No percent without a size")
    }
}
