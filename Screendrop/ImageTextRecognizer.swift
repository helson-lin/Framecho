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
    static func recognizeText(at url: URL) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continuation.resume(returning: "")
                    return
                }

                let request = makeRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    let text = layoutText(
                        request.results ?? [],
                        imageSize: CGSize(width: cgImage.width, height: cgImage.height)
                    )
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    nonisolated private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        configureLanguages(request)
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
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                guard (try? handler.perform([makeRequest()])) != nil else { return }
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
    nonisolated static func configureLanguages(_ request: VNRecognizeTextRequest) {
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = recognitionLanguages(for: request)
    }

    nonisolated private static func recognitionLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = Locale.preferredLanguages.compactMap { identifier in
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
    private struct Fragment {
        var text: String
        var rect: CGRect
    }

    /// Turns Vision's observations into plain text that reads like the
    /// original: fragments on one visual line are joined into one line, and
    /// lines that are clearly a wrapped
    /// paragraph are rejoined instead of hard-broken.
    nonisolated private static func layoutText(
        _ observations: [VNRecognizedTextObservation], imageSize: CGSize
    ) -> String {
        let fragments = observations.compactMap { observation -> Fragment? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Fragment(
                text: text,
                rect: CGRect(
                    x: box.minX * imageSize.width,
                    y: box.minY * imageSize.height,
                    width: box.width * imageSize.width,
                    height: box.height * imageSize.height
                )
            )
        }
        let lines = visualLines(fragments)
        guard var paragraph = lines.first else { return "" }

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
        return paragraphs.map(\.text).joined(separator: "\n")
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
