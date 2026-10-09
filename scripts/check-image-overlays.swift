import CoreGraphics
import Foundation

// Image overlays without a movie: their layout on the canvas, the placement
// presets, fades, how cuts carry them, and how saved projects decode. See
// run-checks.sh for the files.
@main
struct ImageOverlayChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        expect(abs(actual - expected) < 0.000_1, "\(message): expected \(expected), got \(actual)")
    }

    static func overlay(start: Double = 2, end: Double = 6, aspect: Double = 2, width: Double = 0.25) -> RecordingImageOverlay {
        RecordingImageOverlay(fileName: "a.png", displayName: "a", aspectRatio: aspect, start: start, end: end, width: width)
    }

    static func main() {
        checkLayout()
        checkAnchors()
        checkCaptionClearance()
        checkSnapping()
        checkFades()
        checkCuts()
        checkDecoding()
        print("Image overlay checks passed (\(checks) assertions).")
    }

    static func checkLayout() {
        let canvas = CGSize(width: 1920, height: 1080)
        let rect = RecordingImageOverlayLayout.rect(for: overlay(), canvasSize: canvas)
        near(rect.width, 480, "width is a share of the canvas width")
        near(rect.height, 240, "height follows the image's aspect")
        near(rect.midX, 960, "centered by default")
        near(rect.midY, 540, "centered by default")

        var rounded = overlay()
        rounded.cornerRadius = 0.5
        near(RecordingImageOverlayLayout.cornerRadius(for: rounded, in: rect), 120, "half the shorter side makes a pill")

        var broken = overlay()
        broken.width = .nan
        broken.aspectRatio = 0
        broken.opacity = 7
        broken.center = CGPoint(x: -3, y: CGFloat.infinity)
        let fixed = broken.sanitized
        expect(fixed.width == RecordingImageOverlay.defaultWidth, "a broken width falls back")
        expect(fixed.aspectRatio == 1, "a broken aspect falls back")
        expect(fixed.opacity == 1, "opacity is clamped")
        expect(fixed.center == CGPoint(x: 0, y: 0.5), "the center stays on the canvas")
        let safeRect = RecordingImageOverlayLayout.rect(for: broken, canvasSize: canvas)
        expect(safeRect.width.isFinite && safeRect.height.isFinite, "layout never produces NaN")
    }

    static func placed(_ overlay: RecordingImageOverlay, at anchor: RecordingImageOverlayAnchor?) -> RecordingImageOverlay {
        var placed = overlay
        placed.anchor = anchor
        return placed
    }

    static func checkAnchors() {
        let canvas = CGSize(width: 1920, height: 1080)
        let margin = RecordingImageOverlay.edgeMargin * 1080
        for anchor in RecordingImageOverlayAnchor.allCases {
            let rect = RecordingImageOverlayLayout.rect(for: placed(overlay(), at: anchor), canvasSize: canvas)
            expect(rect.minX >= margin - 0.01 && rect.maxX <= 1920 - margin + 0.01, "\(anchor) stays inside the margin horizontally")
            expect(rect.minY >= margin - 0.01 && rect.maxY <= 1080 - margin + 0.01, "\(anchor) stays inside the margin vertically")
            expect(RecordingImageOverlayAnchor(column: anchor.column, row: anchor.row) == anchor, "\(anchor) round-trips its grid cell")
        }
        let corner = RecordingImageOverlayLayout.rect(for: placed(overlay(), at: .bottomTrailing), canvasSize: canvas)
        near(corner.maxX, 1920 - margin, "bottom-right hugs the right margin")
        near(corner.maxY, 1080 - margin, "bottom-right hugs the bottom margin")

        // A preset is resolved per canvas, so switching to 9:16 keeps the
        // image in its corner instead of where the old canvas put it.
        let portrait = CGSize(width: 1080, height: 1920)
        let moved = RecordingImageOverlayLayout.rect(for: placed(overlay(), at: .bottomTrailing), canvasSize: portrait)
        near(moved.maxX, 1080 - margin, "after a 9:16 switch it still hugs the right margin")
        near(moved.maxY, 1920 - margin, "after a 9:16 switch it still hugs the bottom margin")

        var free = placed(overlay(), at: nil)
        free.center = CGPoint(x: 0.3, y: 0.4)
        let freeRect = RecordingImageOverlayLayout.rect(for: free, canvasSize: canvas)
        near(freeRect.midX, 576, "a free image keeps its own center")

        let huge = placed(overlay(aspect: 0.5, width: 1), at: .top)
        expect(RecordingImageOverlayLayout.center(for: huge, canvasSize: canvas).y == 0.5,
               "an image taller than the canvas centers instead of running off")
    }

    static func checkCaptionClearance() {
        let canvas = CGSize(width: 1920, height: 1080)
        let margin = RecordingImageOverlay.edgeMargin * 1080
        let band = RecordingImageOverlayLayout.captionBand(canvasSize: canvas, verticalPosition: 0.92, fontSize: 34.56)
        expect(band.contains(1080 * 0.92), "the band surrounds the bar's center")
        expect(band.upperBound - band.lowerBound > 34.56 * 2.2, "the band leaves room for two lines")

        let logo = placed(overlay(), at: .bottomTrailing)
        let clear = RecordingImageOverlayLayout.rect(for: logo, canvasSize: canvas, captionBand: band)
        near(clear.maxY, band.lowerBound - margin, "the bottom row stops above the captions")
        let top = RecordingImageOverlayLayout.rect(for: placed(overlay(), at: .topLeading), canvasSize: canvas, captionBand: band)
        near(top.minY, margin, "the top row ignores captions at the bottom")

        let raised = RecordingImageOverlayLayout.captionBand(canvasSize: canvas, verticalPosition: 0.1, fontSize: 34.56)
        let below = RecordingImageOverlayLayout.rect(for: placed(overlay(), at: .top), canvasSize: canvas, captionBand: raised)
        near(below.minY, raised.upperBound + margin, "captions moved to the top push the top row down")
        let bottom = RecordingImageOverlayLayout.rect(for: logo, canvasSize: canvas, captionBand: raised)
        near(bottom.maxY, 1080 - margin, "and leave the bottom row at the margin")
    }

    static func checkSnapping() {
        let canvas = CGSize(width: 1920, height: 1080)
        let image = placed(overlay(), at: nil)
        let corner = RecordingImageOverlayAnchor.bottomTrailing.center(for: image, canvasSize: canvas)

        let near = RecordingImageOverlayLayout.snapped(
            center: CGPoint(x: corner.x - 3 / 1920, y: corner.y + 4 / 1080),
            for: image, canvasSize: canvas, threshold: 6
        )
        expect(near.anchor == .bottomTrailing, "a drop within the threshold of a preset becomes that preset")
        expect(near.center == corner, "and lands on it exactly")

        let edge = RecordingImageOverlayLayout.snapped(
            center: CGPoint(x: corner.x - 2 / 1920, y: 0.3),
            for: image, canvasSize: canvas, threshold: 6
        )
        expect(edge.anchor == nil, "snapping one axis leaves the image free")
        expect(edge.center.x == corner.x && edge.center.y == 0.3, "but lines it up with the column")

        let away = CGPoint(x: 0.37, y: 0.41)
        let loose = RecordingImageOverlayLayout.snapped(center: away, for: image, canvasSize: canvas, threshold: 6)
        expect(loose.anchor == nil && loose.center == away, "far from every line it stays where dropped")
    }

    static func checkFades() {
        let timeline = RecordingImageOverlayTimeline(
            overlays: [overlay(start: 2, end: 6)],
            clipTimeline: .full(sourceDuration: 10)
        )
        expect(timeline.frames(at: 1.99).isEmpty, "nothing before the start")
        expect(timeline.frames(at: 6).isEmpty, "nothing at the end")
        near(timeline.frames(at: 2.15)[0].opacity, 0.5, "half way through the fade in")
        near(timeline.frames(at: 4)[0].opacity, 1, "full strength in the middle")
        near(timeline.frames(at: 5.85)[0].opacity, 0.5, "half way through the fade out")

        var dim = overlay(start: 2, end: 6)
        dim.opacity = 0.5
        dim.fades = false
        let flat = RecordingImageOverlayTimeline(overlays: [dim], clipTimeline: .full(sourceDuration: 10))
        near(flat.frames(at: 2.01)[0].opacity, 0.5, "no fade cuts straight in at its own opacity")

        let short = RecordingImageOverlayTimeline(
            overlays: [overlay(start: 2, end: 2.6)],
            clipTimeline: .full(sourceDuration: 10)
        )
        near(short.frames(at: 2.3)[0].opacity, 1, "a short image still reaches full strength")

        var first = overlay(start: 1, end: 5)
        first.fileName = "first.png"
        var second = overlay(start: 3, end: 7)
        second.fileName = "second.png"
        let stacked = RecordingImageOverlayTimeline(overlays: [first, second], clipTimeline: .full(sourceDuration: 10))
        expect(stacked.frames(at: 4).map(\.overlay.fileName) == ["first.png", "second.png"], "overlaps draw in stacking order")
    }

    static func checkCuts() {
        // Cut 3–4 s of the source out of a 10 s recording.
        let cut = RecordingClipTimeline.full(sourceDuration: 10).removingSourceRanges([3...4])!
        let timeline = RecordingImageOverlayTimeline(overlays: [overlay(start: 2, end: 6)], clipTimeline: cut)
        let placement = timeline.placements[0]
        near(placement.editorStart, 2, "starts where its footage plays")
        near(placement.editorEnd, 5, "a cut inside shortens it")

        let gone = RecordingImageOverlayTimeline(
            overlays: [overlay(start: 3.2, end: 3.8)],
            clipTimeline: cut
        )
        expect(gone.isEmpty, "an image whose footage was all cut is gone")

        let faster = RecordingClipTimeline.full(sourceDuration: 10).settingSpeed(2, forEditorRange: 0...10)
        let sped = RecordingImageOverlayTimeline(overlays: [overlay(start: 2, end: 6)], clipTimeline: faster)
        near(sped.placements[0].editorStart, 1, "a sped-up clip brings it forward")
        near(sped.placements[0].editorEnd, 3, "and shortens it with the footage")
    }

    static func checkDecoding() {
        let minimal = Data(#"{"fileName":"logo.png","start":1,"end":3}"#.utf8)
        let decoded = try! JSONDecoder().decode(RecordingImageOverlay.self, from: minimal)
        expect(decoded.displayName == "logo.png", "the display name falls back to the file")
        expect(decoded.center == CGPoint(x: 0.5, y: 0.5), "centered by default")
        expect(decoded.anchor == nil, "a project without an anchor places freely")
        let future = Data(#"{"fileName":"a.png","start":0,"end":1,"anchor":"somewhere-new"}"#.utf8)
        expect(try! JSONDecoder().decode(RecordingImageOverlay.self, from: future).anchor == nil,
               "an unknown anchor reads as a free placement")
        expect(decoded.fades && !decoded.hasShadow && decoded.opacity == 1, "look defaults")

        var full = overlay()
        full.hasShadow = true
        full.cornerRadius = 0.2
        let roundTrip = try! JSONDecoder().decode(RecordingImageOverlay.self, from: JSONEncoder().encode(full))
        expect(roundTrip == full, "every field round-trips")
    }
}
