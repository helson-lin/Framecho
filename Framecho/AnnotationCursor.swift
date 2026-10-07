//
//  AnnotationCursor.swift
//  Framecho
//

import AppKit

extension NSCursor {
    /// No pointer at all, for while the color loupe stands in for it.
    static let annotationHidden = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    static let annotationPlus: NSCursor = {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outline = NSBezierPath()
        outline.move(to: CGPoint(x: center.x - 6, y: center.y))
        outline.line(to: CGPoint(x: center.x + 6, y: center.y))
        outline.move(to: CGPoint(x: center.x, y: center.y - 6))
        outline.line(to: CGPoint(x: center.x, y: center.y + 6))
        NSColor.white.setStroke()
        outline.lineWidth = 5
        outline.lineCapStyle = .round
        outline.stroke()

        let plus = NSBezierPath()
        plus.move(to: CGPoint(x: center.x - 6, y: center.y))
        plus.line(to: CGPoint(x: center.x + 6, y: center.y))
        plus.move(to: CGPoint(x: center.x, y: center.y - 6))
        plus.line(to: CGPoint(x: center.x, y: center.y + 6))
        NSColor.black.setStroke()
        plus.lineWidth = 2
        plus.lineCapStyle = .round
        plus.stroke()

        image.unlockFocus()
        return NSCursor(image: image, hotSpot: center)
    }()
}
