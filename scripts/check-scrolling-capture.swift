import CoreGraphics
import Foundation

// Stitches synthetic scrolling frames and compares the result with the page
// they were cut from. Run by scripts/run-checks.sh, or on its own:
// xcrun swiftc -O -module-cache-path /tmp/framecho-scroll-module-cache \
//   Framecho/ScrollingCaptureStitcher.swift scripts/check-scrolling-capture.swift \
//   -o /tmp/framecho-scroll-check && /tmp/framecho-scroll-check
@main
struct ScrollingCaptureChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() {
        checkPlainScroll()
        checkStickyBars()
        checkIgnoredFrames()
        checkNoiseAndScrollBar()
        checkLimit()
        checkEdgeCases()
        checkSpeed()
        print("Scrolling capture checks passed (\(checks) assertions).")
    }

    // MARK: - Cases

    static func checkPlainScroll() {
        let page = Page.text(width: 320, height: 2400, seed: 1)
        let layout = Layout(viewport: 480)
        // Steps of 3 to 300 rows, including a single row.
        let offsets = [0, 3, 40, 160, 161, 400, 700, 1000, 1300, 1600, 1920]
        let image = stitch(page, layout, offsets, expecting: .appended)
        same(image, layout.expected(page, through: 1920), "Plain scroll")
    }

    static func checkStickyBars() {
        let page = Page.text(width: 320, height: 2400, seed: 2)
        let layout = Layout(viewport: 480, header: 48, footer: 32)
        let offsets = [0, 37, 150, 151, 390, 600, 900, 1150, 1400, 1700, 2000]
        let image = stitch(page, layout, offsets, expecting: .appended)
        same(image, layout.expected(page, through: 2000), "Header and footer appear once")
    }

    static func checkIgnoredFrames() {
        let page = Page.text(width: 320, height: 2400, seed: 3)
        let layout = Layout(viewport: 480, header: 40)
        var stitcher = ScrollingCaptureStitcher()
        func add(_ offset: Int) -> ScrollingCaptureStitcher.Outcome {
            stitcher.add(layout.frame(page, offset: offset))
        }
        expect(add(0) == .started, "First frame starts")
        expect(add(0) == .unchanged, "Same frame again")
        expect(add(120) == .appended(rows: 120), "Scrolled 120 rows")
        // Rows that happen to match in place at the bottom wait like a
        // footer, so the count can fall short; the image below is the test.
        expect(add(80) == .scrolledBackward, "Scrolled back up")
        expect(add(120 + 440) == .noMatch, "Jumped past the whole band")
        let recovered = add(400)
        expect(recovered != .noMatch && recovered != .scrolledBackward, "Picks up from the last accepted frame, got \(recovered)")
        same(stitcher.makeImage(), layout.expected(page, through: 400), "Ignored frames leave no trace")
    }

    static func checkNoiseAndScrollBar() {
        let page = Page.text(width: 320, height: 2400, seed: 4)
        let layout = Layout(viewport: 480, header: 30, scrollBar: true, noise: true)
        let offsets = [0, 90, 200, 330, 500, 800, 1100, 1400, 1700, 1920]
        let image = stitch(page, layout, offsets, expecting: .appended)
        // The overlay scroll bar moves with every frame and stays out of the comparison.
        same(image, layout.expected(page, through: 1920), "Noise and a scroll bar", columns: 0..<(320 - Layout.scrollBarWidth), tolerance: 3)
    }

    static func checkLimit() {
        let page = Page.text(width: 320, height: 2400, seed: 5)
        let layout = Layout(viewport: 480)
        var stitcher = ScrollingCaptureStitcher(maximumHeight: 700)
        expect(stitcher.add(layout.frame(page, offset: 0)) == .started, "Limit: start")
        expect(stitcher.add(layout.frame(page, offset: 200)) == .appended(rows: 200), "Limit: room for 200 rows")
        expect(stitcher.add(layout.frame(page, offset: 400)) == .reachedLimit, "Limit: no room for 200 more")
        expect(stitcher.height == 680, "Limit: height stays at 680, got \(stitcher.height)")
        same(stitcher.makeImage(), layout.expected(page, through: 200), "Limit: image ends at the last frame that fit")
    }

    static func checkEdgeCases() {
        let page = Page.text(width: 320, height: 2400, seed: 6)
        let layout = Layout(viewport: 480)

        var empty = ScrollingCaptureStitcher()
        expect(empty.makeImage() == nil && empty.height == 0, "Nothing added, no image")

        let first = layout.frame(page, offset: 0)
        expect(empty.add(first) == .started, "Single frame starts")
        same(empty.makeImage(), layout.expected(page, through: 0), "A single frame comes back as it is")

        let narrow = Layout(viewport: 480).frame(Page.text(width: 300, height: 2400, seed: 6), offset: 40)
        expect(empty.add(narrow) == .sizeMismatch, "A frame of another width is refused")

        // A blank page matches at any shift: nothing is appended.
        var blank = ScrollingCaptureStitcher()
        let white = Page.blank(width: 320, height: 2400)
        expect(blank.add(layout.frame(white, offset: 0)) == .started, "Blank: start")
        expect(blank.add(layout.frame(white, offset: 100)) == .unchanged, "Blank: nothing to see")
        expect(blank.height == 480, "Blank: nothing appended")
    }

    static func checkSpeed() {
        // A Retina window: 1512 × 1800 pixels.
        let page = Page.text(width: 1512, height: 4000, seed: 7)
        let layout = Layout(viewport: 1800, header: 100)
        var stitcher = ScrollingCaptureStitcher()
        _ = stitcher.add(layout.frame(page, offset: 0))
        let frame = layout.frame(page, offset: 700)
        let clock = ContinuousClock()
        var outcome = ScrollingCaptureStitcher.Outcome.unchanged
        let elapsed = clock.measure { outcome = stitcher.add(frame) }
        expect(outcome == .appended(rows: 700), "Large frame: scrolled 700 rows, got \(outcome)")
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("Matched a 1512 × 1800 frame in \(Int(milliseconds)) ms")
        expect(milliseconds < 1500, "Large frame took \(Int(milliseconds)) ms")
    }

    // MARK: - Helpers

    enum Expected { case appended }

    static func stitch(_ page: Page, _ layout: Layout, _ offsets: [Int], expecting: Expected) -> CGImage? {
        var stitcher = ScrollingCaptureStitcher()
        for (index, offset) in offsets.enumerated() {
            let outcome = stitcher.add(layout.frame(page, offset: offset))
            if index == 0 {
                expect(outcome == .started, "Offset \(offset): expected started, got \(outcome)")
            } else if case .appended = outcome {
                expect(true, "")
            } else {
                expect(false, "Offset \(offset): expected appended, got \(outcome)")
            }
        }
        return stitcher.makeImage()
    }

    static func same(
        _ image: CGImage?, _ expected: Page, _ message: String,
        columns: Range<Int>? = nil, tolerance: Int = 0
    ) {
        guard let image else { return expect(false, "\(message): no image") }
        expect(image.width == expected.width && image.height == expected.height,
               "\(message): expected \(expected.width) × \(expected.height), got \(image.width) × \(image.height)")
        let actual = Page(image)
        let columns = columns ?? 0..<expected.width
        for row in 0..<expected.height {
            for column in columns {
                for channel in 0..<3 {
                    let index = (row * expected.width + column) * 4 + channel
                    if abs(Int(actual.pixels[index]) - Int(expected.pixels[index])) > tolerance {
                        return expect(false, "\(message): pixel differs at row \(row), column \(column)")
                    }
                }
            }
        }
        expect(true, message)
    }
}

/// How a frame is cut from a page: a viewport with optional fixed bars, an
/// overlay scroll bar and a little capture noise.
struct Layout {
    static let scrollBarWidth = 8

    var viewport: Int
    var header = 0
    var footer = 0
    var scrollBar = false
    var noise = false

    var band: Int { viewport - header - footer }

    func frame(_ page: Page, offset: Int) -> CGImage {
        var frame = Page(width: page.width, height: viewport)
        for row in 0..<viewport {
            if row < header {
                frame.fillRow(row, with: Self.barColor(row, seed: 11))
            } else if row >= viewport - footer {
                frame.fillRow(row, with: Self.barColor(row, seed: 23))
            } else {
                frame.copyRow(row, from: page, row: offset + row - header)
            }
        }
        if scrollBar {
            // A thumb a fifth of the band tall, placed by how far the page has scrolled.
            let thumb = band / 5
            let y = header + (band - thumb) * offset / max(1, page.height - band)
            for row in y..<(y + thumb) {
                for column in (page.width - Self.scrollBarWidth)..<page.width {
                    frame.set(row, column, (120, 120, 120))
                }
            }
        }
        if noise {
            var random = Random(seed: UInt64(offset) + 99)
            for index in frame.pixels.indices where index % 4 != 3 {
                let value = Int(frame.pixels[index]) + Int(random.next() % 3) - 1
                frame.pixels[index] = UInt8(clamping: value)
            }
        }
        return frame.image()
    }

    /// What stitching frames up to `offset` should give: the header, every
    /// page row seen, then the footer.
    func expected(_ page: Page, through offset: Int) -> Page {
        let height = header + offset + band + footer
        var result = Page(width: page.width, height: height)
        for row in 0..<height {
            if row < header {
                result.fillRow(row, with: Self.barColor(row, seed: 11))
            } else if row >= height - footer {
                result.fillRow(row, with: Self.barColor(viewport - (height - row), seed: 23))
            } else {
                result.copyRow(row, from: page, row: row - header)
            }
        }
        return result
    }

    /// Bars have detail of their own, so they could be mistaken for content.
    static func barColor(_ row: Int, seed: Int) -> (UInt8, UInt8, UInt8) {
        let shade = UInt8((row * 7 + seed * 13) % 60)
        return (40 + shade, 60, 180 - shade)
    }
}

/// RGBA pixels, top row first.
struct Page {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 255, count: width * height * 4)
    }

    init(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Lines of "words" in 24-row blocks on slightly varying paper, with an
    /// empty line now and then, like a document.
    static func text(width: Int, height: Int, seed: UInt64) -> Page {
        var page = Page(width: width, height: height)
        var random = Random(seed: seed)
        for block in 0..<(height + 23) / 24 {
            let paper = UInt8(244 + block % 5)
            let top = block * 24
            for row in top..<min(top + 24, height) { page.fillRow(row, with: (paper, paper, paper)) }
            if random.next() % 7 == 0 { continue }
            var x = 8 + Int(random.next() % 24)
            while x < width - 16 {
                let length = 8 + Int(random.next() % 48)
                let ink = (UInt8(20 + random.next() % 60), UInt8(20 + random.next() % 60), UInt8(20 + random.next() % 60))
                for row in (top + 7)..<min(top + 17, height) {
                    for column in x..<min(x + length, width - 16) { page.set(row, column, ink) }
                }
                x += length + 6 + Int(random.next() % 10)
            }
        }
        return page
    }

    static func blank(width: Int, height: Int) -> Page {
        Page(width: width, height: height)
    }

    mutating func set(_ row: Int, _ column: Int, _ color: (UInt8, UInt8, UInt8)) {
        let index = (row * width + column) * 4
        pixels[index] = color.0
        pixels[index + 1] = color.1
        pixels[index + 2] = color.2
        pixels[index + 3] = 255
    }

    mutating func fillRow(_ row: Int, with color: (UInt8, UInt8, UInt8)) {
        for column in 0..<width { set(row, column, color) }
    }

    mutating func copyRow(_ row: Int, from page: Page, row source: Int) {
        let count = width * 4
        pixels.replaceSubrange((row * count)..<((row + 1) * count),
                               with: page.pixels[(source * count)..<((source + 1) * count)])
    }

    func image() -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

/// A repeatable pseudo-random sequence (SplitMix64).
struct Random {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
