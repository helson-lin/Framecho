//
//  RecordingTitleCardRenderer.swift
//  Framecho
//
//  Draws intro and outro cards to a bitmap - once per export, and for the
//  Studio preview - so both show exactly the same card.
//

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftUI

/// The Studio background on its own, as the export's backdrop and title
/// cards draw it.
nonisolated enum RecordingStudioBackdrop {
    static func drawBackground(
        _ background: AnnotationBackgroundStyle,
        in context: CGContext,
        canvasSize: CGSize,
        colorSpace: CGColorSpace
    ) {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        switch background {
        case .none:
            context.setFillColor(CGColor(gray: 0.04, alpha: 1))
            context.fill(canvasRect)
        case .solid(let color):
            context.setFillColor(CGColor(
                colorSpace: colorSpace,
                components: [color.red, color.green, color.blue, color.alpha]
            ) ?? CGColor(gray: 0, alpha: 1))
            context.fill(canvasRect)
        case .gradient(let gradient):
            let cgColors = gradient.colors.map { color in
                CGColor(
                    colorSpace: colorSpace,
                    components: [color.red, color.green, color.blue, color.alpha]
                ) ?? CGColor(gray: 0, alpha: 1)
            }
            if let cgGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: cgColors as CFArray,
                locations: nil
            ) {
                // UnitPoint has a top-left origin; the context is bottom-up.
                let start = CGPoint(
                    x: gradient.startPoint.x * canvasSize.width,
                    y: canvasSize.height - gradient.startPoint.y * canvasSize.height
                )
                let end = CGPoint(
                    x: gradient.endPoint.x * canvasSize.width,
                    y: canvasSize.height - gradient.endPoint.y * canvasSize.height
                )
                context.drawLinearGradient(cgGradient, start: start, end: end, options: [
                    .drawsBeforeStartLocation,
                    .drawsAfterEndLocation
                ])
            }
        case .customWallpaper(let wallpaper):
            if let source = CGImageSourceCreateWithURL(wallpaper.url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, [
                   kCGImageSourceShouldCache: false
               ] as CFDictionary) {
                let imageSize = CGSize(width: image.width, height: image.height)
                let scale = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
                let fillSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let fillRect = CGRect(
                    x: (canvasSize.width - fillSize.width) / 2,
                    y: (canvasSize.height - fillSize.height) / 2,
                    width: fillSize.width,
                    height: fillSize.height
                )
                context.draw(image, in: fillRect)
            } else {
                context.setFillColor(CGColor(gray: 0.04, alpha: 1))
                context.fill(canvasRect)
            }
        }
    }
}

/// A card taken apart for animation: the background, and each part drawn
/// once into its own image with where it sits when settled.
nonisolated struct RecordingTitleCardLayers: @unchecked Sendable {
    /// The side a part draws in from as it reveals.
    enum RevealEdge: Sendable {
        case leading
        case trailing
        case top
    }

    struct Element: @unchecked Sendable {
        var part: RecordingTitleCardMotion.Part
        var image: CGImage
        /// Settled frame in canvas pixels, top-left origin.
        var rect: CGRect
        var revealEdge: RevealEdge?
    }

    let canvasSize: CGSize
    let background: CGImage?
    let elements: [Element]
}

nonisolated enum RecordingTitleCardRenderer {
    /// The card's layers on a canvas of `canvasSize` pixels.
    static func layers(
        _ card: RecordingTitleCard,
        canvasSize: CGSize,
        background: AnnotationBackgroundStyle,
        assetsDirectory: URL?,
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    ) -> RecordingTitleCardLayers? {
        let size = CGSize(width: canvasSize.width.rounded(), height: canvasSize.height.rounded())
        guard size.width > 0, size.height > 0,
              let context = bitmap(size, colorSpace: colorSpace) else { return nil }
        context.interpolationQuality = .high
        if let color = card.backgroundColor {
            context.setFillColor(color.cgColor(alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        } else {
            RecordingStudioBackdrop.drawBackground(background, in: context, canvasSize: size, colorSpace: colorSpace)
        }

        var elements: [RecordingTitleCardLayers.Element] = []
        switch card.kind {
        case .image:
            if let fileName = card.imageFileName,
               let assetsDirectory,
               let image = RecordingStudioAssets.loadImage(
                   at: assetsDirectory.appendingPathComponent(fileName),
                   maxPixelSize: Int(max(size.width, size.height))
               ) {
                let rect = imageRect(image, fit: card.imageFit, canvasSize: size)
                if card.imageFit == .fill {
                    // A filling image is the backdrop, and pushes in with it.
                    context.draw(image, in: flipped(rect, canvasHeight: size.height))
                } else {
                    elements.append(.init(part: .content(0), image: image, rect: rect, revealEdge: nil))
                }
            }
        case .text:
            let textColor = card.textColor ?? {
                let luminance = card.backgroundColor?.luminance ?? averageLuminance(of: context)
                let gray = RecordingTitleCardTypography.usesDarkText(onBackgroundLuminance: luminance) ? 0.08 : 1
                return RecordingCardColor(red: gray, green: gray, blue: gray)
            }()
            elements = textElements(card, color: textColor, canvasSize: size, colorSpace: colorSpace)
        }
        return RecordingTitleCardLayers(canvasSize: size, background: context.makeImage(), elements: elements)
    }

    /// Draws the card as it stands `time` into it, filling `context`'s
    /// canvas. The caller sets the crossfade's alpha around it.
    static func draw(
        _ layers: RecordingTitleCardLayers,
        at time: TimeInterval,
        cardDuration: TimeInterval,
        animates: Bool,
        in context: CGContext
    ) {
        let canvas = layers.canvasSize
        if let background = layers.background {
            let state = RecordingTitleCardMotion.state(of: .background, at: time, cardDuration: cardDuration, animates: animates)
            let rect = CGRect(origin: .zero, size: canvas).scaled(by: state.scale)
            context.draw(background, in: rect)
        }
        for element in layers.elements {
            let state = RecordingTitleCardMotion.state(of: element.part, at: time, cardDuration: cardDuration, animates: animates)
            guard state.opacity > 0.001, state.reveal > 0.001 else { continue }
            var rect = element.rect.scaled(by: state.scale)
            rect.origin.y += canvas.height * state.offset
            let drawn = flipped(rect, canvasHeight: canvas.height)
            context.saveGState()
            context.setAlpha(state.opacity)
            if let edge = element.revealEdge, state.reveal < 1 {
                context.clip(to: revealed(drawn, edge: edge, amount: state.reveal))
            }
            context.draw(element.image, in: drawn)
            context.restoreGState()
        }
    }

    /// The share of a part already drawn, in the bottom-up context.
    private static func revealed(_ rect: CGRect, edge: RecordingTitleCardLayers.RevealEdge, amount: Double) -> CGRect {
        let amount = CGFloat(amount)
        switch edge {
        case .leading:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width * amount, height: rect.height)
        case .trailing:
            return CGRect(x: rect.maxX - rect.width * amount, y: rect.minY, width: rect.width * amount, height: rect.height)
        case .top:
            return CGRect(x: rect.minX, y: rect.maxY - rect.height * amount, width: rect.width, height: rect.height * amount)
        }
    }

    private static func imageRect(_ image: CGImage, fit: RecordingTitleCard.ImageFit, canvasSize: CGSize) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale: CGFloat = switch fit {
        case .fill: max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        // A margin of background all round, like the video card's.
        case .fit: min(canvasSize.width * 0.84 / imageSize.width, canvasSize.height * 0.84 / imageSize.height)
        }
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvasSize.width - drawn.width) / 2,
            y: (canvasSize.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    // MARK: - Text

    private static func textElements(
        _ card: RecordingTitleCard,
        color: RecordingCardColor,
        canvasSize: CGSize,
        colorSpace: CGColorSpace
    ) -> [RecordingTitleCardLayers.Element] {
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = card.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !subtitle.isEmpty else { return [] }

        let titleSize = RecordingTitleCardTypography.titleSize(canvasSize: canvasSize, scale: card.clampedTitleScale)
        let subtitleSize = RecordingTitleCardTypography.subtitleSize(canvasSize: canvasSize, scale: card.clampedSubtitleScale)
        let maxWidth = canvasSize.width * RecordingTitleCardTypography.maximumWidthFraction
        let column = card.textPosition.column
        let alignment: CTTextAlignment = column == 0 ? .left : column == 2 ? .right : .center

        var blocks: [(setter: CTFramesetter, size: CGSize)] = []
        if !title.isEmpty {
            let font = font(size: titleSize, weight: card.titleWeight, style: card.fontStyle)
            blocks.append(framesetter(title, font: font, color: color.cgColor(alpha: 1), alignment: alignment, width: maxWidth))
        }
        if !subtitle.isEmpty {
            let font = font(size: subtitleSize, weight: .regular, style: card.fontStyle)
            blocks.append(framesetter(subtitle, font: font, color: color.cgColor(alpha: 0.75), alignment: alignment, width: maxWidth))
        }

        // Measures shared by every part, off the larger type on the card.
        let unit = max(titleSize, subtitleSize * 1.6)
        let gap = unit * 0.35
        let ruleThickness = max(2, unit * 0.07)
        let lineLength = unit * 1.6
        let barGap = unit * 0.45
        let panelPadding = unit * 0.55
        let hasLine = card.accent == .line && !title.isEmpty && !subtitle.isEmpty
        let hasBar = card.accent == .bar

        // The text column: blocks stacked, a line between title and
        // subtitle when there is one.
        let contentWidth = max(blocks.map(\.size.width).max() ?? 0, hasLine ? lineLength : 0)
        var cursor: CGFloat = 0
        var placed: [(CGRect, Int)] = []
        var lineRect: CGRect?
        for (index, block) in blocks.enumerated() {
            if index == 1 {
                if hasLine {
                    lineRect = CGRect(x: 0, y: cursor + gap * 0.9, width: lineLength, height: ruleThickness)
                    cursor += gap * 0.9 + ruleThickness + gap * 1.1
                } else {
                    cursor += gap
                }
            }
            placed.append((CGRect(x: 0, y: cursor, width: contentWidth, height: block.size.height), index))
            cursor += block.size.height
        }
        let contentHeight = cursor

        // The block positioned on the canvas: column, bar beside it, panel
        // around both.
        let barSpan = hasBar ? ruleThickness + barGap : 0
        let inner = CGSize(width: contentWidth + barSpan, height: contentHeight)
        let outer = card.hasTextPanel
            ? CGSize(width: inner.width + panelPadding * 2, height: inner.height + panelPadding * 2)
            : inner
        let origin = RecordingTitleCardTypography.blockOrigin(blockSize: outer, canvasSize: canvasSize, position: card.textPosition)
        let innerOrigin = card.hasTextPanel
            ? CGPoint(x: origin.x + panelPadding, y: origin.y + panelPadding)
            : origin
        // A bar sits on the side the text is aligned to - the left unless
        // the text hangs right.
        let barOnRight = column == 2
        let contentX = innerOrigin.x + (hasBar && !barOnRight ? barSpan : 0)

        var elements: [RecordingTitleCardLayers.Element] = []
        if card.hasTextPanel {
            let rect = CGRect(origin: origin, size: outer)
            let dark = color.luminance > 0.5
            let fill = dark ? CGColor(gray: 0, alpha: 0.38) : CGColor(gray: 1, alpha: 0.62)
            if let image = shape(size: rect.size, radius: panelPadding * 0.8, fill: fill, colorSpace: colorSpace) {
                elements.append(.init(part: .panel, image: image, rect: rect, revealEdge: nil))
            }
        }
        if hasBar, let image = shape(size: CGSize(width: ruleThickness, height: contentHeight), radius: ruleThickness / 2, fill: color.cgColor(alpha: 1), colorSpace: colorSpace) {
            let x = barOnRight ? innerOrigin.x + contentWidth + barGap : innerOrigin.x
            elements.append(.init(
                part: .accent, image: image,
                rect: CGRect(x: x, y: innerOrigin.y, width: ruleThickness, height: contentHeight),
                revealEdge: .top
            ))
        }
        if let lineRect, let image = shape(size: lineRect.size, radius: ruleThickness / 2, fill: color.cgColor(alpha: 1), colorSpace: colorSpace) {
            let x: CGFloat = switch column {
            case 0: contentX
            case 2: contentX + contentWidth - lineLength
            default: contentX + (contentWidth - lineLength) / 2
            }
            elements.append(.init(
                part: .accent, image: image,
                rect: CGRect(x: x, y: innerOrigin.y + lineRect.minY, width: lineLength, height: ruleThickness),
                revealEdge: column == 2 ? .trailing : .leading
            ))
        }

        // Each text block in its own image, padded so a shadow isn't cut.
        let pad = card.hasTextShadow ? unit * 0.6 : 2
        for (frame, index) in placed {
            let block = blocks[index]
            let rect = CGRect(
                x: contentX + frame.minX - pad,
                y: innerOrigin.y + frame.minY - pad,
                width: frame.width + pad * 2,
                height: frame.height + pad * 2
            )
            guard let context = bitmap(rect.size, colorSpace: colorSpace) else { continue }
            if card.hasTextShadow {
                context.setShadow(
                    offset: CGSize(width: 0, height: -titleSize * 0.04),
                    blur: titleSize * 0.3,
                    color: CGColor(gray: 0, alpha: 0.5)
                )
            }
            let path = CGPath(rect: CGRect(x: pad, y: pad, width: frame.width, height: frame.height), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(block.setter, CFRange(location: 0, length: 0), path, nil), context)
            if let image = context.makeImage() {
                elements.append(.init(part: .content(index), image: image, rect: rect, revealEdge: nil))
            }
        }
        return elements
    }

    private static func shape(size: CGSize, radius: CGFloat, fill: CGColor, colorSpace: CGColorSpace) -> CGImage? {
        guard let context = bitmap(size, colorSpace: colorSpace) else { return nil }
        let rect = CGRect(origin: .zero, size: CGSize(width: context.width, height: context.height))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2, rect.height / 2),
                               cornerHeight: min(radius, rect.width / 2, rect.height / 2), transform: nil))
        context.setFillColor(fill)
        context.fillPath()
        return context.makeImage()
    }

    private static func bitmap(_ size: CGSize, colorSpace: CGColorSpace) -> CGContext? {
        let width = max(1, Int(size.width.rounded(.up)))
        let height = max(1, Int(size.height.rounded(.up)))
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    private static func flipped(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The system font at a weight, in one of its designs; it covers every
    /// script, so a Chinese title gets the matching PingFang.
    private static func font(
        size: CGFloat,
        weight: RecordingTitleCard.FontWeight,
        style: RecordingTitleCard.FontStyle
    ) -> CTFont {
        let nsWeight: NSFont.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
        let base = NSFont.systemFont(ofSize: size, weight: nsWeight)
        let design: NSFontDescriptor.SystemDesign = switch style {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design),
              let designed = NSFont(descriptor: descriptor, size: size) else {
            return base as CTFont
        }
        return designed as CTFont
    }

    /// A text block's setter and size; the width is what the text needs,
    /// up to `width`.
    private static func framesetter(
        _ text: String,
        font: CTFont,
        color: CGColor,
        alignment: CTTextAlignment,
        width: CGFloat
    ) -> (setter: CTFramesetter, size: CGSize) {
        var alignment = alignment
        let paragraph = withUnsafeMutablePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            setter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        return (setter, CGSize(width: ceil(min(fitted.width, width)) + 1, height: ceil(fitted.height)))
    }

    /// The background's mean relative luminance, from a one-pixel reduction.
    private static func averageLuminance(of context: CGContext) -> Double {
        guard let image = context.makeImage(),
              let pixel = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return 0
        }
        pixel.interpolationQuality = .medium
        pixel.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = pixel.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let red = Double(data[0]) / 255
        let green = Double(data[1]) / 255
        let blue = Double(data[2]) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

private extension CGRect {
    /// Scaled about its own center.
    nonisolated func scaled(by scale: Double) -> CGRect {
        guard scale != 1 else { return self }
        let scale = CGFloat(scale)
        return CGRect(
            x: midX - width * scale / 2,
            y: midY - height * scale / 2,
            width: width * scale,
            height: height * scale
        )
    }
}

private extension RecordingCardColor {
    nonisolated func cgColor(alpha: Double) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
