//
//  RecordingCursorStyle.swift
//  Framecho
//
//  How Studio draws the synthetic pointer. Besides the artwork recorded with
//  the video, the pointer can be replaced by the system arrow or by a shape
//  Framecho draws itself. Those shapes are rendered once here with Core
//  Graphics into ordinary pointer artwork, so the live preview and the
//  exporter place them exactly like recorded artwork.
//

import CoreGraphics
import Foundation
import ImageIO

/// Cases are in the order the inspector's picker shows them.
nonisolated enum RecordingCursorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A soft translucent disc, like a presenter's highlight.
    case highlight
    /// A solid dot centered on the pointer location.
    case dot
    /// A ring with a small center mark, centered on the pointer location.
    case ring
    /// Thin crosshair lines around a center point.
    case crosshair
    /// Always the system arrow, whatever the pointer looked like.
    case arrow
    /// The pointer artwork recorded with the video: arrows, I-beams, hands.
    case recorded

    var id: String { rawValue }

    var help: String {
        switch self {
        case .highlight: String(localized: "Replace the pointer with a soft highlight")
        case .dot: String(localized: "Replace the pointer with a dot")
        case .ring: String(localized: "Replace the pointer with a ring")
        case .crosshair: String(localized: "Replace the pointer with a crosshair")
        case .arrow: String(localized: "Always show the arrow pointer")
        case .recorded: String(localized: "The pointer as it looked while recording")
        }
    }
}

/// Pointer artwork for the shapes Framecho draws itself.
nonisolated enum RecordingCursorArtwork {
    /// Points per side. A recorded arrow is about 16-24 points tall, and
    /// `PointerArtwork.intrinsicScale` sizes artwork by this reference, so
    /// the Size slider treats the shapes like the system pointer.
    private static let side: CGFloat = 20
    /// Pixels per point, so the shapes stay crisp at 4x cursor size on 4K.
    private static let pixelScale: CGFloat = 8

    static let highlight = make(id: "framecho-cursor-highlight") { context in
        let disc = circle(center: CGPoint(x: side / 2, y: side / 2), diameter: 15)
        context.setFillColor(CGColor(gray: 0.3, alpha: 0.45))
        context.fillEllipse(in: disc)
        context.setStrokeColor(CGColor(gray: 0.2, alpha: 0.7))
        context.setLineWidth(1)
        context.strokeEllipse(in: disc.insetBy(dx: 0.5, dy: 0.5))
    }

    static let dot = make(id: "framecho-cursor-dot") { context in
        let center = CGPoint(x: side / 2, y: side / 2)
        context.setShadow(
            offset: CGSize(width: 0, height: -0.5),
            blur: 1.6,
            color: CGColor(gray: 0, alpha: 0.35)
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: circle(center: center, diameter: 11.5))
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fillEllipse(in: circle(center: center, diameter: 8.5))
    }

    static let ring = make(id: "framecho-cursor-ring") { context in
        let center = CGPoint(x: side / 2, y: side / 2)
        let ring = circle(center: center, diameter: 14.5)
        context.setFillColor(CGColor(gray: 0, alpha: 0.12))
        context.fillEllipse(in: ring)
        context.setShadow(
            offset: CGSize(width: 0, height: -0.5),
            blur: 1.4,
            color: CGColor(gray: 0, alpha: 0.3)
        )
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(3)
        context.strokeEllipse(in: ring)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 0.06, alpha: 1))
        context.setLineWidth(1.5)
        context.strokeEllipse(in: ring)
        // The center mark gets the same white rim so it reads on dark content.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: circle(center: center, diameter: 3.8))
        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fillEllipse(in: circle(center: center, diameter: 2.4))
    }

    static let crosshair = make(id: "framecho-cursor-crosshair") { context in
        let middle = side / 2
        let arms: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 2.5, y: middle), CGPoint(x: middle - 2.5, y: middle)),
            (CGPoint(x: middle + 2.5, y: middle), CGPoint(x: side - 2.5, y: middle)),
            (CGPoint(x: middle, y: 2.5), CGPoint(x: middle, y: middle - 2.5)),
            (CGPoint(x: middle, y: middle + 2.5), CGPoint(x: middle, y: side - 2.5)),
        ]
        let center = CGPoint(x: middle, y: middle)
        context.setLineCap(.round)
        // A white halo under dark lines keeps it visible on any content.
        for (color, lineWidth, dot) in [(CGColor(gray: 1, alpha: 0.9), 2.6, 3.4), (CGColor(gray: 0.06, alpha: 1), 1.1, 1.8)] {
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            for (start, end) in arms {
                context.strokeLineSegments(between: [start, end])
            }
            context.setFillColor(color)
            context.fillEllipse(in: circle(center: center, diameter: dot))
        }
    }

    private static func circle(center: CGPoint, diameter: CGFloat) -> CGRect {
        CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    /// Draws into a `side`-point square (bottom-left origin) and encodes the
    /// result as PNG, anchored at the center.
    private static func make(
        id: String,
        draw: (CGContext) -> Void
    ) -> PointerArtwork? {
        let pixels = Int(side * pixelScale)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.scaleBy(x: pixelScale, y: pixelScale)
        draw(context)

        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                "public.png" as CFString,
                1,
                nil
              ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return PointerArtwork(
            artworkID: id,
            imageData: data as Data,
            anchorPoint: PointerArtwork.Point(x: Double(side / 2), y: Double(side / 2)),
            referenceSize: PointerArtwork.Size(width: Double(side), height: Double(side))
        )
    }
}
