//
//  PinnedScreenshotGeometry.swift
//  Framecho
//
//  The arithmetic behind a pin's size, placement and opacity, kept apart
//  from AppKit so scripts/check-pinned-geometry.swift can exercise it.
//

import CoreGraphics

nonisolated enum PinnedScreenshotGeometry {
    /// A fully faded pin would be lost on screen.
    static let minimumOpacity: CGFloat = 0.2

    /// A new pin's size: the image at its size on screen, with the longest
    /// side kept between 160 and 560 points so pins stay handy but readable.
    static func displaySize(forPixelSize pixelSize: CGSize, backingScale: CGFloat) -> CGSize {
        let scale = backingScale > 0 ? backingScale : 2
        let width = pixelSize.width / scale
        let height = pixelSize.height / scale
        guard width > 0, height > 0 else { return CGSize(width: 320, height: 240) }

        let longest = max(width, height)
        let target = min(max(longest, 160), 560)
        let factor = target / longest
        return CGSize(width: (width * factor).rounded(), height: (height * factor).rounded())
    }

    /// The frame for resizing `frame` to `proposed` around `anchor` (its
    /// centre when nil): kept at least `minSize` and no larger than the
    /// visible area, aspect intact, and pulled back onto the screen when it
    /// grew past an edge.
    /// - Returns: nil when `proposed` is empty.
    static func resizedFrame(
        _ frame: CGRect,
        to proposed: CGSize,
        around anchor: CGPoint?,
        minSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect? {
        guard proposed.width > 0, proposed.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let grow = max(minSize.width / proposed.width, minSize.height / proposed.height, 1)
        let shrink = min(visibleFrame.width / proposed.width, visibleFrame.height / proposed.height, 1)
        let factor = grow > 1 ? grow : shrink
        let size = CGSize(width: (proposed.width * factor).rounded(), height: (proposed.height * factor).rounded())

        let anchor = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        let fx = (anchor.x - frame.minX) / frame.width
        let fy = (anchor.y - frame.minY) / frame.height
        var target = CGRect(
            x: (anchor.x - fx * size.width).rounded(),
            y: (anchor.y - fy * size.height).rounded(),
            width: size.width,
            height: size.height
        )
        if size.width > frame.width {
            target.origin.x = min(max(target.minX, visibleFrame.minX), visibleFrame.maxX - target.width)
            target.origin.y = min(max(target.minY, visibleFrame.minY), visibleFrame.maxY - target.height)
        }
        return target
    }

    /// Where the toolbar goes: under the pin's right edge, where it covers
    /// none of the image; above the pin when there's no room below; inside
    /// its bottom edge when there's room for neither. Never off screen
    /// sideways. Coordinates are AppKit's, y up.
    static func toolbarFrame(size: CGSize, pinFrame: CGRect, visibleFrame: CGRect, gap: CGFloat) -> CGRect {
        let x = min(max(pinFrame.maxX - size.width, visibleFrame.minX + gap), visibleFrame.maxX - size.width - gap)
        var y = pinFrame.minY - gap - size.height
        if y < visibleFrame.minY + gap {
            let above = pinFrame.maxY + gap
            y = above + size.height <= visibleFrame.maxY - gap ? above : pinFrame.minY + gap
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    static func clampedOpacity(_ opacity: CGFloat) -> CGFloat {
        min(1, max(minimumOpacity, opacity))
    }

    /// A pin's width as a percentage of the image at its actual size.
    static func zoomPercent(width: CGFloat, actualWidth: CGFloat) -> Int? {
        guard actualWidth > 0 else { return nil }
        return Int((width / actualWidth * 100).rounded())
    }
}
