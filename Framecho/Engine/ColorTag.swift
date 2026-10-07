import AppKit
import CoreText
import Foundation

/// A color tag: a label giving one screenshot pixel's color, with an arrow to a marker on that pixel.
///
/// The color is sampled from the screenshot when the tag is placed (and again whenever its marker
/// is dragged), converted to sRGB so the hex matches what a browser or design tool would show.
///
/// The shape itself is the label: a dark pill holding a chip of the color, its hex and its RGB
/// components, at the shape's origin. The sampled pixel is kept in page space, so moving, scaling
/// or rotating the label leaves the arrow pointing at the same pixel.
struct ColorTagProps: Codable, Equatable {
    /// 0...255 per channel, in sRGB.
    var red: Int = 0
    var green: Int = 0
    var blue: Int = 0
    /// The hex line's point size in page (image pixel) units; everything else scales from it.
    var fontSize: Double = 20
    /// The sampled pixel's centre, in page space. Nil for tags from before the label could be
    /// moved off its pixel, whose marker sat just left of the label.
    var anchor: Vec?

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgbDescription: String {
        "R\(red) G\(green) B\(blue)"
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    func hasSameColor(as other: ColorTagProps) -> Bool {
        (red, green, blue) == (other.red, other.green, other.blue)
    }

    /// The default size for a new tag on an image of this size: readable at fit-to-window zoom.
    static func defaultFontSize(forImageSize size: CGSize) -> Double {
        Swift.max(12, Double(Swift.max(size.width, size.height)) * 0.0125)
    }
}

extension AnnoShape {
    /// A color tag's sampled pixel, in page space.
    var colorTagAnchor: Vec? {
        guard let props = colorTagProps else { return nil }
        if let anchor = props.anchor { return anchor }
        let layout = ColorTagLayout(props)
        let outer = layout.markerRadius + layout.markerRing
        return pageTransform.applyToPoint(Vec(-(outer + props.fontSize * 0.4), Double(layout.pill.midY)))
    }
}

/// Where each part of a color tag sits, in the shape's local space. Shared by the renderer, the
/// geometry and the editor.
struct ColorTagLayout {
    let props: ColorTagProps
    let markerRadius: Double
    let markerRing: Double
    let pill: CGRect
    let chip: CGRect
    let hexOrigin: CGPoint
    let rgbOrigin: CGPoint
    let hexPath: CGPath
    let rgbPath: CGPath

    var size: CGSize { pill.size }
    /// How far the marker reaches from the sampled point, for hit-testing it.
    var markerExtent: Double { markerRadius + markerRing }

    init(_ props: ColorTagProps) {
        self.props = props
        let f = Swift.max(1, props.fontSize)
        let secondarySize = f * 0.72

        hexPath = ColorTagGlyphs.path(props.hex, size: f, weight: .semibold)
        rgbPath = ColorTagGlyphs.path(props.rgbDescription, size: secondarySize, weight: .regular)

        markerRadius = f * 0.5
        markerRing = Swift.max(1, f * 0.14)

        let padding = f * 0.5
        let lineGap = f * 0.22
        // Line boxes from the font's cap height, so the two lines sit optically centred.
        let hexHeight = f * 0.72
        let rgbHeight = secondarySize * 0.72
        let textHeight = hexHeight + lineGap + rgbHeight
        let textWidth = Swift.max(hexPath.boundingBoxOfPath.maxX, rgbPath.boundingBoxOfPath.maxX)

        let pillHeight = textHeight + padding * 2
        let chipSide = pillHeight - padding * 1.2
        pill = CGRect(
            x: 0,
            y: 0,
            width: padding * 0.6 + chipSide + padding * 0.7 + textWidth + padding,
            height: pillHeight
        )
        chip = CGRect(x: padding * 0.6, y: padding * 0.6, width: chipSide, height: chipSide)

        let textX = chip.maxX + padding * 0.7
        hexOrigin = CGPoint(x: textX, y: padding + hexHeight)
        rgbOrigin = CGPoint(x: textX, y: padding + textHeight)
    }

    /// Where a new tag's label goes for a pixel: up and to the right of it, flipped to stay on
    /// the image near its right and top edges. Returns the label's page-space origin.
    func labelOrigin(forAnchor anchor: Vec, imageSize: CGSize) -> Vec {
        let offset = props.fontSize * 2.4
        var x = anchor.x + offset
        var y = anchor.y - offset - Double(pill.height)
        if x + Double(pill.width) > Double(imageSize.width) { x = anchor.x - offset - Double(pill.width) }
        if y < 0 { y = anchor.y + offset }
        return Vec(x, y)
    }

    // MARK: - Rendering

    static let pillColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 0.9)

    /// Everything drawn for the tag, with the sampled pixel at `anchor` in local space.
    func elements(anchor: Vec) -> [RenderElement] {
        let color = props.nsColor
        let center = CGPoint(x: anchor.x, y: anchor.y)
        let outer = markerExtent
        let hairline = Swift.max(0.5, markerRing * 0.35)

        var elements = arrowElements(to: anchor)

        // A hairline outside a white ring, so the marker reads on dark and light pixels alike.
        elements.append(RenderElement(
            content: .path(CGPath(ellipseIn: Self.circle(center, outer), transform: nil)),
            fill: .white,
            stroke: NSColor.black.withAlphaComponent(0.35),
            strokeWidth: hairline
        ))
        elements.append(RenderElement(
            content: .path(CGPath(ellipseIn: Self.circle(center, markerRadius), transform: nil)),
            fill: color
        ))

        let pillRadius = pill.height * 0.3
        elements.append(RenderElement(
            content: .path(CGPath(roundedRect: pill, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)),
            fill: Self.pillColor,
            // Keeps the pill's edge on screenshots as dark as it is.
            stroke: NSColor.white.withAlphaComponent(0.16),
            strokeWidth: hairline
        ))
        let chipRadius = chip.height * 0.24
        elements.append(RenderElement(
            content: .path(CGPath(roundedRect: chip, cornerWidth: chipRadius, cornerHeight: chipRadius, transform: nil)),
            fill: color,
            stroke: NSColor.white.withAlphaComponent(0.28),
            strokeWidth: Swift.max(0.5, props.fontSize * 0.06)
        ))
        elements.append(Self.text(hexPath, at: hexOrigin, color: .white))
        elements.append(Self.text(rgbPath, at: rgbOrigin, color: NSColor.white.withAlphaComponent(0.62)))
        return elements
    }

    /// The arrow from the label's edge to the marker, with a light halo so it reads on dark
    /// screenshots too. Nothing when the marker touches the label.
    private func arrowElements(to anchor: Vec) -> [RenderElement] {
        let middle = Vec(Double(pill.midX), Double(pill.midY))
        guard let start = Self.exit(from: pill, toward: anchor) else { return [] }
        let span = Vec.sub(anchor, start)
        let headLength = props.fontSize * 0.6
        let lineWidth = markerRing
        let tipGap = markerExtent + lineWidth
        guard span.len > tipGap + headLength + lineWidth, !Vec.equals(anchor, middle) else { return [] }

        let direction = span.uni
        let tip = Vec.sub(anchor, Vec.mul(direction, tipGap))
        let base = Vec.sub(tip, Vec.mul(direction, headLength))
        let side = Vec.mul(direction.per, props.fontSize * 0.3)

        let shaft = CGMutablePath()
        shaft.move(to: CGPoint(x: start.x, y: start.y))
        shaft.addLine(to: CGPoint(x: base.x, y: base.y))

        let head = CGMutablePath()
        head.move(to: CGPoint(x: tip.x, y: tip.y))
        head.addLine(to: CGPoint(x: base.x + side.x, y: base.y + side.y))
        head.addLine(to: CGPoint(x: base.x - side.x, y: base.y - side.y))
        head.closeSubpath()

        let halo = NSColor.white.withAlphaComponent(0.85)
        let haloWidth = lineWidth + Swift.max(1, props.fontSize * 0.12)
        return [
            RenderElement(content: .path(shaft), stroke: halo, strokeWidth: haloWidth),
            RenderElement(content: .path(head), fill: halo, stroke: halo, strokeWidth: haloWidth - lineWidth),
            RenderElement(content: .path(shaft), stroke: Self.pillColor, strokeWidth: lineWidth),
            RenderElement(content: .path(head), fill: Self.pillColor),
        ]
    }

    /// Where a line from the rect's centre toward `point` leaves the rect, or nil if the point is
    /// inside it.
    private static func exit(from rect: CGRect, toward point: Vec) -> Vec? {
        guard !rect.contains(CGPoint(x: point.x, y: point.y)) else { return nil }
        let middle = Vec(Double(rect.midX), Double(rect.midY))
        let d = Vec.sub(point, middle)
        let tx = d.x == 0 ? Double.infinity : Double(rect.width) / 2 / abs(d.x)
        let ty = d.y == 0 ? Double.infinity : Double(rect.height) / 2 / abs(d.y)
        return Vec.add(middle, Vec.mul(d, Swift.min(tx, ty)))
    }

    private static func circle(_ center: CGPoint, _ radius: Double) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func text(_ path: CGPath, at baseline: CGPoint, color: NSColor) -> RenderElement {
        var transform = CGAffineTransform(translationX: baseline.x, y: baseline.y)
        let positioned = path.copy(using: &transform) ?? path
        return RenderElement(content: .glyphs(positioned), fill: color, stroke: nil)
    }
}

/// Monospaced glyph outlines for a tag's label, so the digits line up from tag to tag.
enum ColorTagGlyphs {
    private struct Key: Hashable {
        var text: String
        var size: Double
        var weight: CGFloat
    }
    private static var cache: [Key: CGPath] = [:]

    /// The string's outlines in a y-down space, with its baseline on y = 0 and its left edge on x = 0.
    static func path(_ text: String, size: Double, weight: NSFont.Weight) -> CGPath {
        let key = Key(text: text, size: size, weight: weight.rawValue)
        if let cached = cache[key] { return cached }
        if cache.count > 256 { cache.removeAll() }

        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: weight) as CTFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        let result = CGMutablePath()
        // Core Text lays glyphs out y-up; page space is y-down.
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                let transform = flip.translatedBy(x: positions[index].x, y: positions[index].y)
                result.addPath(glyph, transform: transform)
            }
        }
        cache[key] = result
        return result
    }
}
