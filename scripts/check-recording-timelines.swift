import CoreGraphics
import Foundation

// Builds the recording's camera (zoom) and pointer timelines from captured
// input, without a movie; see run-checks.sh for the files. Springs make exact
// values meaningless, so these check behaviour: when the camera moves, how
// far, that it never shows past the recording, and that cuts carry it along.
@main
struct RecordingTimelineChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func near(_ actual: Double, _ expected: Double, _ tolerance: Double, _ message: String) {
        expect(actual.isFinite && abs(actual - expected) <= tolerance, "\(message): expected \(expected), got \(actual)")
    }

    static func press(_ time: TimeInterval, _ x: Double, _ y: Double, _ phase: PointerPressEvent.PressPhase = .down) -> PointerPressEvent {
        PointerPressEvent(time: time, x: x, y: y, button: 0, phase: phase)
    }

    static func capture(presses: [PointerPressEvent] = [], travel: [PointerTravelSample] = []) -> PointerCaptureFile {
        PointerCaptureFile(travel: travel, presses: presses)
    }

    static func main() {
        checkCueSynthesis()
        checkCueStorage()
        checkViewport()
        checkViewportAcrossCuts()
        checkPointer()
        checkCursorStyles()
        checkClickEffects()
        print("Recording timeline checks passed (\(checks) assertions).")
    }

    // MARK: - Automatic zoom cues

    static func checkCueSynthesis() {
        expect(ZoomCueSynthesizer.cues(from: capture(), duration: 20).isEmpty, "No clicks, no zooms")
        expect(ZoomCueSynthesizer.cues(from: capture(presses: [press(5, 0.5, 0.5)]), duration: .nan).isEmpty,
               "No duration, no zooms")

        // A click zooms in just before it and holds for a while after.
        let one = ZoomCueSynthesizer.cues(from: capture(presses: [press(5, 0.2, 0.7)]), duration: 20)
        expect(one.count == 1, "One click, one zoom")
        near(one[0].start, 4.7, 1e-9, "Starts a moment before the click")
        near(one[0].end, 7.5, 1e-9, "Holds after it")
        expect(one[0].zoom == 1.5 && one[0].anchorMode == .pointerAnchor, "Follows the pointer at 1.5×")
        expect(one[0].pinnedPoint == CGPoint(x: 0.2, y: 0.7), "Remembers where the click was")

        // Releases, clicks off the recording and clicks in the last second are ignored.
        let ignored = ZoomCueSynthesizer.cues(from: capture(presses: [
            press(5, 0.5, 0.5, .up), press(6, 1.2, 0.5), press(7, 0.5, -0.1), press(19.5, 0.5, 0.5),
        ]), duration: 20)
        expect(ignored.isEmpty, "Ignored presses: \(ignored)")

        // Clicks close together become one continuous zoom; far apart, two.
        let joined = ZoomCueSynthesizer.cues(from: capture(presses: [press(5, 0.5, 0.5), press(8, 0.6, 0.5), press(12, 0.7, 0.5)]),
                                             duration: 30)
        expect(joined.count == 1, "Nearby clicks join: \(joined.map { ($0.start, $0.end) })")
        near(joined[0].end, 14.5, 1e-9, "…lasting to the last one's hold")
        let apart = ZoomCueSynthesizer.cues(from: capture(presses: [press(5, 0.5, 0.5), press(20, 0.5, 0.5)]), duration: 30)
        expect(apart.count == 2, "Distant clicks stay separate")

        // Order of capture doesn't matter.
        let shuffled = ZoomCueSynthesizer.cues(from: capture(presses: [press(20, 0.5, 0.5), press(5, 0.5, 0.5)]), duration: 30)
        expect(shuffled.map(\.start) == apart.map(\.start), "Sorted by time")

        // Clamped to the recording.
        let early = ZoomCueSynthesizer.cues(from: capture(presses: [press(0.1, 0.5, 0.5)]), duration: 20)
        expect(early[0].start > 0 && early[0].start < 0.01, "A click at the start zooms from the start")
        let late = ZoomCueSynthesizer.cues(from: capture(presses: [press(8.5, 0.5, 0.5)]), duration: 10)
        near(late[0].end, 9.2, 1e-9, "A late click lets the zoom out finish before the end")
    }

    static func checkCueStorage() {
        let cue = ZoomCue(start: 1, end: 3, zoom: 2.5, anchorMode: .pinnedAnchor,
                          pinnedPoint: CGPoint(x: 1.4, y: -0.2), boundsBias: 3)
        expect(cue.pinnedPoint == CGPoint(x: 1, y: 0) && cue.boundsBias == 1, "Out-of-range values are clamped")
        expect(cue.duration == 2, "Duration")

        let reread = try! JSONDecoder().decode(ZoomCue.self, from: try! JSONEncoder().encode(cue))
        expect(reread == cue, "A cue survives a save")

        // Projects from earlier builds stored less.
        let minimal = try! JSONDecoder().decode(ZoomCue.self, from: Data(#"{"start": 2, "end": 4}"#.utf8))
        expect(minimal.zoom == 2 && minimal.anchorMode == .pointerAnchor && minimal.isEnabled,
               "Missing fields take the defaults those builds used")
        let experimental = try! JSONDecoder().decode(ZoomCue.self, from: Data(#"{"start": 2, "end": 4, "anchorMode": "cursorPredictive"}"#.utf8))
        expect(experimental.anchorMode == .pointerAnchor, "A mode this build doesn't know follows the pointer")
    }

    // MARK: - Camera

    static func frames(_ timeline: ViewportTimeline, duration: TimeInterval) -> [ViewportFrame] {
        stride(from: 0.0, through: duration, by: 1.0 / 120).map { timeline.frame(at: $0) }
    }

    /// At magnification m the viewport is 1/m of the recording; its centre
    /// must stay far enough in that it never shows past an edge.
    static func staysInside(_ frame: ViewportFrame) -> Bool {
        let half = 0.5 / frame.magnification - 1e-6
        return frame.anchor.x >= half && frame.anchor.x <= 1 - half
            && frame.anchor.y >= half && frame.anchor.y <= 1 - half
    }

    static func checkViewport() {
        let full = RecordingClipTimeline.full(sourceDuration: 10)

        let still = ViewportTimeline.build(cues: [], capture: capture(), clipTimeline: full)
        expect(frames(still, duration: 10).allSatisfy { $0 == .identity }, "No cues: the camera never moves")

        // Zoom to a corner, held from 2 s to 7 s.
        let cue = ZoomCue(start: 2, end: 7, zoom: 2, anchorMode: .pinnedAnchor, pinnedPoint: CGPoint(x: 0.9, y: 0.15))
        let timeline = ViewportTimeline.build(cues: [cue], capture: capture(), clipTimeline: full)
        near(timeline.frame(at: 1).magnification, 1, 1e-3, "Not zoomed before the cue")
        let held = timeline.frame(at: 5)
        near(held.magnification, 2, 0.05, "Zoomed while the cue holds")
        expect(held.anchor.x > 0.6 && held.anchor.y < 0.4, "Framed toward the pinned corner: \(held.anchor)")
        near(timeline.frame(at: 9.9).magnification, 1, 0.05, "Zoomed back out after it")

        let all = frames(timeline, duration: 10)
        expect(all.allSatisfy(staysInside), "Never shows past the recording's edge")
        let jumps = zip(all, all.dropFirst()).map { abs($1.magnification - $0.magnification) }
        expect((jumps.max() ?? 0) < 0.05, "Zoom eases instead of jumping: largest step \(jumps.max() ?? 0)")

        // Out of range time reads the ends.
        expect(timeline.frame(at: -5) == timeline.frame(at: 0), "Before the start")
        expect(timeline.frame(at: 50) == timeline.frame(at: 10), "After the end")

        var off = cue
        off.isEnabled = false
        let disabled = ViewportTimeline.build(cues: [off], capture: capture(), clipTimeline: full)
        expect(frames(disabled, duration: 10).allSatisfy { abs($0.magnification - 1) < 1e-9 }, "A disabled cue does nothing")

        // Following the pointer stays inside even when the pointer hugs a corner.
        let travel = stride(from: 0.0, through: 10, by: 0.1).map {
            PointerTravelSample(time: $0, x: min(1, 0.5 + $0 / 10), y: max(0, 0.5 - $0 / 10))
        }
        let follow = ViewportTimeline.build(
            cues: [ZoomCue(start: 1, end: 9, zoom: 3)],
            capture: capture(travel: travel),
            clipTimeline: full
        )
        let followed = frames(follow, duration: 10)
        expect(followed.allSatisfy(staysInside), "Following the pointer never shows past an edge")
        expect(follow.frame(at: 8).anchor.x > follow.frame(at: 3).anchor.x, "The camera follows the pointer right")
    }

    static func checkViewportAcrossCuts() {
        // Cutting the first 10 s moves a zoom at 12-16 s to 2-6 s.
        let cut = RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 10, sourceEnd: 20)])
        let cue = ZoomCue(start: 12, end: 16, zoom: 2, anchorMode: .pinnedAnchor, pinnedPoint: CGPoint(x: 0.5, y: 0.5))
        let timeline = ViewportTimeline.build(cues: [cue], capture: capture(), clipTimeline: cut)
        near(timeline.frame(at: 1).magnification, 1, 1e-3, "Not zoomed before its new start")
        near(timeline.frame(at: 4.5).magnification, 2, 0.05, "Zoomed at its new time")

        // A sped-up clip plays faster but the camera doesn't move faster.
        let normal = ViewportTimeline.build(cues: [ZoomCue(start: 2, end: 20, zoom: 2, anchorMode: .pinnedAnchor)],
                                            capture: capture(), clipTimeline: .full(sourceDuration: 20))
        let fast = ViewportTimeline.build(cues: [ZoomCue(start: 2, end: 20, zoom: 2, anchorMode: .pinnedAnchor)],
                                          capture: capture(),
                                          clipTimeline: RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 0, sourceEnd: 20, speed: 2)]))
        let normalRamp = frames(normal, duration: 10).firstIndex { $0.magnification > 1.9 } ?? 0
        let fastRamp = frames(fast, duration: 10).firstIndex { $0.magnification > 1.9 } ?? 0
        let normalStart = frames(normal, duration: 10).firstIndex { $0.magnification > 1.01 } ?? 0
        let fastStart = frames(fast, duration: 10).firstIndex { $0.magnification > 1.01 } ?? 0
        expect(abs((normalRamp - normalStart) - (fastRamp - fastStart)) <= 2,
               "The zoom takes as long at 2× speed (\(fastRamp - fastStart) vs \(normalRamp - normalStart) frames)")
        expect(fastStart < normalStart, "…but starts earlier in the shorter edit")
    }

    // MARK: - Pointer

    static func checkPointer() {
        expect(PointerTimeline.build(capture: capture(), duration: 10).frame(at: 1) == nil, "No pointer data, no pointer")

        let travel = stride(from: 0.0, through: 2, by: 1.0 / 60).map {
            PointerTravelSample(time: $0, x: 0.1 + 0.4 * $0, y: 0.2 + 0.3 * $0)
        }
        let timeline = PointerTimeline.build(capture: capture(travel: travel), duration: 6)
        let end = timeline.frame(at: 5.5)!.location
        near(end.x, 0.9, 0.01, "Comes to rest where the pointer stopped (x)")
        near(end.y, 0.8, 0.01, "…(y)")
        let middle = timeline.frame(at: 1)!.location
        expect(middle.x > 0.2 && middle.x < 0.8, "In between halfway through: \(middle)")
        expect(timeline.frame(at: 1.5)!.location.x > middle.x, "Moves the way the pointer went")
        expect(timeline.frame(at: -1)?.location == timeline.frame(at: 0)?.location, "Clamped before the start")

        // A click shows its press effect around the click.
        let clicked = PointerTimeline.build(
            capture: capture(presses: [press(1, 0.5, 0.5), press(1.1, 0.5, 0.5, .up)],
                             travel: [PointerTravelSample(time: 0, x: 0.5, y: 0.5), PointerTravelSample(time: 3, x: 0.5, y: 0.5)]),
            duration: 4
        )
        expect(clicked.frame(at: 1.05)?.press != nil, "Press effect while clicking")
        expect(clicked.frame(at: 3.5)?.press == nil, "Gone well after")

        // An idle pointer can fade out.
        let still = [PointerTravelSample(time: 0, x: 0.5, y: 0.5), PointerTravelSample(time: 1, x: 0.6, y: 0.5)]
        let hiding = PointerTimeline.build(capture: capture(travel: still), duration: 8, hideAfterInactivity: 2)
        expect((hiding.frame(at: 0.5)?.opacity ?? 0) > 0.9, "Visible while moving")
        expect((hiding.frame(at: 7)?.opacity ?? 1) < 0.1, "Faded after a long pause")
        let showing = PointerTimeline.build(capture: capture(travel: still), duration: 8)
        expect((showing.frame(at: 7)?.opacity ?? 0) > 0.9, "Stays when hiding is off")

        // Cuts carry the pointer along with the video.
        let path = [PointerTravelSample(time: 0, x: 0.1, y: 0.5), PointerTravelSample(time: 12, x: 0.1, y: 0.5),
                    PointerTravelSample(time: 12.5, x: 0.9, y: 0.5), PointerTravelSample(time: 20, x: 0.9, y: 0.5)]
        let cut = PointerTimeline.build(capture: capture(travel: path), duration: 20,
                                        clipTimeline: RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 10, sourceEnd: 20)]))
        expect((cut.frame(at: 1)?.location.x ?? 1) < 0.3, "Before the move, at its new time")
        expect((cut.frame(at: 6)?.location.x ?? 0) > 0.8, "After the move, at its new time")
    }

    // MARK: - Cursor and click styles

    static func checkCursorStyles() {
        let arrow = PointerArtwork(
            artworkID: "arrow", imageData: Data([1]),
            anchorPoint: .init(x: 0, y: 0), referenceSize: .init(width: 16, height: 24)
        )
        let beam = PointerArtwork(
            artworkID: "beam", imageData: Data([2]),
            anchorPoint: .init(x: 4, y: 8), referenceSize: .init(width: 8, height: 16)
        )
        let travel = [PointerTravelSample(time: 0, x: 0.5, y: 0.5, kind: .move, artworkID: "beam")]
        var file = capture(travel: travel)
        file.artwork = [beam]
        let timeline = PointerTimeline.build(capture: file, duration: 2, fallbackArtwork: arrow)

        expect(timeline.artwork(id: "beam", style: .recorded) == beam, "Original keeps the recorded artwork")
        expect(timeline.artwork(id: "beam", style: .arrow) == arrow, "Arrow always uses the system arrow")
        for style in [RecordingCursorStyle.highlight, .dot, .ring, .crosshair] {
            guard let shape = timeline.artwork(id: "beam", style: style) else {
                expect(false, "\(style) artwork renders")
                continue
            }
            expect(shape.artworkID != beam.artworkID && !shape.imageData.isEmpty, "\(style) replaces the pointer")
            expect(shape.normalizedAnchor == CGPoint(x: 0.5, y: 0.5), "\(style) is centered on the pointer")
        }
        let shapeIDs = [RecordingCursorStyle.highlight, .dot, .ring, .crosshair]
            .compactMap { timeline.artwork(id: nil, style: $0)?.artworkID }
        expect(Set(shapeIDs).count == 4, "Shapes cache under their own IDs")
    }

    static func checkClickEffects() {
        func effect(_ kind: PointerPressEffectKind, _ progress: Double, scale: CGFloat = 1) -> PointerPressEffectGeometry {
            var appearance = PointerPressEffectAppearance()
            appearance.kind = kind
            appearance.scale = scale
            return PointerPressEffectStyle.geometry(
                progress: progress, referenceHeight: 1_080, cursorScale: 1, appearance: appearance
            )
        }

        let defaultRipple = PointerPressEffectStyle.geometry(progress: 0.5, referenceHeight: 1_080, cursorScale: 1)
        near(Double(defaultRipple.rippleRadius), Double(effect(.ripple, 0.5).rippleRadius), 1e-9,
             "The default appearance is the ripple")

        let ring = effect(.ring, 0.2)
        expect(ring.impactOpacity == 0 && ring.rippleOpacity > 0, "Ring draws only its ring")
        let pulse = effect(.pulse, 0.2)
        expect(pulse.rippleOpacity == 0 && pulse.impactOpacity > 0, "Pulse draws only its disc")

        for kind in PointerPressEffectKind.allCases {
            let early = effect(kind, 0.15)
            let late = effect(kind, 0.9)
            expect(max(late.impactRadius, late.rippleRadius) > max(early.impactRadius, early.rippleRadius),
                   "\(kind) grows")
            let end = effect(kind, 1)
            expect(end.impactOpacity < 0.01 && end.rippleOpacity < 0.01, "\(kind) has faded by the end")
        }

        near(Double(effect(.ring, 0.5, scale: 2).rippleRadius), 2 * Double(effect(.ring, 0.5).rippleRadius), 1e-9,
             "Size scales the effect")
        near(Double(effect(.ring, 0.5, scale: 10).rippleRadius),
             Double(effect(.ring, 0.5, scale: PointerPressEffectAppearance.scaleRange.upperBound).rippleRadius), 1e-9,
             "Size is clamped")
    }
}
