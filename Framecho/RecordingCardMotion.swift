//
//  RecordingCardMotion.swift
//  Framecho
//
//  3D motion for the Studio's video card: a fixed base pose plus timed
//  motion cues that move the card to a target pose and back. The card stays
//  a flat plane; everything on it (video, pointer, keystroke caption) is
//  composed first and projected together.
//
//  Cues are stored in source time like ZoomCue, so cuts, trims and speed
//  changes never rewrite them. The editor-time timeline is derived from the
//  clip timeline and evaluated as a pure function of time, so scrubbing,
//  playback and 30/60 fps exports all resolve the same pose.
//

import CoreGraphics
import Foundation
import QuartzCore

// MARK: - Pose

nonisolated struct RecordingCardPose: Codable, Equatable, Sendable {
    /// Around the vertical axis. Positive turns the card to face right
    /// (its right edge recedes).
    var yawDegrees: Double
    /// Around the horizontal axis. Positive brings the bottom edge closer,
    /// as if looking down at the card.
    var pitchDegrees: Double
    /// In-plane rotation, clockwise on screen.
    var rollDegrees: Double
    /// Outer card scale around its center; independent of zoom cues.
    var scale: Double
    /// Card offset as a fraction of the canvas width.
    var translationX: Double
    /// Card offset as a fraction of the canvas height.
    var translationY: Double

    static let identity = RecordingCardPose(
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        scale: 1,
        translationX: 0,
        translationY: 0
    )

    static let yawRange: ClosedRange<Double> = -45...45
    static let pitchRange: ClosedRange<Double> = -45...45
    static let rollRange: ClosedRange<Double> = -30...30
    static let scaleRange: ClosedRange<Double> = 0.4...2
    static let translationRange: ClosedRange<Double> = -0.5...0.5

    init(
        yawDegrees: Double = 0,
        pitchDegrees: Double = 0,
        rollDegrees: Double = 0,
        scale: Double = 1,
        translationX: Double = 0,
        translationY: Double = 0
    ) {
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.scale = scale
        self.translationX = translationX
        self.translationY = translationY
    }

    private enum CodingKeys: String, CodingKey {
        case yawDegrees, pitchDegrees, rollDegrees, scale, translationX, translationY
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            yawDegrees: try container.decodeIfPresent(Double.self, forKey: .yawDegrees) ?? 0,
            pitchDegrees: try container.decodeIfPresent(Double.self, forKey: .pitchDegrees) ?? 0,
            rollDegrees: try container.decodeIfPresent(Double.self, forKey: .rollDegrees) ?? 0,
            scale: try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1,
            translationX: try container.decodeIfPresent(Double.self, forKey: .translationX) ?? 0,
            translationY: try container.decodeIfPresent(Double.self, forKey: .translationY) ?? 0
        )
        self = clamped
    }

    /// Every component finite and inside its supported range.
    var clamped: RecordingCardPose {
        RecordingCardPose(
            yawDegrees: Self.clamp(yawDegrees, Self.yawRange, fallback: 0),
            pitchDegrees: Self.clamp(pitchDegrees, Self.pitchRange, fallback: 0),
            rollDegrees: Self.clamp(rollDegrees, Self.rollRange, fallback: 0),
            scale: Self.clamp(scale, Self.scaleRange, fallback: 1),
            translationX: Self.clamp(translationX, Self.translationRange, fallback: 0),
            translationY: Self.clamp(translationY, Self.translationRange, fallback: 0)
        )
    }

    var isIdentity: Bool {
        abs(yawDegrees) < 0.0001
            && abs(pitchDegrees) < 0.0001
            && abs(rollDegrees) < 0.0001
            && abs(scale - 1) < 0.00001
            && abs(translationX) < 0.00001
            && abs(translationY) < 0.00001
    }

    static func interpolate(
        from start: RecordingCardPose,
        to end: RecordingCardPose,
        progress: Double
    ) -> RecordingCardPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        return RecordingCardPose(
            yawDegrees: mix(start.yawDegrees, end.yawDegrees),
            pitchDegrees: mix(start.pitchDegrees, end.pitchDegrees),
            rollDegrees: mix(start.rollDegrees, end.rollDegrees),
            scale: mix(start.scale, end.scale),
            translationX: mix(start.translationX, end.translationX),
            translationY: mix(start.translationY, end.translationY)
        )
    }

    private static func clamp(
        _ value: Double,
        _ range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Presets

nonisolated enum RecordingMotionPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiltLeft
    case tiltRight
    case topDown
    case gentleRoll
    case pushIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiltLeft: String(localized: "Tilt Left")
        case .tiltRight: String(localized: "Tilt Right")
        case .topDown: String(localized: "Top Down")
        case .gentleRoll: String(localized: "Gentle Roll")
        case .pushIn: String(localized: "Push In")
        }
    }

    var systemImage: String {
        switch self {
        case .tiltLeft: "rotate.left"
        case .tiltRight: "rotate.right"
        case .topDown: "rotate.3d"
        case .gentleRoll: "arrow.clockwise"
        case .pushIn: "plus.magnifyingglass"
        }
    }

    /// The preset's target relative to a base pose. Angles replace the
    /// base's so a preset always reads the same; scale and offset follow the
    /// base so a pushed-back card stays pushed back.
    func targetPose(from base: RecordingCardPose) -> RecordingCardPose {
        var pose = base
        switch self {
        case .tiltLeft:
            pose.yawDegrees = -18
            pose.pitchDegrees = 4
            pose.scale = base.scale * 0.94
        case .tiltRight:
            pose.yawDegrees = 18
            pose.pitchDegrees = 4
            pose.scale = base.scale * 0.94
        case .topDown:
            pose.pitchDegrees = 20
            pose.scale = base.scale * 0.94
        case .gentleRoll:
            pose.rollDegrees = -4
        case .pushIn:
            pose.scale = base.scale * 1.15
        }
        return pose.clamped
    }
}

// MARK: - Easing

/// How a motion's entrance or exit moves between the base pose and its
/// target. Stored per cue; projects from before easing was choosable
/// decode as `.smooth`, the curve every cue used until then.
nonisolated enum RecordingMotionEasing: String, CaseIterable, Codable, Identifiable, Sendable {
    case smooth
    case linear
    case easeIn
    case easeOut
    case overshoot
    case spring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: String(localized: "Smooth")
        case .linear: String(localized: "Linear")
        case .easeIn: String(localized: "Ease In")
        case .easeOut: String(localized: "Ease Out")
        case .overshoot: String(localized: "Overshoot")
        case .spring: String(localized: "Spring")
        }
    }

    /// Progress through a transition, 0 at its start and 1 at its end.
    /// Overshoot and spring pass beyond 1 before settling, so the card
    /// swings slightly past where it is heading.
    func value(at progress: Double) -> Double {
        let u = min(max(progress, 0), 1)
        switch self {
        case .smooth:
            // Quintic ease: zero velocity and acceleration at both ends.
            return u * u * u * (u * (u * 6 - 15) + 10)
        case .linear:
            return u
        case .easeIn:
            return u * u * u
        case .easeOut:
            let inverse = 1 - u
            return 1 - inverse * inverse * inverse
        case .overshoot:
            let c1 = 1.70158
            let c3 = c1 + 1
            let t = u - 1
            return 1 + c3 * t * t * t + c1 * t * t
        case .spring:
            guard u < 1 else { return 1 }
            let raw = 1 - exp(-6.5 * u) * cos(3 * .pi * u)
            // Corrects the curve's tiny miss at the end so it lands exactly.
            let endMiss = 1 - (1 - exp(-6.5) * cos(3 * .pi))
            return raw + endMiss * u
        }
    }
}

// MARK: - Cues

nonisolated struct RecordingMotionCue: Identifiable, Codable, Equatable, Sendable {
    /// Shortest cue the timeline will create or leave behind after a resize.
    static let minimumDuration: TimeInterval = 0.5
    static let defaultDuration: TimeInterval = 3
    static let defaultTransition: TimeInterval = 0.8
    static let transitionRange: ClosedRange<TimeInterval> = 0...5

    var id: UUID
    /// Source time, like ZoomCue.
    var start: TimeInterval
    /// Source time.
    var end: TimeInterval
    /// Output seconds spent moving from the base pose to the target.
    var enterDuration: TimeInterval
    /// Output seconds spent moving back to the base pose.
    var exitDuration: TimeInterval
    var targetPose: RecordingCardPose
    /// Curve of the move from the base pose to the target.
    var enterEasing: RecordingMotionEasing
    /// Curve of the move back to the base pose.
    var exitEasing: RecordingMotionEasing
    var isEnabled: Bool
    /// Reserved: start from the previous cue's target instead of the base
    /// pose. Always false in this version and not exposed in the editor.
    var chainsFromPrevious: Bool
    /// The preset the cue was created from, for its timeline label.
    var preset: RecordingMotionPreset?

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        enterDuration: TimeInterval = RecordingMotionCue.defaultTransition,
        exitDuration: TimeInterval = RecordingMotionCue.defaultTransition,
        targetPose: RecordingCardPose,
        enterEasing: RecordingMotionEasing = .smooth,
        exitEasing: RecordingMotionEasing = .smooth,
        isEnabled: Bool = true,
        chainsFromPrevious: Bool = false,
        preset: RecordingMotionPreset? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.enterDuration = enterDuration
        self.exitDuration = exitDuration
        self.targetPose = targetPose
        self.enterEasing = enterEasing
        self.exitEasing = exitEasing
        self.isEnabled = isEnabled
        self.chainsFromPrevious = chainsFromPrevious
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, enterDuration, exitDuration, targetPose, isEnabled
        case chainsFromPrevious, preset, enterEasing, exitEasing
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            start: try container.decode(TimeInterval.self, forKey: .start),
            end: try container.decode(TimeInterval.self, forKey: .end),
            enterDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .enterDuration)
                ?? Self.defaultTransition,
            exitDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .exitDuration)
                ?? Self.defaultTransition,
            targetPose: try container.decodeIfPresent(RecordingCardPose.self, forKey: .targetPose)
                ?? .identity,
            // An easing a newer version added reads as the original curve.
            enterEasing: (try? container.decodeIfPresent(RecordingMotionEasing.self, forKey: .enterEasing))
                .flatMap { $0 } ?? .smooth,
            exitEasing: (try? container.decodeIfPresent(RecordingMotionEasing.self, forKey: .exitEasing))
                .flatMap { $0 } ?? .smooth,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            chainsFromPrevious: try container.decodeIfPresent(Bool.self, forKey: .chainsFromPrevious)
                ?? false,
            preset: try? container.decodeIfPresent(RecordingMotionPreset.self, forKey: .preset)
        )
    }

    var duration: TimeInterval { end - start }

    var title: String {
        preset?.title ?? String(localized: "Motion")
    }
}

// MARK: - Settings

/// Everything the project stores about card motion.
nonisolated struct RecordingMotionSettings: Codable, Equatable, Sendable {
    /// Bumped whenever the projection math changes, so older projects keep
    /// rendering with the model they were made with.
    static let currentProjectionVersion = 1

    var isEnabled = false
    var basePose = RecordingCardPose.identity
    var cues: [RecordingMotionCue] = []
    var projectionVersion = RecordingMotionSettings.currentProjectionVersion

    init(
        isEnabled: Bool = false,
        basePose: RecordingCardPose = .identity,
        cues: [RecordingMotionCue] = [],
        projectionVersion: Int = RecordingMotionSettings.currentProjectionVersion
    ) {
        self.isEnabled = isEnabled
        self.basePose = basePose
        self.cues = cues
        self.projectionVersion = projectionVersion
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, basePose, cues, projectionVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        basePose = try container.decodeIfPresent(RecordingCardPose.self, forKey: .basePose) ?? .identity
        cues = (try container.decodeIfPresent([RecordingMotionCue].self, forKey: .cues) ?? [])
            .sorted { $0.start < $1.start }
        projectionVersion = try container.decodeIfPresent(Int.self, forKey: .projectionVersion)
            ?? Self.currentProjectionVersion
    }

    static let disabled = RecordingMotionSettings()

    /// True when the card can never leave its flat, unscaled pose, so the
    /// renderer may keep its original 2D path.
    var isInert: Bool {
        !isEnabled || (basePose.isIdentity && cues.allSatisfy { !$0.isEnabled || $0.targetPose.isIdentity })
    }
}

// MARK: - Timeline

/// Card poses along the edited (output) timeline.
nonisolated struct RecordingMotionTimeline: Equatable, Sendable {
    /// One cue resolved onto the editor timeline.
    struct Segment: Equatable, Sendable {
        var cueID: UUID
        var editorStart: TimeInterval
        var editorEnd: TimeInterval
        /// Effective transition lengths after fitting the visible range.
        var enter: TimeInterval
        var exit: TimeInterval
        var target: RecordingCardPose
        var enterEasing: RecordingMotionEasing = .smooth
        var exitEasing: RecordingMotionEasing = .smooth
    }

    let isEnabled: Bool
    let basePose: RecordingCardPose
    let segments: [Segment]
    let projectionVersion: Int

    static let disabled = RecordingMotionTimeline(
        isEnabled: false,
        basePose: .identity,
        segments: [],
        projectionVersion: RecordingMotionSettings.currentProjectionVersion
    )

    static func build(
        settings: RecordingMotionSettings,
        clipTimeline: RecordingClipTimeline
    ) -> RecordingMotionTimeline {
        guard settings.isEnabled else { return .disabled }
        var segments: [Segment] = []
        for cue in settings.cues.sorted(by: { $0.start < $1.start }) where cue.isEnabled {
            guard let segment = segment(for: cue, clipTimeline: clipTimeline) else { continue }
            // Source cues never overlap and cuts keep source order, so this
            // only guards against hand-edited project files.
            var resolved = segment
            if let previous = segments.last, resolved.editorStart < previous.editorEnd {
                resolved.editorStart = previous.editorEnd
                guard resolved.editorEnd - resolved.editorStart > 0.0001 else { continue }
                resolved = fitted(resolved, enter: cue.enterDuration, exit: cue.exitDuration)
            }
            segments.append(resolved)
        }
        return RecordingMotionTimeline(
            isEnabled: true,
            basePose: settings.basePose.clamped,
            segments: segments,
            projectionVersion: settings.projectionVersion
        )
    }

    /// The cue's visible range: from the first retained source instant to
    /// the last. Cuts inside the cue do not interrupt it, and cutting its
    /// head or tail rebuilds the full entrance or exit at the new edge.
    static func segment(
        for cue: RecordingMotionCue,
        clipTimeline: RecordingClipTimeline
    ) -> Segment? {
        let slices = clipTimeline.slices(overlapping: cue.start, sourceEnd: cue.end)
        guard let first = slices.first, let last = slices.last,
              last.editorEnd - first.editorStart > 0.0001 else { return nil }
        return fitted(
            Segment(
                cueID: cue.id,
                editorStart: first.editorStart,
                editorEnd: last.editorEnd,
                enter: 0,
                exit: 0,
                target: cue.targetPose.clamped,
                enterEasing: cue.enterEasing,
                exitEasing: cue.exitEasing
            ),
            enter: cue.enterDuration,
            exit: cue.exitDuration
        )
    }

    /// Shrinks the transitions proportionally when the visible range is
    /// shorter than both together; the hold never goes negative.
    private static func fitted(
        _ segment: Segment,
        enter requestedEnter: TimeInterval,
        exit requestedExit: TimeInterval
    ) -> Segment {
        var segment = segment
        let length = segment.editorEnd - segment.editorStart
        let enter = requestedEnter.isFinite ? max(requestedEnter, 0) : 0
        let exit = requestedExit.isFinite ? max(requestedExit, 0) : 0
        let total = enter + exit
        let factor = total > length && total > 0 ? length / total : 1
        segment.enter = enter * factor
        segment.exit = exit * factor
        return segment
    }

    /// True when no frame can ever differ from the flat card.
    var isIdentity: Bool {
        !isEnabled || (basePose.isIdentity && segments.allSatisfy { $0.target.isIdentity })
    }

    /// True when the pose never changes over time.
    var isStatic: Bool {
        !isEnabled || segments.allSatisfy { $0.target == basePose }
    }

    func pose(at editorTime: TimeInterval) -> RecordingCardPose {
        guard isEnabled else { return .identity }
        guard editorTime.isFinite,
              let segment = segments.first(where: {
                  editorTime >= $0.editorStart && editorTime < $0.editorEnd
              }) else {
            return basePose
        }
        // Each transition runs its curve forward in its own time, so an
        // exit that eases in leaves the target slowly.
        let progress: Double
        if segment.enter > 0, editorTime < segment.editorStart + segment.enter {
            progress = segment.enterEasing.value(at: (editorTime - segment.editorStart) / segment.enter)
        } else if segment.exit > 0, editorTime > segment.editorEnd - segment.exit {
            let exitProgress = (editorTime - (segment.editorEnd - segment.exit)) / segment.exit
            progress = 1 - segment.exitEasing.value(at: exitProgress)
        } else {
            progress = 1
        }
        return RecordingCardPose.interpolate(
            from: basePose,
            to: segment.target,
            progress: progress
        )
    }

    func segment(for cueID: UUID) -> Segment? {
        segments.first { $0.cueID == cueID }
    }

}

// MARK: - Projection

/// The card's 3D pose as one plane-to-canvas homography. The preview, the
/// exporter and editor hit-testing all project through this type, in canvas
/// space with a top-left origin.
nonisolated struct RecordingCardProjection: Sendable {
    /// Fixed lens, matching the screenshot camera's default.
    static let fieldOfViewDegrees: Double = 24

    let cardRect: CGRect
    let pose: RecordingCardPose
    /// False when the pose produced a degenerate plane; the projection then
    /// falls back to the flat card so preview and export still agree.
    let isValid: Bool
    let homography: ProjectiveHomography
    let inverse: ProjectiveHomography

    init(
        cardRect: CGRect,
        canvasSize: CGSize,
        pose requestedPose: RecordingCardPose,
        projectionVersion: Int = RecordingMotionSettings.currentProjectionVersion
    ) {
        let pose = requestedPose.clamped
        self.cardRect = cardRect
        self.pose = pose
        let corners = [
            CGPoint(x: cardRect.minX, y: cardRect.minY),
            CGPoint(x: cardRect.maxX, y: cardRect.minY),
            CGPoint(x: cardRect.maxX, y: cardRect.maxY),
            CGPoint(x: cardRect.minX, y: cardRect.maxY)
        ].map {
            Self.projectedPoint($0, cardRect: cardRect, canvasSize: canvasSize, pose: pose)
        }
        if cardRect.width > 0, cardRect.height > 0,
           corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
           let forward = ProjectiveHomography.mapping(
               cardRect,
               topLeft: corners[0],
               topRight: corners[1],
               bottomRight: corners[2],
               bottomLeft: corners[3]
           ),
           let inverted = forward.inverted() {
            isValid = true
            homography = forward
            inverse = inverted
        } else {
            isValid = pose.isIdentity
            homography = .identity
            inverse = .identity
        }
    }

    var isIdentity: Bool { pose.isIdentity || !isValid }

    func project(_ point: CGPoint) -> CGPoint {
        homography.applying(to: point)
    }

    func unproject(_ point: CGPoint) -> CGPoint {
        inverse.applying(to: point)
    }

    /// Projected corners of a card-plane rect: top-left, top-right,
    /// bottom-right, bottom-left.
    func quad(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ].map(project)
    }

    func bounds(of rect: CGRect) -> CGRect {
        let points = quad(for: rect)
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return rect }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The projection as a transform for a view whose local origin sits at
    /// `origin` in canvas space (SwiftUI `projectionEffect`, CALayer).
    func localTransform(origin: CGPoint) -> CATransform3D {
        let toCanvas = CATransform3DMakeTranslation(origin.x, origin.y, 0)
        let fromCanvas = CATransform3DMakeTranslation(-origin.x, -origin.y, 0)
        // Row-vector convention: applied left to right.
        return CATransform3DConcat(CATransform3DConcat(toCanvas, homography.caTransform), fromCanvas)
    }

    /// Projects a card-plane point through the pinhole camera: pitch, then
    /// yaw around the card center, perspective divide, in-plane roll, outer
    /// scale, then the canvas offset.
    static func projectedPoint(
        _ point: CGPoint,
        cardRect: CGRect,
        canvasSize: CGSize,
        pose: RecordingCardPose
    ) -> CGPoint {
        let pivot = CGPoint(x: cardRect.midX, y: cardRect.midY)
        var x = Double(point.x - pivot.x)
        var y = Double(point.y - pivot.y)
        var z = 0.0

        let pitch = pose.pitchDegrees * .pi / 180
        let rotatedY = y * cos(pitch) - z * sin(pitch)
        let rotatedZ = y * sin(pitch) + z * cos(pitch)
        y = rotatedY
        z = rotatedZ

        let yaw = pose.yawDegrees * .pi / 180
        let yawedX = x * cos(yaw) + z * sin(yaw)
        let yawedZ = -x * sin(yaw) + z * cos(yaw)
        x = yawedX
        z = yawedZ

        let longestEdge = Double(max(cardRect.width, cardRect.height, 1))
        let focalDistance = longestEdge * (
            0.35 + 0.5 / max(tan(fieldOfViewDegrees * .pi / 360), 0.01)
        )
        let perspective = focalDistance / max(focalDistance - z, focalDistance * 0.12)
        x *= perspective
        y *= perspective

        let roll = pose.rollDegrees * .pi / 180
        let rolledX = x * cos(roll) - y * sin(roll)
        let rolledY = x * sin(roll) + y * cos(roll)

        return CGPoint(
            x: pivot.x + CGFloat(rolledX * pose.scale + pose.translationX * Double(canvasSize.width)),
            y: pivot.y + CGFloat(rolledY * pose.scale + pose.translationY * Double(canvasSize.height))
        )
    }

    /// The largest factor every pose's scale can be multiplied by while the
    /// projected card stays inside the canvas. Used by "Fit to Canvas"; it
    /// is computed once and saved, never applied silently during playback.
    static func fittingScaleFactor(
        cardRect: CGRect,
        canvasSize: CGSize,
        poses: [RecordingCardPose]
    ) -> Double {
        guard cardRect.width > 0, cardRect.height > 0 else { return 1 }
        let pivot = CGPoint(x: cardRect.midX, y: cardRect.midY)
        var factor = Double.infinity
        for requested in poses {
            let pose = requested.clamped
            var unscaled = pose
            unscaled.scale = 1
            unscaled.translationX = 0
            unscaled.translationY = 0
            let offset = CGPoint(
                x: pose.translationX * Double(canvasSize.width),
                y: pose.translationY * Double(canvasSize.height)
            )
            let center = CGPoint(x: pivot.x + offset.x, y: pivot.y + offset.y)
            for corner in [
                CGPoint(x: cardRect.minX, y: cardRect.minY),
                CGPoint(x: cardRect.maxX, y: cardRect.minY),
                CGPoint(x: cardRect.maxX, y: cardRect.maxY),
                CGPoint(x: cardRect.minX, y: cardRect.maxY)
            ] {
                let raw = projectedPoint(corner, cardRect: cardRect, canvasSize: canvasSize, pose: unscaled)
                let dx = Double(raw.x - pivot.x)
                let dy = Double(raw.y - pivot.y)
                var limit = Double.infinity
                if dx > 0.0001 { limit = min(limit, Double(canvasSize.width - center.x) / dx) }
                if dx < -0.0001 { limit = min(limit, Double(center.x) / -dx) }
                if dy > 0.0001 { limit = min(limit, Double(canvasSize.height - center.y) / dy) }
                if dy < -0.0001 { limit = min(limit, Double(center.y) / -dy) }
                factor = min(factor, limit / max(pose.scale, 0.0001))
            }
        }
        guard factor.isFinite, factor > 0 else { return 1 }
        return factor
    }
}
