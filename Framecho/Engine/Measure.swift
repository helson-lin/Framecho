import AppKit
import Foundation

/// Pixel measurements: a ruler between two points, and the size label a rectangle or ellipse can
/// carry.
///
/// Page space is the screenshot's own pixels, so a measurement is just a length in page units.
/// Points divide that by the capture's pixel density (2 on Retina), which each label keeps so it
/// reads the same wherever the shape ends up.
enum MeasureUnit: String, CaseIterable, Codable {
    case pixels
    case points

    var label: String {
        switch self {
        case .pixels: String(localized: "Pixels")
        case .points: String(localized: "Points")
        }
    }

    var suffix: String {
        switch self {
        case .pixels: "px"
        case .points: "pt"
        }
    }
}

/// How a measurement is written out.
struct MeasureLabel: Codable, Equatable {
    var unit: MeasureUnit = .pixels
    /// Image pixels per point for the screenshot the label was made on.
    var pixelsPerPoint: Double = 1
    /// The label's point size in page (image pixel) units.
    var fontSize: Double = 20

    /// A page-space length in this label's unit: whole numbers stay whole, anything else gets one
    /// decimal, which is as precise as a half-pixel on Retina needs.
    func value(_ pixels: Double) -> String {
        let divisor = unit == .points ? Swift.max(1, pixelsPerPoint) : 1
        let value = abs(pixels) / divisor
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 { return String(Int(rounded)) }
        return String(format: "%.1f", value)
    }

    func distance(_ pixels: Double) -> String {
        "\(value(pixels)) \(unit.suffix)"
    }

    func size(width: Double, height: Double) -> String {
        "\(value(width)) × \(value(height)) \(unit.suffix)"
    }
}

/// What a measurement measures.
enum MeasureKind: String, Codable {
    /// The length of the line between two points.
    case distance
    /// The width and height of the box with two opposite corners at the points.
    case area
}

/// A ruler: a line between two points with end ticks and its length in a label, or a box with its
/// size.
struct MeasureProps: Codable, Equatable {
    /// Nil is a distance, which is what rulers saved before boxes were.
    var kind: MeasureKind?
    /// Ends in the shape's local space; a box's opposite corners.
    var start = Vec(0, 0)
    var end = Vec(100, 0)
    var swatch: AnnotationSwatch = .red
    var label = MeasureLabel()
    /// How far the label is moved from where it would sit on its own, to clear another ruler's.
    /// Nil leaves it there; moving an end clears it.
    var labelOffset: Vec?

    var length: Double { Vec.dist(start, end) }
    var isArea: Bool { kind == .area }
    /// A box's extent, in the shape's local space.
    var box: CGRect { CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized }

    /// What the label says.
    var text: String {
        isArea ? label.size(width: Double(box.width), height: Double(box.height)) : label.distance(length)
    }
}

/// What a click with the measure tool found, in page space.
enum MeasureTarget: Equatable {
    /// A block - a card, a button, a field - by its edges.
    case block(left: Double, top: Double, right: Double, bottom: Double)
    /// The background: the gaps either side of the pressed pixel.
    case spans(MeasureSpans)
}

/// The run of matching pixels through a point, found by scanning the screenshot outwards from it.
/// Bounds are page-space pixel edges: `left...right` covers whole pixels on the row through `y`.
struct MeasureSpans: Equatable {
    var left: Double
    var right: Double
    var top: Double
    var bottom: Double
    /// The centre of the pressed pixel, which the two rulers cross at.
    var x: Double
    var y: Double
}

/// The default label size for an image of this size, matching color tags.
func measureDefaultFontSize(forImageSize size: CGSize) -> Double {
    ColorTagProps.defaultFontSize(forImageSize: size)
}

// MARK: - Label

/// A measurement's label: white monospaced digits on the same dark pill as a color tag.
struct MeasureLabelLayout {
    let pill: CGRect
    let textPath: CGPath
    let textOrigin: CGPoint

    /// A pill for `text` with its top-left at the origin.
    init(text: String, fontSize: Double) {
        let f = Swift.max(1, fontSize)
        textPath = ColorTagGlyphs.path(text, size: f, weight: .semibold)
        let padX = f * 0.5
        let padY = f * 0.32
        let capHeight = f * 0.72
        pill = CGRect(
            x: 0,
            y: 0,
            width: Double(textPath.boundingBoxOfPath.maxX) + padX * 2,
            height: capHeight + padY * 2
        )
        textOrigin = CGPoint(x: padX, y: padY + capHeight)
    }

    var size: CGSize { pill.size }

    /// The pill and its text, with the pill's top-left moved to `origin`.
    func elements(at origin: CGPoint) -> [RenderElement] {
        let rect = pill.offsetBy(dx: origin.x, dy: origin.y)
        let radius = rect.height * 0.3
        var transform = CGAffineTransform(translationX: origin.x + textOrigin.x, y: origin.y + textOrigin.y)
        let text = textPath.copy(using: &transform) ?? textPath
        return [
            RenderElement(
                content: .path(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)),
                fill: ColorTagLayout.pillColor,
                stroke: NSColor.white.withAlphaComponent(0.16),
                strokeWidth: Swift.max(0.5, rect.height * 0.03)
            ),
            RenderElement(content: .glyphs(text), fill: .white, stroke: nil),
        ]
    }
}

// MARK: - Ruler

/// Where each part of a ruler sits, in the shape's local space. Shared by the renderer and the
/// geometry, so what you can grab is what you see.
struct MeasureLayout {
    let props: MeasureProps
    let lineWidth: Double
    let tickLength: Double
    let label: MeasureLabelLayout
    /// The label pill, placed.
    let labelRect: CGRect

    init(_ props: MeasureProps) {
        self.props = props
        let f = Swift.max(1, props.label.fontSize)
        lineWidth = Swift.max(1, f * 0.1)
        tickLength = f * 0.9
        label = MeasureLabelLayout(text: props.text, fontSize: f)

        let size = label.size
        if props.isArea {
            // Inside the box when it fits with room to spare, otherwise centred under it.
            let box = props.box
            let fits = Double(size.width) + f * 2 <= Double(box.width) && Double(size.height) + f <= Double(box.height)
            labelRect = CGRect(
                x: box.midX - size.width / 2,
                y: fits ? box.midY - size.height / 2 : box.maxY + f * 0.4,
                width: size.width,
                height: size.height
            )
            return
        }

        let middle = Vec.med(props.start, props.end)
        let direction = Vec.sub(props.end, props.start).uni
        // The pill sits on the line's middle when the line runs past both sides of it; a shorter
        // line keeps it clear, off to one side, so the line itself stays visible.
        let alongExtent = abs(direction.x) * Double(size.width) / 2 + abs(direction.y) * Double(size.height) / 2
        var center = middle
        if props.length < alongExtent * 2 + tickLength {
            // Above a flat line, left of an upright one.
            var normal = direction.per
            if normal.y > 0 || (normal.y == 0 && normal.x > 0) { normal = Vec.neg(normal) }
            if props.length == 0 { normal = Vec(0, -1) }
            let acrossExtent = abs(normal.x) * Double(size.width) / 2 + abs(normal.y) * Double(size.height) / 2
            center = Vec.add(middle, Vec.mul(normal, acrossExtent + tickLength / 2 + f * 0.3))
        }
        if let offset = props.labelOffset { center = Vec.add(center, offset) }
        labelRect = CGRect(
            x: center.x - Double(size.width) / 2,
            y: center.y - Double(size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The line plus a tick across each end, or a box's outline, as one path.
    var linePath: CGPath {
        if props.isArea { return CGPath(rect: props.box, transform: nil) }
        let path = CGMutablePath()
        let start = props.start
        let end = props.end
        path.move(to: start.cgPoint)
        path.addLine(to: end.cgPoint)
        guard props.length > 0 else { return path }
        let tick = Vec.mul(Vec.sub(end, start).uni.per, tickLength / 2)
        for point in [start, end] {
            path.move(to: Vec.add(point, tick).cgPoint)
            path.addLine(to: Vec.sub(point, tick).cgPoint)
        }
        return path
    }

    func elements() -> [RenderElement] {
        let line = linePath
        // A light halo under the line, so it reads on dark screenshots as well as light ones.
        let halo = NSColor.white.withAlphaComponent(0.7)
        var elements = [
            RenderElement(content: .path(line), stroke: halo, strokeWidth: lineWidth * 2.6),
            RenderElement(content: .path(line), stroke: props.swatch.nsColor, strokeWidth: lineWidth),
        ]
        elements.append(contentsOf: label.elements(at: labelRect.origin))
        return elements
    }
}

// MARK: - Crossing rulers

extension MeasureProps {
    /// A label offset for this ruler that keeps its label clear of `other`, a page-space rect,
    /// when the ruler's shape sits at `origin`: nil when its own spot is already clear, otherwise
    /// just past the other label along this ruler, toward whichever end has more ruler left.
    func labelOffset(clearing other: CGRect, origin: Vec) -> Vec? {
        var props = self
        props.labelOffset = nil
        let own = MeasureLayout(props).labelRect.offsetBy(dx: origin.x, dy: origin.y)
        let blocked = other.insetBy(dx: -label.fontSize * 0.3, dy: -label.fontSize * 0.3)
        guard own.intersects(blocked) else { return nil }

        // Work along the ruler's main axis, so one path covers rulers across and down.
        let isUpright = abs(end.y - start.y) > abs(end.x - start.x)
        func axis(_ v: Vec) -> Double { isUpright ? v.y : v.x }
        func axis(min rect: CGRect) -> Double { Double(isUpright ? rect.minY : rect.minX) }
        func axis(max rect: CGRect) -> Double { Double(isUpright ? rect.maxY : rect.maxX) }

        let crossing = (axis(min: blocked) + axis(max: blocked)) / 2
        let low = Swift.min(axis(start), axis(end)) + axis(origin)
        let high = Swift.max(axis(start), axis(end)) + axis(origin)
        // Past the other label toward the far end, or back before it toward the near one.
        let shift = high - crossing >= crossing - low
            ? axis(max: blocked) - axis(min: own)
            : axis(min: blocked) - axis(max: own)
        return isUpright ? Vec(0, shift) : Vec(shift, 0)
    }
}

// MARK: - Size labels

extension GeoProps {
    /// Where a geo shape's size label goes: centred under it, clear of its stroke.
    func sizeLabelLayout() -> (layout: MeasureLabelLayout, origin: CGPoint)? {
        guard let sizeLabel else { return nil }
        let layout = MeasureLabelLayout(text: sizeLabel.size(width: w, height: h), fontSize: sizeLabel.fontSize)
        let gap = (fill == .none ? strokeWidth / 2 : 0) + sizeLabel.fontSize * 0.4
        let origin = CGPoint(x: w / 2 - Double(layout.size.width) / 2, y: h + gap)
        return (layout, origin)
    }
}
