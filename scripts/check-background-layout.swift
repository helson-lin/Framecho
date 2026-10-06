import CoreGraphics
import Foundation

// Compile the screenshot background layout without launching the app:
// xcrun swiftc -module-cache-path /tmp/framecho-layout-module-cache \
//   Screendrop/AnnotationBackgroundLayout.swift Screendrop/AnnotationBackground.swift \
//   Screendrop/AnnotationShadowStyle.swift Screendrop/AnnotationSwatch.swift \
//   scripts/check-background-layout.swift -o /tmp/framecho-layout-check && /tmp/framecho-layout-check
@main
struct BackgroundLayoutChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func same(_ actual: CGRect, _ expected: CGRect, _ message: String) {
        let close = abs(actual.minX - expected.minX) < 1e-6 && abs(actual.minY - expected.minY) < 1e-6
            && abs(actual.width - expected.width) < 1e-6 && abs(actual.height - expected.height) < 1e-6
        expect(close, "\(message): expected \(expected), got \(actual)")
    }

    static func same(_ actual: CGSize, _ expected: CGSize, _ message: String) {
        expect(abs(actual.width - expected.width) < 1e-6 && abs(actual.height - expected.height) < 1e-6,
               "\(message): expected \(expected), got \(actual)")
    }

    static let wide = CGSize(width: 1000, height: 500)
    static let solid = AnnotationBackgroundStyle.solid(AnnotationBackgroundColor("ink", title: "Ink", red: 0.1, green: 0.1, blue: 0.1))

    static func layout(_ content: CGSize = wide, _ configure: (inout AnnotationBackgroundSettings) -> Void) -> AnnotationBackgroundLayout {
        var settings = AnnotationBackgroundSettings()
        configure(&settings)
        return AnnotationBackgroundLayout.make(contentSize: content, settings: settings)
    }

    static func main() {
        checkPlainScreenshot()
        checkBackground()
        checkAspectRatios()
        checkAlignment()
        checkBorder()
        checkCameraStage()
        checkDisplayScaling()
        checkInvariants()
        print("Background layout checks passed (\(checks) assertions).")
    }

    static func checkPlainScreenshot() {
        let plain = layout { _ in }
        same(plain.canvasSize, wide, "No background: the export is the screenshot")
        same(plain.imageRect, CGRect(origin: .zero, size: wide), "Image fills it")
        expect(plain.padding == 0, "No padding")

        let empty = layout(.zero) { $0.style = solid }
        expect(empty.canvasSize == .zero && empty.imageRect == .zero, "An empty image lays out as nothing")
    }

    static func checkBackground() {
        // Padding is a fraction of the shortest edge: 8% of 500 = 40 px.
        let framed = layout { $0.style = solid }
        expect(framed.padding == 40, "Default padding: \(framed.padding)")
        same(framed.canvasSize, CGSize(width: 1080, height: 580), "Canvas grows by the padding")
        same(framed.imageRect, CGRect(x: 40, y: 40, width: 1000, height: 500), "Image centred inside")

        let tight = layout { $0.style = solid; $0.padding = -0.2 }
        expect(tight.padding == 0, "Negative padding is no padding")
        same(tight.canvasSize, wide, "…so the canvas is the image")
    }

    static func checkAspectRatios() {
        let square = layout { $0.style = solid; $0.aspectRatio = .square }
        same(square.canvasSize, CGSize(width: 1080, height: 1080), "Square canvas")
        same(square.imageRect, CGRect(x: 40, y: 290, width: 1000, height: 500), "Image centred in the square")

        // A tall image in 16:9 grows sideways.
        let tall = layout(CGSize(width: 500, height: 1000)) { $0.style = solid; $0.aspectRatio = .sixteenNine }
        same(tall.canvasSize, CGSize(width: 1920, height: 1080), "16:9 around a tall image")
        same(tall.imageRect, CGRect(x: 710, y: 40, width: 500, height: 1000), "Centred horizontally")

        for ratio in AnnotationBackgroundAspectRatio.allCases {
            guard let value = ratio.value else { continue }
            let result = layout { $0.style = solid; $0.aspectRatio = ratio }
            expect(abs(result.canvasSize.width / result.canvasSize.height - value) < 1e-9, "\(ratio) canvas has its ratio")
        }
    }

    static func checkAlignment() {
        // An aligned edge loses its padding, so the image touches it.
        let topLeading = layout { $0.style = solid; $0.aspectRatio = .square; $0.alignment = .topLeading }
        same(topLeading.canvasSize, CGSize(width: 1040, height: 1040), "Two edges without padding")
        same(topLeading.imageRect, CGRect(x: 0, y: 0, width: 1000, height: 500), "Pinned to the top-left corner")

        let bottomTrailing = layout { $0.style = solid; $0.aspectRatio = .square; $0.alignment = .bottomTrailing }
        same(bottomTrailing.imageRect, CGRect(x: 40, y: 540, width: 1000, height: 500), "Pinned to the bottom-right corner")
        expect(bottomTrailing.imageRect.maxY == bottomTrailing.canvasSize.height, "Touches the bottom edge")
        expect(bottomTrailing.imageRect.maxX == bottomTrailing.canvasSize.width, "Touches the right edge")

        let top = layout { $0.style = solid; $0.aspectRatio = .square; $0.alignment = .top }
        expect(top.imageRect.minY == 0 && abs(top.imageRect.midX - top.canvasSize.width / 2) < 1e-9, "Top, centred across")
    }

    static func checkBorder() {
        func border(_ s: inout AnnotationBackgroundSettings) {
            s.border.isEnabled = true
            s.border.thickness = 0.012
        }

        // Border only: the export grows by exactly the ring, nothing more.
        let ring = layout { border(&$0); $0.aspectRatio = .square }
        same(ring.canvasSize, CGSize(width: 1012, height: 512), "6 px ring on each side; the ratio is ignored")
        same(ring.cardRect, CGRect(x: 0, y: 0, width: 1012, height: 512), "Card is the ring")
        same(ring.imageRect, CGRect(x: 6, y: 6, width: 1000, height: 500), "Image inside the ring")

        let framed = layout { border(&$0); $0.style = solid }
        same(framed.canvasSize, CGSize(width: 1092, height: 592), "Padding outside the ring")
        same(framed.imageRect, CGRect(x: 46, y: 46, width: 1000, height: 500), "Image inside both")

        let hidden = layout { border(&$0); $0.border.opacity = 0 }
        same(hidden.canvasSize, wide, "An invisible border adds nothing")
        expect(AnnotationScreenshotBorderSettings().pixelThickness(for: wide) == 0, "A border that's off is 0 px")
    }

    static func checkCameraStage() {
        // A camera move with no background still needs room to tilt into.
        let tilted = layout { $0.camera.tiltXDegrees = 12 }
        expect(tilted.padding == 90, "At least 18% breathing room: \(tilted.padding)")
        same(tilted.imageRect, CGRect(x: 90, y: 90, width: 1000, height: 500), "Centred")

        // The camera orbits the centre, so alignment is ignored while it's on.
        let aligned = layout { $0.camera.tiltXDegrees = 12; $0.style = solid; $0.alignment = .topLeading }
        same(aligned.imageRect, CGRect(x: 40, y: 40, width: 1000, height: 500), "Alignment ignored under a camera")

        // Blur that bleeds past the image needs the same room; clipped blur doesn't.
        let bleed = layout { $0.progressiveBlur.isEnabled = true; $0.progressiveBlur.edgeMode = .bleed }
        expect(bleed.padding == 90, "Bleeding scene blur gets a stage: \(bleed.padding)")
        let clipped = layout { $0.progressiveBlur.isEnabled = true; $0.progressiveBlur.edgeMode = .clipped }
        same(clipped.canvasSize, wide, "Clipped blur stays within the image")
    }

    static func checkDisplayScaling() {
        let framed = layout { $0.style = solid }
        let display = framed.scaled(to: CGRect(x: 100, y: 50, width: 540, height: 290))
        expect(display.scale == 0.5, "Half size on screen")
        same(display.imageFrame, CGRect(x: 120, y: 70, width: 500, height: 250), "Image on screen")
        same(display.cardFrame, display.imageFrame, "No border: card is the image")

        let none = AnnotationBackgroundLayout.make(contentSize: .zero, settings: AnnotationBackgroundSettings())
            .scaled(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        expect(none.scale == 1 && none.imageFrame == .zero, "Nothing to show")
    }

    /// Across every combination: the screenshot is never resized or cropped,
    /// and everything sits inside the canvas.
    static func checkInvariants() {
        var combinations = 0
        for content in [wide, CGSize(width: 500, height: 1000), CGSize(width: 333, height: 333)] {
            for ratio in AnnotationBackgroundAspectRatio.allCases {
                for alignment in AnnotationBackgroundAlignment.allCases {
                    for hasBackground in [false, true] {
                        for hasBorder in [false, true] {
                            for hasCamera in [false, true] {
                                let result = layout(content) {
                                    if hasBackground { $0.style = solid }
                                    $0.border.isEnabled = hasBorder
                                    if hasCamera { $0.camera.rollDegrees = 5 }
                                    $0.aspectRatio = ratio
                                    $0.alignment = alignment
                                }
                                let canvas = CGRect(origin: .zero, size: result.canvasSize).insetBy(dx: -1e-6, dy: -1e-6)
                                let label = "\(content) \(ratio) \(alignment) bg:\(hasBackground) border:\(hasBorder) camera:\(hasCamera)"
                                expect(abs(result.imageRect.width - content.width) < 1e-6
                                       && abs(result.imageRect.height - content.height) < 1e-6,
                                       "Image keeps its pixel size: \(label)")
                                expect(canvas.contains(result.cardRect), "Card inside the canvas: \(label)")
                                expect(result.cardRect.insetBy(dx: -1e-6, dy: -1e-6).contains(result.imageRect),
                                       "Image inside the card: \(label)")
                                combinations += 1
                            }
                        }
                    }
                }
            }
        }
        expect(combinations == 3 * 5 * 9 * 8, "Every combination ran")
    }
}
