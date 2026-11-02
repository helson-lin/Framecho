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
/// Until the first rows are kept, such a frame replaces the first one.
nonisolated struct ScrollingCaptureStitcher {
    enum Outcome: Equatable, Sendable {
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

        let shift = Self.shift(from: reference, to: frame, top: fixed.top, bottom: fixed.bottom)
        if pieces.isEmpty, (shift ?? -1) <= 0 {
            // Nothing is kept yet, so the capture starts over from this frame:
            // the first one may have caught an overlay still fading out, or
            // the user scrolled up to where they want to begin.
            self.reference = frame
            return shift == 0 ? .unchanged : .started
        }
        guard let shift else { return .noMatch }
        if shift == 0 { return .unchanged }
        if shift < 0 { return .scrolledBackward }

        // Rows near the bottom edge are held back until a later frame shows
        // them higher up: on macOS 26 and later a scroll view tints what
        // passes under its edges, and differently as the content moves.
        // Only the last frame's are kept, as they were on screen.
        let held = Self.heldBackFraction(of: height - fixed.top - fixed.bottom)
        let end = height - fixed.bottom - held
        // Until a second frame arrives the footer isn't known, so the first
        // frame's rows are taken now, down to the same point.
        let currentEnd = pieces.isEmpty ? end : endRow
        // In the new frame, the canvas ends `shift` rows higher up. Rows
        // that are under its header by now come from the last frame's
        // held-back ones instead.
        let start = currentEnd - shift
        let hidden = max(0, fixed.top - start)
        let fromReference = (pieces.isEmpty ? 0 : currentEnd)..<(currentEnd + hidden)
        let fromFrame = (start + hidden)..<max(start + hidden, end)
        let added = fromReference.count + fromFrame.count
        guard piecesHeight + added + fixed.bottom + held <= maximumHeight else { return .reachedLimit }

        for (image, rows) in [(reference.image, fromReference), (frame.image, fromFrame)] where !rows.isEmpty {
            guard let piece = Self.copyRows(of: image, rows) else { continue }
            pieces.append(piece)
            piecesHeight += rows.count
        }
        endRow = max(start, end)
        self.reference = frame
        return .appended(rows: hidden + fromFrame.count)
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

    /// A row whose bands differ from each other by more than this on
    /// average (luma) has detail; below it, it is blank or evenly tinted.
    static let detailLevel: Float = 2
    /// Rows that differ by less than this (mean luma, 0-255) count as the same.
    static let fixedTolerance: Float = 1
    /// A shift is accepted when the overlapping rows differ by at most this.
    static let matchTolerance: Float = 2
    /// The fewest rows outside the fixed bars worth matching.
    static let minimumBand = 24

    /// The rows at the bottom of the moving band taken from a later frame.
    static func heldBackFraction(of band: Int) -> Int {
        max(0, band / 3)
    }

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
    ///
    /// Written for speed without the optimizer: Debug builds run this on
    /// every frame too, and standard-library loops there are some 70 times
    /// slower, enough for a capture to lag seconds behind the screen.
    private static func shift(from old: Frame, to new: Frame, top: Int, bottom: Int) -> Int? {
        let end = new.height - bottom
        let band = end - top
        // Some overlap is needed to tell where the frames meet.
        let minimumOverlap = max(12, band / 10)
        let maximumShift = band - minimumOverlap
        guard maximumShift >= 0 else { return nil }
        let step = max(1, band / 160)

        // Screen every shift on one number per row, then compare the most
        // likely ones properly.
        var screened: [(shift: Int, error: Float)] = []
        screened.reserveCapacity(2 * maximumShift + 1)
        var shift = -maximumShift
        while shift <= maximumShift {
            var sum: Float = 0
            var count = 0
            var row = max(top, top - shift)
            let last = min(end, end - shift)
            while row < last {
                let a = new.profile[row]
                let b = old.profile[row + shift]
                if a > detailLevel || b > detailLevel {
                    sum += a > b ? a - b : b - a
                    count += 1
                }
                row += step
            }
            screened.append((shift, count == 0 ? .infinity : sum / Float(count)))
            shift += 1
        }
        screened.sort { $0.error < $1.error }

        // Rows of `new` that land inside the band of `old` after the shift
        // and have detail in either: their mean difference in shape. Blank
        // rows line up at any shift, so on a page that is mostly white
        // space they would let a wrong shift pass.
        func error(_ shift: Int, step: Int) -> Float {
            var sum: Float = 0
            var count = 0
            var row = max(top, top - shift)
            let last = min(end, end - shift)
            while row < last {
                if new.profile[row] > detailLevel || old.profile[row + shift] > detailLevel {
                    sum += shapeDifference(new, row, old, row + shift)
                    count += 1
                }
                row += step
            }
            return count < 2 ? .infinity : sum / Float(count)
        }

        func isBetter(_ a: (shift: Int, error: Float), _ b: (shift: Int, error: Float)) -> Bool {
            a.error < b.error || (a.error == b.error && abs(a.shift) < abs(b.shift))
        }
        let sampled = screened.prefix(24)
            .map { (shift: $0.shift, error: error($0.shift, step: step)) }
            .sorted(by: isBetter)
        guard let best = sampled.prefix(4)
            .map({ (shift: $0.shift, error: error($0.shift, step: 1)) })
            .min(by: isBetter),
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

    /// Like `rowDifference`, on the rows' shapes rather than their
    /// brightness, so a tint over part of a frame doesn't count.
    private static func shapeDifference(_ a: Frame, _ rowA: Int, _ b: Frame, _ rowB: Int) -> Float {
        let columns = a.columns
        let rowOfA = a.shapes + rowA * columns
        let rowOfB = b.shapes + rowB * columns
        var sum: Float = 0
        var column = 0
        while column < columns {
            let difference = rowOfA[column] - rowOfB[column]
            sum += difference < 0 ? -difference : difference
            column += 1
        }
        return sum / Float(columns)
    }

    private static func rowDifference(_ a: Frame, _ rowA: Int, _ b: Frame, _ rowB: Int) -> Float {
        let columns = a.columns
        let rowOfA = a.signatures + rowA * columns
        let rowOfB = b.signatures + rowB * columns
        var sum: Float = 0
        var column = 0
        while column < columns {
            let difference = rowOfA[column] - rowOfB[column]
            sum += difference < 0 ? -difference : difference
            column += 1
        }
        return sum / Float(columns)
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
    /// scroll bar or a little noise from spoiling a match. `profile` sums
    /// each row's changes from band to band, one number per row for a
    /// quick first comparison. `shapes` are the signatures with each row's
    /// mean taken away and divided by its mean deviation: a scroll view's
    /// tint scales and offsets a row's brightness, which this undoes.
    private final class Frame {
        let image: CGImage
        let width: Int
        let height: Int
        let columns: Int
        /// `columns` values per row, top row first.
        let signatures: UnsafeMutablePointer<Float>
        let profile: UnsafeMutablePointer<Float>
        let shapes: UnsafeMutablePointer<Float>

        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }

            let luma = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
            defer { luma.deallocate() }
            guard let context = CGContext(
                data: luma, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let columns = min(128, width)
            let band = UnsafeMutablePointer<Int>.allocate(capacity: width)
            defer { band.deallocate() }
            let perBand = UnsafeMutablePointer<Float>.allocate(capacity: columns)
            defer { perBand.deallocate() }
            perBand.initialize(repeating: 0, count: columns)
            var column = 0
            while column < width {
                band[column] = column * columns / width
                perBand[band[column]] += 1
                column += 1
            }

            let signatures = UnsafeMutablePointer<Float>.allocate(capacity: height * columns)
            signatures.initialize(repeating: 0, count: height * columns)
            let profile = UnsafeMutablePointer<Float>.allocate(capacity: height)
            let shapes = UnsafeMutablePointer<Float>.allocate(capacity: height * columns)
            var row = 0
            while row < height {
                let out = signatures + row * columns
                let pixels = luma + row * width
                column = 0
                while column < width {
                    out[band[column]] += Float(pixels[column])
                    column += 1
                }
                var energy: Float = 0
                var index = 0
                while index < columns {
                    out[index] /= perBand[index]
                    if index > 0 {
                        let difference = out[index] - out[index - 1]
                        energy += difference < 0 ? -difference : difference
                    }
                    index += 1
                }
                profile[row] = energy / Float(columns)

                var mean: Float = 0
                index = 0
                while index < columns {
                    mean += out[index]
                    index += 1
                }
                mean /= Float(columns)
                var deviation: Float = 0
                index = 0
                while index < columns {
                    let difference = out[index] - mean
                    deviation += difference < 0 ? -difference : difference
                    index += 1
                }
                deviation /= Float(columns)
                // Scaled to read like luma for a row of ordinary contrast;
                // a blank row stays flat rather than magnifying noise.
                let scale: Float = deviation > 1 ? 32 / deviation : 0
                let shape = shapes + row * columns
                index = 0
                while index < columns {
                    shape[index] = (out[index] - mean) * scale
                    index += 1
                }
                row += 1
            }

            self.image = image
            self.width = width
            self.height = height
            self.columns = columns
            self.signatures = signatures
            self.profile = profile
            self.shapes = shapes
        }

        deinit {
            signatures.deallocate()
            profile.deallocate()
            shapes.deallocate()
        }
    }
}
