//
//  ImageTextRecognizer.swift
//  Screendrop
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Vision

/// Extracts text from a captured image using the Vision framework so users can
/// "Copy text from image" (OCR).
enum ImageTextRecognizer {
    /// Recognises text in the image at `url`, returning the recognised lines
    /// joined by newlines in reading order. Returns an empty string when
    /// nothing is found.
    static func recognizeText(
        at url: URL,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continuation.resume(returning: "")
                    return
                }

                continuation.resume(
                    returning: recognizeText(in: cgImage, preferredLanguages: preferredLanguages)
                )
            }
        }
    }

    /// Automatic language detection reads pure English best, but it picks one
    /// recognizer per line, and an English-led line hands its CJK words to the
    /// Latin model: "Settings 设置" comes back as "Settings wE", with full
    /// confidence. A second pass with a CJK recognizer first reads those words
    /// right, so lines where it finds more CJK replace the detected ones.
    ///
    /// The second pass runs for everyone: the first gives no sign of the CJK
    /// it misread, and the pass costs well under a second even on a full
    /// 5K screenshot.
    nonisolated private static func recognizeText(in image: CGImage, preferredLanguages: [String]) -> String {
        let imageSize = CGSize(width: image.width, height: image.height)
        // Tiles are regions of interest on one handler rather than cropped
        // images: Core Image can read past the end of a cropped PNG-backed
        // image, and Vision then crashes building its buffer. Running them in
        // parallel would save nothing - Vision queues them on the same
        // hardware anyway.
        let passes = tiles(for: imageSize).map { tile in
            let regionOfInterest = CGRect(
                x: tile.frame.minX / imageSize.width, y: tile.frame.minY / imageSize.height,
                width: tile.frame.width / imageSize.width, height: tile.frame.height / imageSize.height
            )
            let detected = makeRequest(preferredLanguages: preferredLanguages)
            let cjkFirst = makeRequest(preferredLanguages: preferredLanguages, cjkFirst: true)
            detected.regionOfInterest = regionOfInterest
            cjkFirst.regionOfInterest = regionOfInterest
            return (tile, detected, cjkFirst)
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform(passes.map(\.1))) != nil else { return "" }
        // A tile the first pass found nothing in holds nothing for the second
        // either; skipping it halves the cost of the empty parts of a screen.
        let cjkPasses = passes.filter { !($0.1.results ?? []).isEmpty }.map(\.2)
        if !cjkPasses.isEmpty {
            try? handler.perform(cjkPasses)
        }

        // Results are relative to each request's region of interest, which is
        // the tile's frame.
        let detectedFragments = passes.flatMap { fragments($0.1.results ?? [], in: $0.0) }
        let cjkFragments = passes.flatMap { fragments($0.2.results ?? [], in: $0.0) }

        let lines = merging(cjkLines: visualLines(cjkFragments), into: visualLines(detectedFragments))
        return paragraphs(lines).map(\.text).joined(separator: "\n")
    }

    // MARK: - Tiling

    /// Vision scales the whole image down to a fixed working size before it
    /// looks for text, so on a large screenshot ordinary UI text drops below
    /// its detection threshold: 13 px text is found in none of 49 lines on a
    /// 2560 px image, and in all of them on a 1280 px one, and a full 5K
    /// Retina screenshot of a normal window reads as no text at all. Large
    /// images are therefore read in overlapping tiles, each small enough that
    /// the text stays detectable.
    ///
    /// Measured, not derived: larger tiles for Retina captures were faster
    /// but lost whole tiles of dense CJK text, so the length stays fixed.
    nonisolated private static let tileCoreLength: CGFloat = 1280
    /// Each tile reaches this far past its core on every side. A word up to
    /// twice this wide that crosses a core edge is still whole in the tile
    /// that owns its centre.
    nonisolated private static let tileMargin: CGFloat = 256

    nonisolated private struct Tile {
        /// The pixels Vision reads for this tile, in its bottom-left
        /// coordinates.
        let frame: CGRect
        /// The part of the image this tile reports text for. Cores partition
        /// the image, so every word is kept by exactly one tile.
        let core: CGRect
    }

    nonisolated private static func tiles(for imageSize: CGSize) -> [Tile] {
        let columns = max(1, Int((imageSize.width / tileCoreLength).rounded(.up)))
        let rows = max(1, Int((imageSize.height / tileCoreLength).rounded(.up)))
        let coreWidth = imageSize.width / CGFloat(columns)
        let coreHeight = imageSize.height / CGFloat(rows)
        let bounds = CGRect(origin: .zero, size: imageSize)

        var tiles: [Tile] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let core = CGRect(
                    x: CGFloat(column) * coreWidth, y: CGFloat(row) * coreHeight,
                    width: coreWidth, height: coreHeight
                )
                // Cores on the image's outer edges extend past it, so text
                // that Vision boxes a hair outside the image is still kept.
                let minX = column == 0 ? -tileMargin : core.minX
                let minY = row == 0 ? -tileMargin : core.minY
                let maxX = column == columns - 1 ? imageSize.width + tileMargin : core.maxX
                let maxY = row == rows - 1 ? imageSize.height + tileMargin : core.maxY
                tiles.append(Tile(
                    frame: core.insetBy(dx: -tileMargin, dy: -tileMargin).intersection(bounds).integral,
                    core: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                ))
            }
        }
        return tiles
    }

    nonisolated private static func makeRequest(
        preferredLanguages: [String] = Locale.preferredLanguages,
        cjkFirst: Bool = false
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Measured on prose at 11-16 px in English and Chinese, correction
        // changed nothing; on code and commands it only did harm, splitting
        // "push -f" into "push - f" and repeating tokens. Screenshots carry a
        // lot of code, paths, and URLs, so text is kept as recognized.
        request.usesLanguageCorrection = false
        if cjkFirst {
            // A fixed list makes the first language's recognizer read every
            // line, so put a CJK one first.
            let languages = recognitionLanguages(for: request, preferredLanguages: preferredLanguages)
            request.recognitionLanguages = languages.filter(isCJKLanguage)
                + languages.filter { !isCJKLanguage($0) }
        } else {
            configureLanguages(request, preferredLanguages: preferredLanguages)
        }
        return request
    }

    // MARK: - Warm-up

    nonisolated private static let warmUpFingerprintKey = "textRecognition.warmedUpFingerprint"

    /// The first accurate recognition in a newly installed binary compiles
    /// Vision's models for it, which takes 20-45 seconds - so after every
    /// update the first Copy Text would sit there for half a minute. The
    /// compiled models are cached on disk per binary, so this pays that cost
    /// once in the background, only when the app or macOS has changed since
    /// the last warm-up. Ordinary launches skip it and load nothing.
    static func warmUpAfterUpdateIfNeeded() {
        let fingerprint = binaryFingerprint()
        guard UserDefaults.standard.string(forKey: warmUpFingerprintKey) != fingerprint else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            // One Latin and one CJK sample: automatic language detection
            // picks a single recognizer per image, and each one compiles
            // separately.
            for sample in ["Recognize text", "识别文字"] {
                guard let image = warmUpImage(sample) else { return }
                _ = recognizeText(in: image, preferredLanguages: Locale.preferredLanguages)
            }
            UserDefaults.standard.set(fingerprint, forKey: warmUpFingerprintKey)
        }
    }

    /// Changes whenever the executable or the OS does - both invalidate the
    /// compiled models.
    private static func binaryFingerprint() -> String {
        let modified = (try? Bundle.main.executableURL?
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?
            .map { String($0.timeIntervalSinceReferenceDate) } ?? "unknown"
        return "\(modified)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    nonisolated private static func warmUpImage(_ text: String) -> CGImage? {
        let size = CGSize(width: 320, height: 64)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let font = CTFontCreateUIFontForLanguage(.system, 28, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 12, y: 20)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        return context.makeImage()
    }

    // MARK: - Languages

    /// Vision recognises only English unless told otherwise, and with a fixed
    /// list the first language's model reads everything - Chinese first turns
    /// "find" into "fina", English first turns Chinese into noise. Detecting
    /// the language per image avoids both; the list (the user's system
    /// languages, then Chinese and English) only narrows the candidates.
    nonisolated static func configureLanguages(
        _ request: VNRecognizeTextRequest,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = recognitionLanguages(for: request, preferredLanguages: preferredLanguages)
    }

    nonisolated private static func recognitionLanguages(
        for request: VNRecognizeTextRequest, preferredLanguages: [String]
    ) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = preferredLanguages.compactMap { identifier in
            supported.first { identifier.hasPrefix($0) || $0.hasPrefix(identifier) }
        }
        var languages: [String] = []
        for language in preferred + ["zh-Hans", "zh-Hant", "en-US"]
            where supported.contains(language) && !languages.contains(language) {
            languages.append(language)
        }
        return languages.isEmpty ? ["en-US"] : languages
    }

    /// A recognised run of text in pixel space (origin bottom-left, as Vision
    /// reports it). Normalized boxes scale x and y by different amounts, so
    /// gaps and heights are only comparable once converted.
    nonisolated private struct Fragment {
        var text: String
        var rect: CGRect
    }

    /// Converts a tile's observations to image coordinates and keeps only
    /// the text its core owns. Observations wholly inside the core are kept
    /// as they are; ones that cross its edge are cut between words, keeping
    /// the words whose centres the core contains.
    nonisolated private static func fragments(
        _ observations: [VNRecognizedTextObservation], in tile: Tile
    ) -> [Fragment] {
        func imageRect(_ box: CGRect) -> CGRect {
            CGRect(
                x: tile.frame.minX + box.minX * tile.frame.width,
                y: tile.frame.minY + box.minY * tile.frame.height,
                width: box.width * tile.frame.width,
                height: box.height * tile.frame.height
            )
        }
        func owns(_ rect: CGRect) -> Bool {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            // Half-open, so a centre on a shared core edge has one owner.
            return center.x >= tile.core.minX && center.x < tile.core.maxX
                && center.y >= tile.core.minY && center.y < tile.core.maxY
        }

        return observations.compactMap { observation -> Fragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let rect = imageRect(observation.boundingBox)
            if tile.core.contains(rect) {
                return Fragment(text: candidate.string, rect: rect)
            }
            guard tile.core.intersects(rect) else { return nil }

            let text = candidate.string
            let owned = wordRanges(in: text).compactMap { range -> (Range<String.Index>, CGRect)? in
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
                let wordRect = imageRect(box)
                return owns(wordRect) ? (range, wordRect) : nil
            }
            guard let first = owned.first, let last = owned.last else { return nil }
            return Fragment(
                text: String(text[first.0.lowerBound..<last.0.upperBound]),
                rect: owned.dropFirst().reduce(first.1) { $0.union($1.1) }
            )
        }
    }

    /// Splits text where it may be cut between tiles: at spaces, and around
    /// every CJK character, since CJK text has no spaces between words.
    nonisolated private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var wordStart: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if character.isWhitespace {
                if let start = wordStart { ranges.append(start..<index) }
                wordStart = nil
            } else if character.unicodeScalars.first.map(isUnspacedScript) == true {
                if let start = wordStart { ranges.append(start..<index) }
                ranges.append(index..<next)
                wordStart = nil
            } else if wordStart == nil {
                wordStart = index
            }
            index = next
        }
        if let start = wordStart { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// Puts the CJK-first reading of a line in place of the detected one when
    /// it holds more CJK characters. The detected line keeps its position, so
    /// layout is unchanged; lines only the CJK pass found are added.
    nonisolated private static func merging(cjkLines: [Fragment], into lines: [Fragment]) -> [Fragment] {
        var merged = lines
        for cjkLine in cjkLines {
            let cjkCount = cjkCharacterCount(cjkLine.text)
            guard cjkCount > 0 else { continue }

            let match = merged.indices
                .map { ($0, lineOverlap(merged[$0].rect, cjkLine.rect)) }
                .max { $0.1 < $1.1 }
            if let (index, overlap) = match, overlap > 0.5 {
                if cjkCount > cjkCharacterCount(merged[index].text) {
                    merged[index].text = cjkLine.text
                }
            } else {
                merged.append(cjkLine)
            }
        }
        return merged.sorted { $0.rect.midY > $1.rect.midY }
    }

    /// How much two line boxes share vertically, as a fraction of the shorter
    /// one; zero unless they also overlap horizontally.
    nonisolated private static func lineOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard a.maxX > b.minX, b.maxX > a.minX else { return 0 }
        let shared = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let shorter = min(a.height, b.height)
        return shorter > 0 ? max(0, shared) / shorter : 0
    }

    /// Rejoins lines that are clearly a wrapped paragraph instead of leaving
    /// them hard-broken, so the copied text reads like the original.
    nonisolated private static func paragraphs(_ lines: [Fragment]) -> [Fragment] {
        guard var paragraph = lines.first else { return [] }

        var paragraphs: [Fragment] = []
        for line in lines.dropFirst() {
            if continuesParagraph(paragraph, with: line) {
                paragraph.text = joinedAcrossWrap(paragraph.text, line.text)
                paragraph.rect = paragraph.rect.union(line.rect)
                // Keep a single line's height: the union now spans several.
                paragraph.rect.size.height = line.rect.height
                paragraph.rect.origin.y = line.rect.minY
            } else {
                paragraphs.append(paragraph)
                paragraph = line
            }
        }
        paragraphs.append(paragraph)
        return paragraphs
    }

    /// Vision returns observations in no documented order, which scrambles
    /// anything laid out in columns. Groups them into visual lines top to
    /// bottom, then orders each line left to right and joins it.
    ///
    /// Done as an explicit grouping pass rather than one clever comparator:
    /// a tolerance-based comparator is not a strict weak ordering, and
    /// `sorted(by:)` gives undefined results when handed one.
    nonisolated private static func visualLines(_ fragments: [Fragment]) -> [Fragment] {
        // The origin is bottom-left, so a larger midY sits higher on the page.
        let topDown = fragments.sorted { $0.rect.midY > $1.rect.midY }

        var lines: [Fragment] = []
        var line: [Fragment] = []
        var lineMidY: CGFloat = 0

        func flushLine() {
            let ordered = line.sorted { $0.rect.minX < $1.rect.minX }
            guard var merged = ordered.first else { return }
            for fragment in ordered.dropFirst() {
                let gap = fragment.rect.minX - merged.rect.maxX
                merged.text = joinedOnLine(
                    merged.text, fragment.text,
                    isTight: gap < max(merged.rect.height, fragment.rect.height)
                )
                merged.rect = merged.rect.union(fragment.rect)
            }
            lines.append(merged)
            line.removeAll()
        }

        for fragment in topDown {
            // Two fragments belong to the same visual line when their centres
            // sit within half a line height of each other.
            if !line.isEmpty, abs(fragment.rect.midY - lineMidY) > fragment.rect.height / 2 {
                flushLine()
            }
            if line.isEmpty {
                lineMidY = fragment.rect.midY
            }
            line.append(fragment)
        }
        flushLine()

        return lines
    }

    /// Conservative on purpose: wrongly gluing two UI labels together is worse
    /// than leaving a wrapped paragraph hard-broken. `previous` must look like
    /// a line that ran out of room - long, flush with `next` on the left, at
    /// least as wide, and without closing punctuation - and the two must be
    /// set in the same size at body-text spacing.
    nonisolated private static func continuesParagraph(_ previous: Fragment, with next: Fragment) -> Bool {
        let height = max(previous.rect.height, next.rect.height)
        guard height > 0 else { return false }

        let similarSize = abs(previous.rect.height - next.rect.height) <= height * 0.25
        let gap = previous.rect.minY - next.rect.maxY
        let tightlySpaced = gap >= -height * 0.25 && gap <= height * 0.6
        let leftAligned = abs(previous.rect.minX - next.rect.minX) <= height * 0.6
        let filledLine = previous.rect.width >= height * 8
            && previous.rect.maxX >= next.rect.maxX - height
        let openEnded = previous.text.last.map { !sentenceTerminators.contains($0) } ?? false
        let startsListItem = next.text.first.map { listMarkers.contains($0) } ?? false

        return similarSize && tightlySpaced && leftAligned && filledLine && openEnded && !startsListItem
    }

    nonisolated private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", ":", ";", "。", "！", "？", "：", "；", "…"
    ]
    nonisolated private static let listMarkers: Set<Character> = ["•", "·", "-", "–", "—", "*", "▪", "◦"]

    /// Chinese and Japanese are written without spaces between words, so a
    /// line that wraps at a CJK character continues directly. Korean does use
    /// spaces, so Hangul is not treated as unspaced.
    nonisolated private static func joinedAcrossWrap(_ left: String, _ right: String) -> String {
        guard let end = left.unicodeScalars.last, let start = right.unicodeScalars.first else {
            return left + right
        }
        let separator = isUnspacedScript(end) || isUnspacedScript(start) ? "" : " "
        return left + separator + right
    }

    /// Fragments on one line were split by Vision because something visibly
    /// separates them, so they keep a space - unless both sides are CJK and
    /// sit close enough to be one run of text.
    nonisolated private static func joinedOnLine(_ left: String, _ right: String, isTight: Bool) -> String {
        guard let end = left.unicodeScalars.last, let start = right.unicodeScalars.first else {
            return left + right
        }
        let separator = isTight && isUnspacedScript(end) && isUnspacedScript(start) ? "" : " "
        return left + separator + right
    }

    nonisolated private static func isCJKLanguage(_ identifier: String) -> Bool {
        ["zh", "ja", "ko", "yue"].contains { identifier == $0 || identifier.hasPrefix($0 + "-") }
    }

    /// Counts ideographs, kana, and Hangul only: a CJK recognizer reading an
    /// English line may still emit full-width punctuation, which must not
    /// make that reading win.
    nonisolated private static func cjkCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.count { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, // Hangul Jamo
                 0x3040...0x30FF, // Hiragana, Katakana
                 0x3130...0x318F, // Hangul Compatibility Jamo
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xAC00...0xD7AF, // Hangul Syllables
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0x20000...0x3134F: // CJK Extensions B-G
                true
            default:
                false
            }
        }
    }

    nonisolated private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFF00...0xFFEF, // Halfwidth and fullwidth forms
             0x20000...0x3134F: // CJK Extensions B-G
            true
        default:
            false
        }
    }
}
