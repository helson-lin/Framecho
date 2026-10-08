//
//  AnnotationMeasureScanner.swift
//  Framecho
//
//  Finds what a click-to-measure measures. Inside a block - a card, a button,
//  a field - it fills the block's color outwards from the pressed pixel and
//  measures the box around everything it reached, so text or an icon inside
//  the block doesn't stop it short. On the background, which runs across the
//  whole image, it measures the gaps either side instead: the run of matching
//  pixels along the pressed row and column.
//

import CoreGraphics
import Synchronization

/// One screenshot's pixels, decoded once and kept for every measurement on it.
///
/// Fills can run off the main actor (a hover asks for one in the background) at the same time as
/// a click asks on it, so the caches sit behind a lock; the pixels never change.
nonisolated final class AnnotationMeasureImage: @unchecked Sendable {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// How far, per 0...255 channel, a pixel may drift from the pressed one and still count as the
    /// same surface. Screenshots are lossless, so this only has to ride out dithering and the
    /// faintest gradients: light interfaces put a white card on a #F5F5F5 page, ten levels apart,
    /// and that edge has to stop the scan.
    static let defaultTolerance = 3

    /// The image this was decoded from, so a caller can tell when it needs a new one.
    let image: CGImage
    let width: Int
    let height: Int
    let tolerance: Int
    /// RGBA, one `UInt32` per pixel, top row first.
    private let pixels: [UInt32]

    private struct Cache {
        /// The last block found and every pixel it covers, so hovering across it needs no new fill.
        var lastBlock: (box: PixelBox, covered: Bitset)?
        /// Pixels already known to be background, collected from every fill that ran into the edges.
        var background: Bitset
    }

    private let cache: Mutex<Cache>

    /// How a fill ended.
    private enum Fill {
        case block(PixelBox)
        case background
        /// The task asking for it was cancelled; nothing was learned.
        case cancelled
    }

    struct PixelBox: Equatable {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
    }

    init?(image: CGImage, tolerance: Int = defaultTolerance) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt32](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: Self.sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            // A bitmap context's first row in memory is the top of what's drawn, so the bytes run
            // in the image's own y-down order.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.image = image
        self.width = width
        self.height = height
        self.tolerance = tolerance
        self.pixels = bytes
        self.cache = Mutex(Cache(background: Bitset(count: width * height)))
    }

    /// What a click at `point` measures, in page space (y-down, `pageSize` units). The image may
    /// be a scaled copy of the page, as the low-resolution preview is.
    ///
    /// Runs the fill here and now if it has to, which on a big panel in a Debug build can take a
    /// while; a hover goes through `computeTarget` instead.
    func target(at point: Vec, pageSize: CGSize) -> MeasureTarget? {
        resolve(point, pageSize: pageSize, fillingIfNeeded: true)
    }

    /// The target if an earlier fill already knows it, without filling anything.
    func cachedTarget(at point: Vec, pageSize: CGSize) -> MeasureTarget? {
        resolve(point, pageSize: pageSize, fillingIfNeeded: false)
    }

    /// `target(at:pageSize:)` off the main actor, giving up if the calling task is cancelled.
    @concurrent
    func computeTarget(at point: Vec, pageSize: CGSize) async -> MeasureTarget? {
        resolve(point, pageSize: pageSize, fillingIfNeeded: true)
    }

    private func resolve(_ point: Vec, pageSize: CGSize, fillingIfNeeded: Bool) -> MeasureTarget? {
        guard pageSize.width > 0, pageSize.height > 0,
              point.x >= 0, point.y >= 0,
              point.x < Double(pageSize.width), point.y < Double(pageSize.height) else { return nil }
        let scaleX = Double(pageSize.width) / Double(width)
        let scaleY = Double(pageSize.height) / Double(height)
        let x = min(width - 1, Int(point.x / scaleX))
        let y = min(height - 1, Int(point.y / scaleY))

        let found: Fill?
        if let known = known(atX: x, y: y) {
            found = known
        } else if fillingIfNeeded {
            found = fill(atX: x, y: y)
        } else {
            found = nil
        }
        switch found {
        case nil, .cancelled:
            return nil
        case let .block(box):
            return .block(
                left: Double(box.minX) * scaleX,
                top: Double(box.minY) * scaleY,
                right: Double(box.maxX + 1) * scaleX,
                bottom: Double(box.maxY + 1) * scaleY
            )
        case .background:
            break
        }
        let across = run(x: x, y: y, horizontal: true)
        let down = run(x: x, y: y, horizontal: false)
        return .spans(MeasureSpans(
            left: Double(across.lowerBound) * scaleX,
            right: Double(across.upperBound + 1) * scaleX,
            top: Double(down.lowerBound) * scaleY,
            bottom: Double(down.upperBound + 1) * scaleY,
            x: (Double(x) + 0.5) * scaleX,
            y: (Double(y) + 0.5) * scaleY
        ))
    }

    // MARK: - Blocks

    /// The bounding box of the enclosed region of the pixel's color, or nil when the region is
    /// background: it spans the whole image across or down.
    func block(atX x: Int, y: Int) -> PixelBox? {
        switch known(atX: x, y: y) ?? fill(atX: x, y: y) {
        case let .block(box): box
        case .background, .cancelled: nil
        }
    }

    /// What an earlier fill already found at this pixel.
    private func known(atX x: Int, y: Int) -> Fill? {
        let index = y * width + x
        return cache.withLock { cache in
            if cache.background.contains(index) { return .background }
            if let lastBlock = cache.lastBlock, lastBlock.covered.contains(index) { return .block(lastBlock.box) }
            return nil
        }
    }

    /// Fill from the pixel and remember what it found. The fill stops as soon as it knows the
    /// region is background, which keeps the biggest region the cheapest to rule out.
    private func fill(atX x: Int, y: Int) -> Fill {
        var covered = Bitset(count: width * height)
        let result = pixels.withUnsafeBufferPointer { pixels in
            covered.withUnsafeMutableWords { covered in
                Self.fill(
                    pixels: pixels.baseAddress!,
                    covered: covered,
                    width: width,
                    height: height,
                    seed: y * width + x,
                    tolerance: tolerance
                )
            }
        }
        cache.withLock { cache in
            switch result {
            case let .block(box): cache.lastBlock = (box, covered)
            case .background: cache.background.formUnion(covered)
            case .cancelled: break
            }
        }
        return result
    }

    /// A scanline fill: take a pixel, widen it to its whole run on the row, then queue the runs
    /// touching it on the rows above and below. Marks what it reaches in `covered` and returns
    /// their bounding box, or background as soon as they span the image.
    ///
    /// Written against raw pointers with the comparison inlined, and optimized even in Debug
    /// builds: through arrays and closures, unoptimized, a full-screen panel on a 5K capture took
    /// seconds to fill, and this runs as the pointer hovers.
    @_optimize(speed)
    private static func fill(
        pixels: UnsafePointer<UInt32>,
        covered: UnsafeMutablePointer<UInt64>,
        width: Int,
        height: Int,
        seed: Int,
        tolerance: Int
    ) -> Fill {
        let target = pixels[seed]
        // Most pixels in an interface match their surface exactly; only the rest are compared
        // channel by channel.
        @inline(__always) func matches(_ i: Int) -> Bool {
            let pixel = pixels[i]
            return pixel == target || (tolerance > 0 && Self.isClose(pixel, target, tolerance))
        }
        @inline(__always) func isCovered(_ i: Int) -> Bool {
            covered[i >> 6] & (1 << UInt64(i & 63)) != 0
        }

        var box = PixelBox(minX: seed % width, minY: seed / width, maxX: seed % width, maxY: seed / width)
        var stack = [seed]
        var runs = 0
        while let start = stack.popLast() {
            guard !isCovered(start) else { continue }
            runs += 1
            if runs & 0xFF == 0, Task.isCancelled { return .cancelled }
            let y = start / width
            let row = y * width
            var left = start - row
            while left > 0, !isCovered(row + left - 1), matches(row + left - 1) { left -= 1 }
            var right = start - row
            while right < width - 1, !isCovered(row + right + 1), matches(row + right + 1) { right += 1 }
            for i in (row + left)...(row + right) { covered[i >> 6] |= 1 << UInt64(i & 63) }

            if left < box.minX { box.minX = left }
            if right > box.maxX { box.maxX = right }
            if y < box.minY { box.minY = y }
            if y > box.maxY { box.maxY = y }
            if box.maxX - box.minX + 1 == width || box.maxY - box.minY + 1 == height { return .background }

            for neighborY in [y - 1, y + 1] where neighborY >= 0 && neighborY < height {
                let neighbor = neighborY * width
                var inRun = false
                for i in (neighbor + left)...(neighbor + right) {
                    let fits = !isCovered(i) && matches(i)
                    if fits && !inRun { stack.append(i) }
                    inRun = fits
                }
            }
        }
        return .block(box)
    }

    /// Whether two RGBA pixels are within `tolerance` on every channel.
    @inline(__always)
    private static func isClose(_ a: UInt32, _ b: UInt32, _ tolerance: Int) -> Bool {
        for shift in stride(from: 0, to: 32, by: 8) {
            let difference = Int((a >> UInt32(shift)) & 0xFF) - Int((b >> UInt32(shift)) & 0xFF)
            if difference > tolerance || difference < -tolerance { return false }
        }
        return true
    }

    // MARK: - Gaps

    /// The run of pixels through (x, y), along its row or down its column, that stay within the
    /// tolerance of it.
    func run(x: Int, y: Int, horizontal: Bool) -> ClosedRange<Int> {
        let count = horizontal ? width : height
        let start = horizontal ? x : y
        let stride = horizontal ? 1 : width
        let origin = horizontal ? y * width : x
        let tolerance = self.tolerance
        return pixels.withUnsafeBufferPointer { pixels in
            let target = pixels[origin + start * stride]
            func matches(_ i: Int) -> Bool {
                let pixel = pixels[origin + i * stride]
                return pixel == target || (tolerance > 0 && Self.isClose(pixel, target, tolerance))
            }
            var lower = start
            while lower > 0, matches(lower - 1) { lower -= 1 }
            var upper = start
            while upper < count - 1, matches(upper + 1) { upper += 1 }
            return lower...upper
        }
    }
}

/// A fixed-size set of pixel indices, one bit each.
struct Bitset {
    private var words: [UInt64]

    init(count: Int) {
        words = [UInt64](repeating: 0, count: (count + 63) / 64)
    }

    @inline(__always)
    func contains(_ i: Int) -> Bool {
        words[i >> 6] & (1 << UInt64(i & 63)) != 0
    }

    @inline(__always)
    mutating func insert(_ i: Int) {
        words[i >> 6] |= 1 << UInt64(i & 63)
    }

    mutating func withUnsafeMutableWords<Result>(_ body: (UnsafeMutablePointer<UInt64>) -> Result) -> Result {
        words.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    mutating func formUnion(_ other: Bitset) {
        for i in words.indices { words[i] |= other.words[i] }
    }
}
