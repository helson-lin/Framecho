import CoreGraphics
import Foundation

// Compile the actual card-motion math and timeline, without launching the app:
// xcrun swiftc -module-cache-path /tmp/screendrop-motion-module-cache \
//   Screendrop/ProjectiveHomography.swift Screendrop/RecordingClipTimeline.swift \
//   Screendrop/RecordingCardMotion.swift scripts/check-card-motion.swift \
//   -o /tmp/screendrop-motion-check && /tmp/screendrop-motion-check
@main
struct CardMotionChecks {
    static var checks = 0

    static func near(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 0.0001) {
        checks += 1
        precondition(actual.isFinite && abs(actual - expected) < tolerance,
                     "\(message): expected \(expected), got \(actual)")
    }

    static func near(_ actual: CGPoint, _ expected: CGPoint, _ message: String, tolerance: Double = 0.0001) {
        near(Double(actual.x), Double(expected.x), message + " x", tolerance: tolerance)
        near(Double(actual.y), Double(expected.y), message + " y", tolerance: tolerance)
    }

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() {
        checkProjection()
        checkTimeline()
        checkClipMapping()
        checkPreviewMatchesExport()
        print("Card motion checks passed: \(checks)")
    }

    static func checkProjection() {
        let canvas = CGSize(width: 1920, height: 1080)
        let card = CGRect(x: 120, y: 80, width: 1680, height: 920)

        // Identity keeps every point in place.
        let identity = RecordingCardProjection(cardRect: card, canvasSize: canvas, pose: .identity)
        for point in [CGPoint(x: 120, y: 80), CGPoint(x: 1800, y: 1000), CGPoint(x: 400, y: 900)] {
            near(identity.project(point), point, "Identity projection")
        }

        // The homography reproduces the pinhole projection for any plane
        // point, not just the four corners it was built from.
        let poses = [
            RecordingCardPose(yawDegrees: 30, pitchDegrees: -12, rollDegrees: 8, scale: 0.85,
                              translationX: 0.05, translationY: -0.03),
            RecordingCardPose(yawDegrees: -45, pitchDegrees: 45, rollDegrees: -30, scale: 2),
            RecordingCardPose(pitchDegrees: 20)
        ]
        for pose in poses {
            let projection = RecordingCardProjection(cardRect: card, canvasSize: canvas, pose: pose)
            check(projection.isValid, "Pose in range must be valid")
            for point in [CGPoint(x: 500, y: 300), CGPoint(x: 1700, y: 950), CGPoint(x: 960, y: 540),
                          CGPoint(x: -100, y: 1200)] {
                let exact = RecordingCardProjection.projectedPoint(point, cardRect: card, canvasSize: canvas, pose: pose)
                near(projection.project(point), exact, "Homography matches pinhole", tolerance: 0.01)
                near(projection.unproject(projection.project(point)), point, "Inverse round trip", tolerance: 0.01)
            }
        }

        // Axis directions: positive yaw recedes the right edge; positive
        // pitch brings the bottom edge closer.
        let yawed = RecordingCardProjection(cardRect: card, canvasSize: canvas, pose: RecordingCardPose(yawDegrees: 20))
        let yawQuad = yawed.quad(for: card)
        let leftHeight = yawQuad[3].y - yawQuad[0].y
        let rightHeight = yawQuad[2].y - yawQuad[1].y
        check(rightHeight < leftHeight, "Positive yaw shrinks the right edge")
        let pitched = RecordingCardProjection(cardRect: card, canvasSize: canvas, pose: RecordingCardPose(pitchDegrees: 20))
        let pitchQuad = pitched.quad(for: card)
        check(pitchQuad[2].x - pitchQuad[3].x > pitchQuad[1].x - pitchQuad[0].x,
              "Positive pitch widens the bottom edge")
        let rolled = RecordingCardProjection(cardRect: card, canvasSize: canvas, pose: RecordingCardPose(rollDegrees: 10))
        check(rolled.quad(for: card)[1].y > CGFloat(card.minY), "Positive roll turns clockwise on screen")

        // Translation and scale.
        let moved = RecordingCardProjection(
            cardRect: card, canvasSize: canvas,
            pose: RecordingCardPose(scale: 0.5, translationX: 0.1, translationY: -0.1)
        )
        near(moved.project(CGPoint(x: card.midX, y: card.midY)), CGPoint(x: card.midX + 192, y: card.midY - 108),
             "Center follows translation")
        near(Double(moved.bounds(of: card).width), Double(card.width) * 0.5, "Scale halves width")

        // Non-finite and out-of-range input never produces NaN.
        let wild = RecordingCardProjection(
            cardRect: card, canvasSize: canvas,
            pose: RecordingCardPose(yawDegrees: .nan, pitchDegrees: 400, rollDegrees: -.infinity,
                                    scale: 0, translationX: 9, translationY: .nan)
        )
        check(wild.quad(for: card).allSatisfy { $0.x.isFinite && $0.y.isFinite }, "Wild input stays finite")
        near(wild.pose.pitchDegrees, 45, "Pitch clamps")
        near(wild.pose.scale, 0.4, "Scale clamps")

        // Fit to Canvas: after applying the factor every pose fits.
        let tilted = [RecordingCardPose(yawDegrees: 40, scale: 1.2), RecordingCardPose(pitchDegrees: -30)]
        let factor = RecordingCardProjection.fittingScaleFactor(cardRect: card, canvasSize: canvas, poses: tilted)
        check(factor < 1, "Wide tilt needs shrinking")
        for var pose in tilted {
            pose.scale *= factor
            let bounds = RecordingCardProjection(cardRect: card, canvasSize: canvas, pose: pose).bounds(of: card)
            check(bounds.minX >= -0.01 && bounds.minY >= -0.01
                  && bounds.maxX <= canvas.width + 0.01 && bounds.maxY <= canvas.height + 0.01,
                  "Fitted pose stays inside the canvas")
        }
    }

    static func checkTimeline() {
        let clips = RecordingClipTimeline.full(sourceDuration: 20)
        let target = RecordingCardPose(yawDegrees: 18, scale: 0.9)
        let cue = RecordingMotionCue(start: 3, end: 6, enterDuration: 0.8, exitDuration: 0.8, targetPose: target)
        let settings = RecordingMotionSettings(isEnabled: true, cues: [cue])
        let timeline = RecordingMotionTimeline.build(settings: settings, clipTimeline: clips)

        near(timeline.pose(at: 2.9).yawDegrees, 0, "Before cue")
        near(timeline.pose(at: 3).yawDegrees, 0, "Cue start is base")
        near(timeline.pose(at: 3.4).yawDegrees, 9, "Quintic midpoint is half")
        near(timeline.pose(at: 3.8).yawDegrees, 18, "Hold reaches target")
        near(timeline.pose(at: 5.2).yawDegrees, 18, "Hold before exit")
        near(timeline.pose(at: 5.6).yawDegrees, 9, "Exit midpoint")
        near(timeline.pose(at: 6).yawDegrees, 0, "Cue end is base")

        // Deterministic regardless of query order.
        let forward = stride(from: 0.0, through: 8, by: 0.05).map { timeline.pose(at: $0) }
        let backward = stride(from: 0.0, through: 8, by: 0.05).reversed().map { timeline.pose(at: $0) }
        check(forward == Array(backward.reversed()), "Scrubbing order does not matter")

        // Short cue: transitions shrink proportionally, hold is zero.
        let short = RecordingMotionCue(start: 1, end: 1.8, enterDuration: 0.8, exitDuration: 0.8, targetPose: target)
        let shortTimeline = RecordingMotionTimeline.build(
            settings: RecordingMotionSettings(isEnabled: true, cues: [short]), clipTimeline: clips
        )
        near(shortTimeline.segments[0].enter, 0.4, "Short enter")
        near(shortTimeline.segments[0].exit, 0.4, "Short exit")
        near(shortTimeline.pose(at: 1.4).yawDegrees, 18, "Short cue peaks")

        // Disabled settings and disabled cues stay flat.
        check(RecordingMotionTimeline.build(settings: RecordingMotionSettings(isEnabled: false, cues: [cue]),
                                            clipTimeline: clips).isIdentity, "Disabled timeline is identity")
        var off = cue
        off.isEnabled = false
        check(RecordingMotionTimeline.build(settings: RecordingMotionSettings(isEnabled: true, cues: [off]),
                                            clipTimeline: clips).isIdentity, "Disabled cue is identity")
        check(RecordingMotionSettings(isEnabled: true, cues: [off]).isInert, "Disabled cue is inert")
    }

    /// The Studio preview draws the same layout at a smaller canvas. Its
    /// projected corners, scaled up to the export size, must land within one
    /// output pixel of the export's corners for every pose.
    static func checkPreviewMatchesExport() {
        let exportCanvas = CGSize(width: 3840, height: 2160)
        let exportCard = CGRect(x: 230, y: 130, width: 3380, height: 1900)
        let poses = [
            RecordingCardPose(yawDegrees: 18, pitchDegrees: 4, scale: 0.94),
            RecordingCardPose(yawDegrees: -45, pitchDegrees: 45, rollDegrees: 30, scale: 0.6,
                              translationX: -0.2, translationY: 0.15),
            RecordingCardPose(pitchDegrees: -30, rollDegrees: -12, scale: 1.4)
        ]
        for previewScale in [0.21, 0.37, 0.5] as [CGFloat] {
            let previewCanvas = CGSize(width: exportCanvas.width * previewScale,
                                       height: exportCanvas.height * previewScale)
            let previewCard = CGRect(x: exportCard.minX * previewScale, y: exportCard.minY * previewScale,
                                     width: exportCard.width * previewScale, height: exportCard.height * previewScale)
            for pose in poses {
                let exported = RecordingCardProjection(cardRect: exportCard, canvasSize: exportCanvas, pose: pose)
                    .quad(for: exportCard)
                let previewed = RecordingCardProjection(cardRect: previewCard, canvasSize: previewCanvas, pose: pose)
                    .quad(for: previewCard)
                for (export, preview) in zip(exported, previewed) {
                    near(Double(preview.x / previewScale), Double(export.x), "Preview corner x matches export",
                         tolerance: 1)
                    near(Double(preview.y / previewScale), Double(export.y), "Preview corner y matches export",
                         tolerance: 1)
                }
            }
        }

        // Portrait canvases project the same way.
        let portrait = RecordingCardProjection(
            cardRect: CGRect(x: 60, y: 600, width: 960, height: 720),
            canvasSize: CGSize(width: 1080, height: 1920),
            pose: RecordingCardPose(yawDegrees: 20, translationY: 0.1)
        )
        check(portrait.isValid, "Portrait projection is valid")
        near(Double(portrait.project(CGPoint(x: 540, y: 960)).y), 960 + 192, "Portrait offset uses canvas height",
             tolerance: 0.001)
    }

    static func checkClipMapping() {
        let target = RecordingCardPose(yawDegrees: 20)
        let cue = RecordingMotionCue(start: 4, end: 8, enterDuration: 1, exitDuration: 1, targetPose: target)
        let settings = RecordingMotionSettings(isEnabled: true, cues: [cue])

        // Deleting video before the cue shifts it left.
        let shifted = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1),
            RecordingClipSegment(sourceStart: 3, sourceEnd: 20)
        ])
        var timeline = RecordingMotionTimeline.build(settings: settings, clipTimeline: shifted)
        near(timeline.segments[0].editorStart, 2, "Cue shifts with deleted range")
        near(timeline.segments[0].editorEnd, 6, "Cue end shifts")

        // Cutting through the middle keeps one continuous segment.
        let middleCut = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 5),
            RecordingClipSegment(sourceStart: 7, sourceEnd: 20)
        ])
        timeline = RecordingMotionTimeline.build(settings: settings, clipTimeline: middleCut)
        check(timeline.segments.count == 1, "Middle cut keeps one segment")
        near(timeline.segments[0].editorStart, 4, "Middle cut start")
        near(timeline.segments[0].editorEnd, 6, "Middle cut end")
        near(timeline.segments[0].enter, 1, "Middle cut keeps enter")
        near(timeline.pose(at: 4.99).yawDegrees, 20, "Across cut holds target", tolerance: 0.01)
        near(timeline.pose(at: 5.01).yawDegrees, 20, "After cut holds target", tolerance: 0.01)

        // Cutting the head rebuilds the entrance at the new edge.
        let headCut = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4),
            RecordingClipSegment(sourceStart: 6, sourceEnd: 20)
        ])
        timeline = RecordingMotionTimeline.build(settings: settings, clipTimeline: headCut)
        near(timeline.segments[0].editorStart, 4, "Head cut start")
        near(timeline.segments[0].editorEnd, 6, "Head cut end")
        near(timeline.pose(at: 4).yawDegrees, 0, "Head cut enters from base")
        near(timeline.pose(at: 5).yawDegrees, 20, "Head cut reaches target")

        // Speed change keeps transition seconds, scales the covered range.
        let fast = RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 0, sourceEnd: 20, speed: 2)])
        timeline = RecordingMotionTimeline.build(settings: settings, clipTimeline: fast)
        near(timeline.segments[0].editorStart, 2, "Fast start")
        near(timeline.segments[0].editorEnd, 4, "Fast end")
        near(timeline.segments[0].enter, 1, "Fast enter keeps seconds")
        near(timeline.pose(at: 3).yawDegrees, 20, "Fast cue peaks at hold-less middle")

        // Fully deleted cue disappears from the timeline but stays stored.
        let gone = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 3),
            RecordingClipSegment(sourceStart: 9, sourceEnd: 20)
        ])
        timeline = RecordingMotionTimeline.build(settings: settings, clipTimeline: gone)
        check(timeline.segments.isEmpty, "Deleted cue does not render")
        check(settings.cues.count == 1, "Deleted cue stays in the project")
    }
}
