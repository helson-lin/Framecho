//
//  RecordingPoseBall.swift
//  Framecho
//
//  The rotation ball that steers a card pose: an outer ring rotates the card
//  in the screen plane, a horizontal ring turns it, a vertical ring tilts it,
//  and a drag inside the ball turns and tilts freely like a trackball. The
//  geometry is shared by the ball drawn on the Studio canvas and the smaller
//  one in the inspector, so both steer the same way.
//

import AppKit
import SwiftUI

nonisolated enum RecordingPoseBallGeometry {
    /// Which part of the ball a drag grabbed.
    enum Mode: Equatable, Sendable {
        case trackball
        case turn
        case tilt
        case rotate
    }

    /// Vertical squash of the turn and tilt rings, which is what makes the
    /// ball read as a sphere rather than a flat target.
    static let ringDepth: CGFloat = 0.34
    /// How close to a ring a press must land to grab it.
    static let ringGrabDistance: CGFloat = 7
    /// How far a turn, tilt or trackball drag turns the card per point. Fixed
    /// rather than tied to the ball's size, so a small ball isn't coarser to
    /// steer than a large one.
    static let degreesPerPoint: Double = 0.6

    /// The ring or interior under `offset` from the ball's center, or nil
    /// outside the ball.
    static func mode(at offset: CGSize, radius: CGFloat) -> Mode? {
        let dx = offset.width
        let dy = offset.height
        let distance = hypot(dx, dy)
        if abs(distance - radius) <= ringGrabDistance {
            return .rotate
        }
        guard distance < radius else { return nil }
        if distanceToEllipse(radii: CGSize(width: radius, height: radius * ringDepth), dx: dx, dy: dy)
            <= ringGrabDistance {
            return .turn
        }
        if distanceToEllipse(radii: CGSize(width: radius * ringDepth, height: radius), dx: dx, dy: dy)
            <= ringGrabDistance {
            return .tilt
        }
        return .trackball
    }

    /// The pose a drag has reached, measured from where it started so events
    /// never compound. Shift keeps a trackball drag to one direction and
    /// snaps a ring drag to 15° steps.
    static func pose(
        dragging mode: Mode,
        from start: RecordingCardPose,
        startLocation: CGPoint,
        location: CGPoint,
        center: CGPoint,
        constrained: Bool
    ) -> RecordingCardPose {
        var dx = Double(location.x - startLocation.x)
        var dy = Double(location.y - startLocation.y)
        var pose = start

        switch mode {
        case .trackball:
            if constrained {
                if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
            }
            // Like rolling the ball: dragging right sends the card's right
            // edge away, dragging down sends its bottom away.
            pose.yawDegrees = detent(start.yawDegrees + dx * degreesPerPoint)
            pose.pitchDegrees = detent(start.pitchDegrees - dy * degreesPerPoint)
        case .turn:
            pose.yawDegrees = snapped(start.yawDegrees + dx * degreesPerPoint, constrained)
        case .tilt:
            pose.pitchDegrees = snapped(start.pitchDegrees - dy * degreesPerPoint, constrained)
        case .rotate:
            let startAngle = atan2(Double(startLocation.y - center.y), Double(startLocation.x - center.x))
            let angle = atan2(Double(location.y - center.y), Double(location.x - center.x))
            var delta = (angle - startAngle) * 180 / .pi
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            pose.rollDegrees = snapped(start.rollDegrees + delta, constrained)
        }
        return pose
    }

    /// Yaw as a point travelling around the horizontal ring's front.
    static func turnMarker(pose: RecordingCardPose, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = pose.yawDegrees * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(sin(angle)),
            y: center.y + radius * ringDepth * CGFloat(cos(angle))
        )
    }

    /// Pitch as a point travelling around the vertical ring's front.
    static func tiltMarker(pose: RecordingCardPose, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = pose.pitchDegrees * .pi / 180
        return CGPoint(
            x: center.x + radius * ringDepth * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    /// Roll as a point on the outer ring, starting at the top.
    static func rotateMarker(pose: RecordingCardPose, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = pose.rollDegrees * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(sin(angle)),
            y: center.y - radius * CGFloat(cos(angle))
        )
    }

    /// Lands exactly on zero when a drag passes close to it.
    static func detent(_ degrees: Double) -> Double {
        abs(degrees) < 1.5 ? 0 : degrees
    }

    static func snapped(_ degrees: Double, _ constrained: Bool) -> Double {
        constrained ? (degrees / 15).rounded() * 15 : detent(degrees)
    }

    /// Approximate distance from a point to an axis-aligned ellipse's curve.
    private static func distanceToEllipse(radii: CGSize, dx: CGFloat, dy: CGFloat) -> CGFloat {
        guard radii.width > 0, radii.height > 0 else { return .infinity }
        let normalized = hypot(dx / radii.width, dy / radii.height)
        guard normalized > 0 else { return min(radii.width, radii.height) }
        let gradient = hypot(dx / (radii.width * radii.width), dy / (radii.height * radii.height))
        return abs(normalized * normalized - 1) / (2 * max(gradient, 0.0001))
    }
}

/// The ball's drawing: a shaded sphere, its three rings and a marker on each
/// showing where the card's front faces. Fills a square frame of twice
/// `radius`; it never takes clicks, so the host decides what a press does.
struct RecordingPoseBallFace: View {
    let pose: RecordingCardPose
    let radius: CGFloat
    /// The ring being dragged or hovered, drawn heavier.
    var activeMode: RecordingPoseBallGeometry.Mode?

    var body: some View {
        let center = CGPoint(x: radius, y: radius)
        let depth = RecordingPoseBallGeometry.ringDepth
        let turnRing = Path(ellipseIn: CGRect(x: 0, y: radius - radius * depth, width: radius * 2, height: radius * 2 * depth))
        let tiltRing = Path(ellipseIn: CGRect(x: radius - radius * depth, y: 0, width: radius * 2 * depth, height: radius * 2))
        let rotateRing = Path(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2))

        ZStack(alignment: .topLeading) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.28), Color.black.opacity(0.18)],
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: radius * 1.2
                    )
                )

            ring(rotateRing, color: .blue, isActive: activeMode == .rotate, width: 2.5)
            ring(turnRing, color: .green, isActive: activeMode == .turn)
            ring(tiltRing, color: .red, isActive: activeMode == .tilt)

            marker(at: RecordingPoseBallGeometry.turnMarker(pose: pose, center: center, radius: radius), color: .green)
            marker(at: RecordingPoseBallGeometry.tiltMarker(pose: pose, center: center, radius: radius), color: .red)
            marker(at: RecordingPoseBallGeometry.rotateMarker(pose: pose, center: center, radius: radius), color: .blue)

            Circle()
                .fill(Color.white.opacity(activeMode == .trackball ? 0.9 : 0.6))
                .frame(width: 6, height: 6)
                .position(center)
        }
        .frame(width: radius * 2, height: radius * 2)
        .allowsHitTesting(false)
    }

    private func ring(_ path: Path, color: Color, isActive: Bool, width: CGFloat = 2) -> some View {
        path
            .stroke(color.opacity(isActive ? 1 : 0.75), lineWidth: isActive ? width + 1.5 : width)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
    }

    private func marker(at point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .frame(width: 9, height: 9)
            .position(point)
    }
}

/// A self-contained rotation ball for the inspector: the same rings and
/// trackball as the canvas ball, steering whichever pose it is given.
struct RecordingPoseBallControl: View {
    let pose: RecordingCardPose
    let onChange: (RecordingCardPose) -> Void
    var radius: CGFloat = 46

    @State private var drag: (pose: RecordingCardPose, location: CGPoint, mode: RecordingPoseBallGeometry.Mode)?
    @State private var hoverMode: RecordingPoseBallGeometry.Mode?

    var body: some View {
        let center = CGPoint(x: radius, y: radius)
        RecordingPoseBallFace(pose: pose, radius: radius, activeMode: drag?.mode ?? hoverMode)
            .background(
                Circle().fill(Color.primary.opacity(0.06))
            )
            // Room for the outer ring's grab margin.
            .padding(RecordingPoseBallGeometry.ringGrabDistance)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let inset = RecordingPoseBallGeometry.ringGrabDistance
                        let start = CGPoint(x: value.startLocation.x - inset, y: value.startLocation.y - inset)
                        let location = CGPoint(x: value.location.x - inset, y: value.location.y - inset)
                        if drag == nil {
                            guard let mode = RecordingPoseBallGeometry.mode(
                                at: CGSize(width: start.x - center.x, height: start.y - center.y),
                                radius: radius
                            ) else { return }
                            drag = (pose, start, mode)
                        }
                        guard let drag else { return }
                        onChange(RecordingPoseBallGeometry.pose(
                            dragging: drag.mode,
                            from: drag.pose,
                            startLocation: drag.location,
                            location: location,
                            center: center,
                            constrained: NSEvent.modifierFlags.contains(.shift)
                        ))
                    }
                    .onEnded { _ in drag = nil }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let inset = RecordingPoseBallGeometry.ringGrabDistance
                    hoverMode = RecordingPoseBallGeometry.mode(
                        at: CGSize(width: location.x - inset - center.x, height: location.y - inset - center.y),
                        radius: radius
                    )
                case .ended:
                    hoverMode = nil
                }
            }
            .help(helpText)
            .accessibilityElement()
            .accessibilityLabel("Rotation")
            .accessibilityValue(Text(accessibilitySummary))
            .accessibilityAdjustableAction { direction in
                var updated = pose
                updated.yawDegrees += direction == .increment ? 5 : -5
                onChange(updated)
            }
    }

    private var helpText: String {
        switch hoverMode {
        case .turn: String(localized: "Drag the green ring to turn the card left or right")
        case .tilt: String(localized: "Drag the red ring to tilt the card up or down")
        case .rotate: String(localized: "Drag the blue ring to rotate the card. Hold Shift for 15° steps.")
        case .trackball, nil: String(localized: "Drag inside the ball to turn and tilt freely. Hold Shift to keep to one direction.")
        }
    }

    private var accessibilitySummary: String {
        let degrees = InspectorValueFormat.degrees(signed: true)
        let turn = degrees.displayString(for: CGFloat(pose.yawDegrees))
        let tilt = degrees.displayString(for: CGFloat(pose.pitchDegrees))
        let rotate = degrees.displayString(for: CGFloat(pose.rollDegrees))
        return String(localized: "Turn \(turn) · Tilt \(tilt) · Rotate \(rotate)")
    }
}

/// Where the card sits on the canvas, as a dot on a small frame of the
/// canvas. Dragging moves it; a double-click centers it again.
struct RecordingPosePositionPad: View {
    /// Offsets as fractions of the canvas, within `RecordingCardPose.translationRange`.
    let translation: CGPoint
    let canvasAspect: CGFloat
    let onChange: (CGPoint) -> Void

    @State private var isDragging = false

    private static var range: ClosedRange<Double> { RecordingCardPose.translationRange }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let point = CGPoint(
                x: (normalized(translation.x)) * size.width,
                y: (normalized(translation.y)) * size.height
            )
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                Path { path in
                    path.move(to: CGPoint(x: size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: isDragging ? 13 : 11, height: isDragging ? 13 : 11)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .position(point)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        var x = translationValue(value.location.x / max(size.width, 1))
                        var y = translationValue(value.location.y / max(size.height, 1))
                        // Settles on the center line when dragged close to it.
                        if abs(x) < 0.015 { x = 0 }
                        if abs(y) < 0.015 { y = 0 }
                        onChange(CGPoint(x: x, y: y))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onChange(.zero) }
            )
        }
        .aspectRatio(max(canvasAspect, 0.5), contentMode: .fit)
        .help("Drag to move the card. Double-click to center it.")
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(Text(accessibilitySummary))
    }

    /// Pad fraction 0...1 for a translation.
    private func normalized(_ value: CGFloat) -> CGFloat {
        let lower = CGFloat(Self.range.lowerBound)
        let span = CGFloat(Self.range.upperBound - Self.range.lowerBound)
        return min(max((value - lower) / span, 0), 1)
    }

    private func translationValue(_ fraction: CGFloat) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        return CGFloat(Self.range.lowerBound) + clamped * CGFloat(Self.range.upperBound - Self.range.lowerBound)
    }

    private var accessibilitySummary: String {
        let percent = InspectorValueFormat.percent(signed: true)
        let x = percent.displayString(for: translation.x)
        let y = percent.displayString(for: translation.y)
        return "X \(x), Y \(y)"
    }
}
