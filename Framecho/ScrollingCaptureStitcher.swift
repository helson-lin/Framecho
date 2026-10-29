//
//  ScrollingCaptureStitcher.swift
//  Framecho
//
//  Joins the frames of a scrolling capture into one tall image, kept apart
//  from ScreenCaptureKit and AppKit so scripts/check-scrolling-capture.swift
//  can exercise it.
//

import CoreGraphics

/// Builds a long screenshot from frames of one screen area taken while its
/// content scrolls down.
///
/// Each frame is matched against the last frame that was accepted. Rows that
/// stay put between the two (a toolbar, a sticky header or footer) are left
/// out of the match, so they appear once in the result, and only the rows
/// that scrolled into view are appended. A frame that moved back up, or so
/// far that nothing overlaps, is reported and ignored; capturing carries on
/// from the last accepted frame once the content is back within reach.
nonisolated struct ScrollingCaptureStitcher {
    enum Outcome: Equatable {
        /// The first frame.
        case started
        /// The content scrolled down; `rows` new rows were added (none when
        /// the new rows are still hidden behind a sticky footer).
        case appended(rows: Int)
        /// Nothing scrolled.
        case unchanged
        /// The content moved up. The frame is ignored.
        case scrolledBackward
        /// No part of the frame lines up with the last one: it scrolled too
        /// far in one step, or there is too little detail to tell how far.
        case noMatch
        /// Adding the frame would make the image taller than `maximumHeight`.
        case reachedLimit
        /// The frame isn't the size of the first one.
        case sizeMismatch
    }

    /// The tallest image, in pixels, the stitcher will build, so a capture
    /// left running can't grow without bound.
    let maximumHeight: Int

    /// The last accepted frame.
    private var reference: Frame?
    /// The rows taken so far, top first, each copied out of its frame.
    private var pieces: [CGImage] = []
    private var piecesHeight = 0
    /// The row of `reference` at which `pieces` ends.
    private var endRow = 0

    init(maximumHeight: Int = 30_000) {
        self.maximumHeight = maximumHeight
    }

    /// The height of the image `makeImage()` would return now.
    var height: Int {
        guard let reference else { return 0 }
        return pieces.isEmpty ? reference.height : piecesHeight + reference.height - endRow
    }

    mutating func add(_ image: CGImage) -> Outcome {
        guard let frame = Frame(image) else { return .sizeMismatch }
        guard let reference else {
            self.reference = frame
            return .started
        }
        guard frame.width == reference.width, frame.height == reference.height else { return .sizeMismatch }

        let fixed = Self.fixedRows(reference, frame)
        let height = frame.height
        let bandHeight = height - fixed.top - fixed.bottom
        // Only a sliver changed: a spinner or a blinking caret, not a scroll.
        guard bandHeight >= Self.minimumBand else { return .unchanged }

        guard let shift = Self.shift(from: reference, to: frame, top: fixed.top, bottom: fixed.bottom) else {
            return .noMatch
        }
        if shift == 0 { return .unchanged }
        if shift < 0 { return .scrolledBackward }

        // Until a second frame arrives the footer isn't known, so the first
        // frame's rows are taken now, down to this pair's footer.
        let firstRows = pieces.isEmpty ? height - fixed.bottom : 0
        let currentEnd = pieces.isEmpty ? height - fixed.bottom : endRow
        // In the new frame, the canvas ends `shift` rows higher up.
        let start = currentEnd - shift
        let end = height - fixed.bottom
        let newRows = max(0, end - start)
        guard piecesHeight + firstRows + newRows + fixed.bottom <= maximumHeight else { return .reachedLimit }

        if firstRows > 0, let piece = Self.copyRows(of: reference.image, 0..<firstRows) {
            pieces.append(piece)
            piecesHeight += firstRows
        }
        if newRows > 0, let piece = Self.copyRows(of: frame.image, start..<end) {
            pieces.append(piece)
            piecesHeight += newRows
        }
        endRow = max(start, end)
        self.reference = frame
        return .appended(rows: newRows)
    }

    /// The long screenshot: everything taken so far, then the rest of the
    /// last accepted frame (its footer, if it has one).
    func makeImage() -> CGImage? {
        guard let reference else { return nil }
        if pieces.isEmpty { return reference.image }

        var parts = pieces
        if endRow < reference.height, let tail = Self.copyRows(of: reference.image, endRow..<reference.height) {
            parts.append(tail)
        }
        let width = reference.width
        let total = parts.reduce(0) { $0 + $1.height }
        guard let context = Self.makeContext(width: width, height: total, like: reference.image) else { return nil }
        var top = 0
        for part in parts {
            top += part.height
            // Core Graphics counts y from the bottom.
            context.draw(part, in: CGRect(x: 0, y: total - top, width: width, height: part.height))
        }
        return context.makeImage()
    }

    // MARK: - Matching

    /// Rows that differ by less than this (mean luma, 0-255) count as the same.
    static let fixedTolerance: Float = 1
    /// A shift is accepted when the overlapping rows differ by at most this.
    static let matchTolerance: Float = 2
    /// The fewest rows outside the fixed bars worth matching.
    static let minimumBand = 24

    /// How many rows at the top and bottom are the same in both frames.
    private static func fixedRows(_ old: Frame, _ new: Frame) -> (top: Int, bottom: Int) {
        let height = new.height
        var top = 0
        while top < height, rowDifference(old, top, new, top) <= fixedTolerance { top += 1 }
        var bottom = 0
        while bottom < height - top, rowDifference(old, height - 1 - bottom, new, height - 1 - bottom) <= fixedTolerance {
            bottom += 1
        }
        return (top, bottom)
    }

    /// How many rows the content between the fixed bars moved up from `old`
    /// to `new` (negative when it moved down), or nil when no shift lines
    /// the two up.
    private static func shift(from old: Frame, to new: Frame, top: Int, bottom: Int) -> Int? {
        let end = new.height - bottom
        let band = end - top
        // Some overlap is needed to tell where the frames meet.
        let minimumOverlap = max(12, band / 10)
        let maximumShift = band - minimumOverlap
        guard maximumShift >= 0 else { return nil }

        // Rows of `new` that land inside the band of `old` after the shift.
        func error(_ shift: Int, step: Int) -> Float {
            let first = max(top, top - shift)
            let last = min(end, end - shift)
            var sum: Float = 0
            var count = 0
            var row = first
            while row < last {
                sum += rowDifference(new, row, old, row + shift)
                count += 1
                row += step
            }
            return count == 0 ? .infinity : sum / Float(count)
        }

        // Score every shift on a sample of rows, then the best few on all of them.
        let step = max(1, band / 160)
        var scored: [(shift: Int, error: Float)] = []
        scored.reserveCapacity(2 * maximumShift + 1)
        for shift in -maximumShift...maximumShift {
            scored.append((shift, error(shift, step: step)))
        }
        scored.sort { $0.error < $1.error || ($0.error == $1.error && abs($0.shift) < abs($1.shift)) }

        let refined = scored.prefix(4).map { candidate in
            (shift: candidate.shift, error: step == 1 ? candidate.error : error(candidate.shift, step: 1))
        }
        guard let best = refined.min(by: { $0.error < $1.error || ($0.error == $1.error && abs($0.shift) < abs($1.shift)) }),
              best.error <= matchTolerance else { return nil }
        if best.shift == 0 { return 0 }

        // A blank overlap lines up at any shift, so it says nothing.
        var edges = 0
        var row = max(top, top - best.shift, 1)
        let last = min(end, end - best.shift)
        while row < last {
            if rowDifference(new, row, new, row - 1) > matchTolerance {
                edges += 1
                if edges >= 2 { return best.shift }
            }
            row += 1
        }
        return nil
    }

    private static func rowDifference(_ a: Frame, _ rowA: Int, _ b: Frame, _ rowB: Int) -> Float {
        let columns = a.columns
        return a.signatures.withUnsafeBufferPointer { sa in
            b.signatures.withUnsafeBufferPointer { sb in
                var sum: Float = 0
                let ia = rowA * columns
                let ib = rowB * columns
                for column in 0..<columns {
                    sum += abs(sa[ia + column] - sb[ib + column])
                }
                return sum / Float(columns)
            }
        }
    }

    // MARK: - Images

    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .none
        return context
    }

    /// `rows` of `image` (counted from the top) as an image of their own, so
    /// the frame they came from can be released.
    private static func copyRows(of image: CGImage, _ rows: Range<Int>) -> CGImage? {
        guard !rows.isEmpty,
              let cropped = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)),
              let context = makeContext(width: image.width, height: rows.count, like: image) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: image.width, height: rows.count))
        return context.makeImage()
    }

    /// A frame and a compact fingerprint of each of its rows: the mean luma
    /// of up to 128 column bands. Averaging across a band keeps an overlay
    /// scroll bar or a little noise from spoiling a match.
    private struct Frame {
        let image: CGImage
        let width: Int
        let height: Int
        let columns: Int
        /// `columns` values per row, top row first.
        let signatures: [Float]

        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }

            var luma = [UInt8](repeating: 0, count: width * height)
            let drawn = luma.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }

            let columns = min(128, width)
            let band = (0..<width).map { $0 * columns / width }
            var perBand = [Float](repeating: 0, count: columns)
            for column in 0..<width { perBand[band[column]] += 1 }

            var signatures = [Float](repeating: 0, count: height * columns)
            luma.withUnsafeBufferPointer { pixels in
                signatures.withUnsafeMutableBufferPointer { out in
                    for row in 0..<height {
                        let base = row * columns
                        let source = row * width
                        for column in 0..<width {
                            out[base + band[column]] += Float(pixels[source + column])
                        }
                        for index in 0..<columns { out[base + index] /= perBand[index] }
                    }
                }
            }

            self.image = image
            self.width = width
            self.height = height
            self.columns = columns
            self.signatures = signatures
        }
    }
}
