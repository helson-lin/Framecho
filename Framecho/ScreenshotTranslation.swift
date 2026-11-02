//
//  ScreenshotTranslation.swift
//  Framecho
//

import CoreGraphics
import CoreText
import Foundation
import NaturalLanguage

/// Decides what to translate in a screenshot: which language its text is in,
/// which language to translate it to, and which blocks are in that language.
///
/// Languages are told apart by script first and only then by
/// NaturalLanguage, because screenshots are mostly short UI labels that
/// language detection reads badly on their own ("OK", "设置") while their
/// script is unambiguous. Blocks of one script are pooled into one text for
/// detection, so a column of short labels is judged as a whole.
nonisolated enum ScreenshotTranslationPlanner {
    struct Plan: Sendable, Equatable {
        /// BCP-47 identifiers, as `Locale.Language` takes them.
        var source: String
        var target: String
        /// The blocks to translate, by index; the rest are left as they are.
        var blockIndices: [Int]
    }

    /// The target the user most likely wants: their own language, unless the
    /// screenshot is already in it, in which case English (or Chinese for
    /// someone whose language is English).
    static func defaultTarget(for texts: [String], preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let home = homeLanguage(preferredLanguages)
        guard let dominant = dominantLanguage(in: texts), sameLanguage(dominant, home) else { return home }
        return sameLanguage(home, "en") ? "zh-Hans" : "en"
    }

    /// Translates the most common language that is not the target. Returns
    /// nil when every block is already in the target language, or none has
    /// words in it.
    static func plan(for texts: [String], target: String) -> Plan? {
        let languages = blockLanguages(texts)
        var weights: [String: Int] = [:]
        for (index, language) in languages.enumerated() {
            guard let language, !sameLanguage(language, target) else { continue }
            weights[language, default: 0] += weight(of: texts[index])
        }
        guard let source = weights.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
        return Plan(
            source: source,
            target: target,
            blockIndices: languages.indices.filter { languages[$0] == source }
        )
    }

    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        Locale.Language(identifier: a).languageCode == Locale.Language(identifier: b).languageCode
    }

    // MARK: - Detection

    private enum Script: Hashable {
        case han, kana, hangul, latin, cyrillic, other
    }

    private static func dominantLanguage(in texts: [String]) -> String? {
        var weights: [String: Int] = [:]
        for (index, language) in blockLanguages(texts).enumerated() {
            guard let language else { continue }
            weights[language, default: 0] += weight(of: texts[index])
        }
        return weights.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
    }

    /// The language of each block, or nil for one with no words in it.
    private static func blockLanguages(_ texts: [String]) -> [String?] {
        let scripts = texts.map(script)
        var pooled: [Script: String] = [:]
        for (text, script) in zip(texts, scripts) {
            guard let script else { continue }
            pooled[script, default: ""] += text + "\n"
        }
        let languages = pooled.reduce(into: [Script: String]()) { result, entry in
            result[entry.key] = language(of: entry.value, script: entry.key)
        }
        return scripts.map { $0.flatMap { languages[$0] } }
    }

    private static func language(of text: String, script: Script) -> String? {
        switch script {
        case .kana: return "ja"
        case .hangul: return "ko"
        case .han:
            return detect(text, among: [.simplifiedChinese, .traditionalChinese]) ?? "zh-Hans"
        case .cyrillic:
            return detect(text, among: [.russian, .ukrainian, .bulgarian]) ?? "ru"
        case .latin:
            // Screenshots are full of names and identifiers, which read as
            // anything; English is by far the likeliest, so another language
            // must be clearly ahead of it.
            let languages: [NLLanguage] = [
                .english, .french, .german, .spanish, .italian, .portuguese, .dutch,
                .polish, .turkish, .vietnamese, .indonesian, .swedish, .czech,
            ]
            // Every language needs some weight: one hinted alone wins even
            // against plain German.
            var hints = Dictionary(uniqueKeysWithValues: languages.map { ($0, 0.5 / Double(languages.count - 1)) })
            hints[.english] = 0.5
            return detect(text, among: languages, hints: hints) ?? "en"
        case .other:
            return detect(text, among: nil)
        }
    }

    private static func detect(
        _ text: String, among constraints: [NLLanguage]?, hints: [NLLanguage: Double] = [:]
    ) -> String? {
        let recognizer = NLLanguageRecognizer()
        if let constraints {
            recognizer.languageConstraints = constraints
        }
        recognizer.languageHints = hints
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// A block's script is the one most of its letters are in; any kana makes
    /// it Japanese, since Japanese mixes kana into Han text.
    private static func script(of text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
                counts[.kana, default: 0] += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                counts[.han, default: 0] += 1
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
                counts[.hangul, default: 0] += 1
            case 0x0400...0x04FF:
                counts[.cyrillic, default: 0] += 1
            default:
                guard scalar.properties.isAlphabetic else { continue }
                counts[scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value) ? .latin : .other, default: 0] += 1
            }
        }
        if counts[.kana] != nil { return .kana }
        // A lone letter or character is a unit or an icon misread as text (an
        // "x" or "十"), not something to translate.
        guard let top = counts.max(by: { $0.value < $1.value }), top.value >= 2 else { return nil }
        return top.key
    }

    /// How much text a block holds, roughly in words: a CJK character
    /// carries about as much as a short word, a Latin letter far less.
    private static func weight(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: total + 3
            default: total + (scalar.properties.isAlphabetic ? 1 : 0)
            }
        }
    }

    private static func homeLanguage(_ preferredLanguages: [String]) -> String {
        guard let first = preferredLanguages.first else { return "en" }
        let language = Locale.Language(identifier: first)
        guard language.languageCode == .chinese else {
            return language.languageCode?.identifier ?? "en"
        }
        let isTraditional = language.script == .hanTraditional
            || ["TW", "HK", "MO"].contains(language.region?.identifier ?? "")
        return isTraditional ? "zh-Hant" : "zh-Hans"
    }
}

/// Paints translations over the text they replace: each block is covered
/// with the colour around it and its translation is set in the colour of
/// the original text, shrunk to fit the original's box where it can.
nonisolated enum TranslatedImageRenderer {
    struct Replacement: Sendable {
        var block: RecognizedTextBlock
        var text: String
    }

    static func render(_ image: CGImage, replacements: [Replacement], language: String) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)

        // Colours are read before anything is painted, so a block never
        // samples the cover of the one beside it.
        let pixels = PixelReader(context: context)
        let styled = replacements.map { replacement -> (Replacement, CGRect, RGB, RGB, CGFloat) in
            let block = replacement.block
            let pad = (block.lineHeight * 0.15).rounded(.up)
            let cover = block.rect.insetBy(dx: -pad, dy: -pad).intersection(bounds)
            let background = pixels?.median(in: block.rect) ?? RGB(r: 1, g: 1, b: 1)
            let foreground = pixels?.textColor(in: block.rect, against: background)
                ?? background.contrasting
            // Keeps a word's space clear of whatever comes next.
            let free = (pixels?.clearWidth(rightOf: block.rect, background: background) ?? 0) - block.lineHeight * 0.5
            return (replacement, cover, background, foreground, max(0, free))
        }

        let layouts = styled.map { replacement, cover, background, foreground, free in
            (TextLayout(
                text: replacement.text, block: replacement.block, cover: cover, freeWidth: free,
                imageWidth: CGFloat(width), language: language, color: foreground.cgColor
            ), background)
        }
        // Every cover goes down before any text, so a block that grows over
        // its neighbour's cover never hides the neighbour's translation.
        for (layout, background) in layouts {
            context.setFillColor(background.cgColor)
            context.fill(flipped(layout.cover, height: CGFloat(height)))
        }
        for (layout, _) in layouts {
            layout.draw(in: context, imageHeight: CGFloat(height))
        }
        return context.makeImage()
    }

    private static func flipped(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Layout

    private struct TextLayout {
        let attributed: CFAttributedString
        /// Where the text is set, top-left coordinates.
        let textRect: CGRect
        /// What is painted over, which grows when the text needs more room.
        let cover: CGRect

        /// A translation longer than the original first runs on into
        /// `freeWidth`, the plain background to the block's right, and only
        /// then shrinks, so it stays close to the original's size.
        init(text: String, block: RecognizedTextBlock, cover originalCover: CGRect, freeWidth: CGFloat,
             imageWidth: CGFloat, language: String, color: CGColor) {
            let box = block.rect
            // Vision's box spans ascender to descender, a little more than
            // the point size.
            let baseSize = max(6, block.lineHeight * 0.8)
            let minimumSize = max(6, baseSize * 0.6)
            let availableWidth = box.width + freeWidth

            var size = baseSize
            var fitted: (CFAttributedString, CGSize)?
            while size >= minimumSize {
                let attributed = Self.attributed(text, size: size, language: language, color: color)
                let measured = Self.measure(attributed, width: availableWidth)
                // A one-line label stays one line, however roomy its box: a
                // second line would run into whatever sits below it.
                let fits = block.lineCount == 1
                    ? Self.measure(attributed, width: .greatestFiniteMagnitude).width <= availableWidth
                    : measured.height <= box.height + block.lineHeight * 0.25
                if fits {
                    fitted = (attributed, measured)
                    break
                }
                size *= 0.92
            }

            if let (attributed, measured) = fitted {
                self.attributed = attributed
                self.textRect = CGRect(
                    x: box.minX, y: box.midY - measured.height / 2,
                    width: min(availableWidth, max(box.width, measured.width + 2)), height: measured.height
                )
                self.cover = originalCover.union(textRect)
            } else {
                // Too long even at the smallest size: let it run wider, up to
                // the image's edge, and then taller.
                let attributed = Self.attributed(text, size: minimumSize, language: language, color: color)
                let singleLine = Self.measure(attributed, width: .greatestFiniteMagnitude)
                let width = max(box.width, min(singleLine.width + 2, imageWidth - box.minX))
                let measured = Self.measure(attributed, width: width)
                let pad = (block.lineHeight * 0.15).rounded(.up)
                self.attributed = attributed
                self.textRect = CGRect(
                    x: box.minX, y: max(box.minY, box.midY - measured.height / 2),
                    width: width, height: measured.height
                )
                self.cover = originalCover.union(textRect.insetBy(dx: -pad, dy: -pad))
            }
        }

        func draw(in context: CGContext, imageHeight: CGFloat) {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            // A little extra height, so rounding never drops the last line.
            let frameRect = CGRect(
                x: textRect.minX, y: imageHeight - textRect.maxY - 2,
                width: textRect.width, height: textRect.height + 4
            )
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil
            )
            context.saveGState()
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.restoreGState()
        }

        private static func attributed(_ text: String, size: CGFloat, language: String, color: CGColor) -> CFAttributedString {
            let font = CTFontCreateUIFontForLanguage(.system, size, language as CFString)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            var lineBreak = CTLineBreakMode.byWordWrapping
            let style = withUnsafeBytes(of: &lineBreak) { bytes in
                var setting = CTParagraphStyleSetting(
                    spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: bytes.baseAddress!
                )
                return CTParagraphStyleCreate(&setting, 1)
            }
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color,
                kCTParagraphStyleAttributeName: style,
                kCTLanguageAttributeName: language as CFString,
            ]
            return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        }

        private static func measure(_ attributed: CFAttributedString, width: CGFloat) -> CGSize {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil,
                CGSize(width: width, height: .greatestFiniteMagnitude), nil
            )
            return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        }
    }

    // MARK: - Colour sampling

    struct RGB: Equatable {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat

        var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        var contrasting: RGB { luminance > 0.5 ? RGB(r: 0, g: 0, b: 0) : RGB(r: 1, g: 1, b: 1) }
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

        func distance(to other: RGB) -> CGFloat {
            abs(r - other.r) + abs(g - other.g) + abs(b - other.b)
        }
    }

    /// Reads the bitmap the image was drawn into. Its rows run top to bottom,
    /// matching the blocks' top-left coordinates.
    private struct PixelReader {
        let bytes: UnsafePointer<UInt8>
        let width: Int
        let height: Int
        let bytesPerRow: Int

        init?(context: CGContext) {
            guard let data = context.data else { return nil }
            bytes = UnsafePointer(data.assumingMemoryBound(to: UInt8.self))
            width = context.width
            height = context.height
            bytesPerRow = context.bytesPerRow
        }

        func color(x: Int, y: Int) -> RGB {
            let offset = y * bytesPerRow + x * 4
            let alpha = CGFloat(bytes[offset + 3]) / 255
            guard alpha > 0 else { return RGB(r: 1, g: 1, b: 1) }
            // Premultiplied; screenshots are opaque, so this rarely divides.
            return RGB(
                r: CGFloat(bytes[offset]) / 255 / alpha,
                g: CGFloat(bytes[offset + 1]) / 255 / alpha,
                b: CGFloat(bytes[offset + 2]) / 255 / alpha
            )
        }

        /// The median colour inside `rect`: the background the text sits on,
        /// since strokes cover far less of a text box than the space around
        /// them. Read inside rather than around the box, so a box near the
        /// edge of a card isn't painted the colour beyond the card.
        func median(in rect: CGRect) -> RGB? {
            let minX = max(0, Int(rect.minX)), maxX = min(width - 1, Int(rect.maxX))
            let minY = max(0, Int(rect.minY)), maxY = min(height - 1, Int(rect.maxY))
            guard minX <= maxX, minY <= maxY else { return nil }

            let step = max(1, Int((CGFloat((maxX - minX) * (maxY - minY)) / 20_000).squareRoot()))
            var samples: [RGB] = []
            for y in stride(from: minY, through: maxY, by: step) {
                for x in stride(from: minX, through: maxX, by: step) {
                    samples.append(color(x: x, y: y))
                }
            }
            func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
            return RGB(r: median(samples.map(\.r)), g: median(samples.map(\.g)), b: median(samples.map(\.b)))
        }

        /// How far the background runs on unbroken to the right of `rect`,
        /// across its full height.
        func clearWidth(rightOf rect: CGRect, background: RGB) -> CGFloat {
            let minY = max(0, Int(rect.minY)), maxY = min(height - 1, Int(rect.maxY))
            let start = max(0, Int(rect.maxX.rounded(.up)) + 1)
            guard minY <= maxY, start < width else { return 0 }
            let step = max(1, (maxY - minY) / 12)
            for x in start..<width {
                for y in stride(from: minY, through: maxY, by: step)
                    where color(x: x, y: y).distance(to: background) > 0.12 {
                    return CGFloat(x - start)
                }
            }
            return CGFloat(width - start)
        }

        /// The colour of the strokes inside `rect`: the average of the pixels
        /// furthest from the background, which skips anti-aliased edges.
        func textColor(in rect: CGRect, against background: RGB) -> RGB? {
            let minX = max(0, Int(rect.minX)), maxX = min(width - 1, Int(rect.maxX))
            let minY = max(0, Int(rect.minY)), maxY = min(height - 1, Int(rect.maxY))
            guard minX <= maxX, minY <= maxY else { return nil }

            let step = max(1, Int((CGFloat((maxX - minX) * (maxY - minY)) / 40_000).squareRoot()))
            var samples: [(RGB, CGFloat)] = []
            for y in stride(from: minY, through: maxY, by: step) {
                for x in stride(from: minX, through: maxX, by: step) {
                    let pixel = color(x: x, y: y)
                    samples.append((pixel, pixel.distance(to: background)))
                }
            }
            guard let furthest = samples.map(\.1).max(), furthest > 0.3 else { return nil }
            let strokes = samples.filter { $0.1 >= furthest * 0.7 }.map(\.0)
            let count = CGFloat(strokes.count)
            return RGB(
                r: strokes.map(\.r).reduce(0, +) / count,
                g: strokes.map(\.g).reduce(0, +) / count,
                b: strokes.map(\.b).reduce(0, +) / count
            )
        }
    }
}
