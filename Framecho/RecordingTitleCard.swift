//
//  RecordingTitleCard.swift
//  Framecho
//
//  Intro and outro cards: a few seconds of title or image before and after
//  the video. They live outside the edit timeline - cuts, zooms, captions
//  and every other editor-time track are untouched - and only the final
//  program, as played and exported, runs intro + video + outro.
//

import CoreGraphics
import Foundation

nonisolated struct RecordingTitleCard: Codable, Equatable, Sendable {
    static let durationRange: ClosedRange<TimeInterval> = 1...10
    static let defaultDuration: TimeInterval = 3
    /// The crossfade between a card and the video beside it.
    static let transitionDuration: TimeInterval = 0.3

    enum Placement: String, Codable, CaseIterable, Sendable {
        case intro
        case outro
    }

    enum Kind: String, Codable, CaseIterable, Sendable {
        /// A title and subtitle on the project's background.
        case text
        case image
    }

    enum ImageFit: String, Codable, CaseIterable, Sendable {
        /// Covers the canvas, cropping what doesn't fit.
        case fill
        /// Shows the whole image on the project's background.
        case fit
    }

    /// The system font's designs, so every script the title is written in
    /// gets a matching face.
    enum FontStyle: String, Codable, CaseIterable, Sendable {
        case system
        case rounded
        case serif
        case monospaced
    }

    enum FontWeight: String, Codable, CaseIterable, Sendable {
        case regular
        case medium
        case semibold
        case bold
        case heavy
    }

    static let textScaleRange: ClosedRange<Double> = 0.5...2

    /// A rule drawn with the text, in the text's color.
    enum Accent: String, Codable, CaseIterable, Sendable {
        case none
        /// A short line between the title and the subtitle.
        case line
        /// A vertical bar beside the text block, on its aligned side.
        case bar
    }

    /// Ready-made arrangements. Each only sets the fields below, so a card
    /// stays freely adjustable after one is applied.
    enum Layout: String, CaseIterable, Sendable {
        case centered
        case lowerThird
        case hero
        case editorial

        func apply(to card: inout RecordingTitleCard) {
            switch self {
            case .centered:
                card.textPosition = .center
                card.fontStyle = .system
                card.titleWeight = .bold
                card.titleScale = 1
                card.subtitleScale = 1
                card.accent = .none
                card.hasTextPanel = false
            case .lowerThird:
                card.textPosition = .bottomLeading
                card.fontStyle = .system
                card.titleWeight = .semibold
                card.titleScale = 0.75
                card.subtitleScale = 0.95
                card.accent = .bar
                card.hasTextPanel = true
            case .hero:
                card.textPosition = .leading
                card.fontStyle = .system
                card.titleWeight = .heavy
                card.titleScale = 1.8
                card.subtitleScale = 1.15
                card.accent = .line
                card.hasTextPanel = false
            case .editorial:
                card.textPosition = .topLeading
                card.fontStyle = .serif
                card.titleWeight = .bold
                card.titleScale = 1.3
                card.subtitleScale = 1
                card.accent = .line
                card.hasTextPanel = false
            }
        }

        /// The layout a card's fields currently spell, if any.
        static func matching(_ card: RecordingTitleCard) -> Layout? {
            allCases.first { layout in
                var applied = card
                layout.apply(to: &applied)
                return applied == card
            }
        }
    }

    var kind: Kind
    var duration: TimeInterval
    /// Kept when switching to an image card, so switching back restores it.
    var title: String
    var subtitle: String
    /// The image's file in the package's assets folder.
    var imageFileName: String?
    var imageDisplayName: String?
    var imageFit: ImageFit
    var fontStyle: FontStyle
    var titleWeight: FontWeight
    /// Multipliers on the default title and subtitle sizes.
    var titleScale: Double
    var subtitleScale: Double
    /// Nil picks black or white for the background.
    var textColor: RecordingCardColor?
    /// Where the text block sits; its side sets the alignment.
    var textPosition: RecordingImageOverlayAnchor
    var hasTextShadow: Bool
    /// Nil uses the project's background.
    var backgroundColor: RecordingCardColor?
    var accent: Accent
    /// A translucent panel behind the text, for busy backgrounds.
    var hasTextPanel: Bool
    /// Eases the card's parts in instead of showing them all at once.
    var animatesIn: Bool

    init(
        kind: Kind = .text,
        duration: TimeInterval = RecordingTitleCard.defaultDuration,
        title: String = "",
        subtitle: String = "",
        imageFileName: String? = nil,
        imageDisplayName: String? = nil,
        imageFit: ImageFit = .fit,
        fontStyle: FontStyle = .system,
        titleWeight: FontWeight = .bold,
        titleScale: Double = 1,
        subtitleScale: Double = 1,
        textColor: RecordingCardColor? = nil,
        textPosition: RecordingImageOverlayAnchor = .center,
        hasTextShadow: Bool = false,
        backgroundColor: RecordingCardColor? = nil,
        accent: Accent = .none,
        hasTextPanel: Bool = false,
        animatesIn: Bool = true
    ) {
        self.kind = kind
        self.duration = duration
        self.title = title
        self.subtitle = subtitle
        self.imageFileName = imageFileName
        self.imageDisplayName = imageDisplayName
        self.imageFit = imageFit
        self.fontStyle = fontStyle
        self.titleWeight = titleWeight
        self.titleScale = titleScale
        self.subtitleScale = subtitleScale
        self.textColor = textColor
        self.textPosition = textPosition
        self.hasTextShadow = hasTextShadow
        self.backgroundColor = backgroundColor
        self.accent = accent
        self.hasTextPanel = hasTextPanel
        self.animatesIn = animatesIn
    }

    var clampedDuration: TimeInterval {
        duration.isFinite
            ? min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
            : Self.defaultDuration
    }

    var clampedTitleScale: Double { Self.clampScale(titleScale) }
    var clampedSubtitleScale: Double { Self.clampScale(subtitleScale) }

    private static func clampScale(_ scale: Double) -> Double {
        scale.isFinite ? min(max(scale, textScaleRange.lowerBound), textScaleRange.upperBound) : 1
    }

    private enum CodingKeys: String, CodingKey {
        case kind, duration, title, subtitle, imageFileName, imageDisplayName, imageFit
        case fontStyle, titleWeight, titleScale, subtitleScale, textColor, textPosition, hasTextShadow
        case backgroundColor, accent, hasTextPanel, animatesIn
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown values from a later build fall back rather than dropping
        // the whole project.
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)).flatMap { $0 } ?? .text
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? Self.defaultDuration
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        imageDisplayName = try container.decodeIfPresent(String.self, forKey: .imageDisplayName)
        imageFit = (try? container.decodeIfPresent(ImageFit.self, forKey: .imageFit)).flatMap { $0 } ?? .fit
        fontStyle = (try? container.decodeIfPresent(FontStyle.self, forKey: .fontStyle)).flatMap { $0 } ?? .system
        titleWeight = (try? container.decodeIfPresent(FontWeight.self, forKey: .titleWeight)).flatMap { $0 } ?? .bold
        titleScale = try container.decodeIfPresent(Double.self, forKey: .titleScale) ?? 1
        subtitleScale = try container.decodeIfPresent(Double.self, forKey: .subtitleScale) ?? 1
        textColor = try? container.decodeIfPresent(RecordingCardColor.self, forKey: .textColor)
        textPosition = (try? container.decodeIfPresent(RecordingImageOverlayAnchor.self, forKey: .textPosition))
            .flatMap { $0 } ?? .center
        hasTextShadow = try container.decodeIfPresent(Bool.self, forKey: .hasTextShadow) ?? false
        backgroundColor = try? container.decodeIfPresent(RecordingCardColor.self, forKey: .backgroundColor)
        accent = (try? container.decodeIfPresent(Accent.self, forKey: .accent)).flatMap { $0 } ?? .none
        hasTextPanel = try container.decodeIfPresent(Bool.self, forKey: .hasTextPanel) ?? false
        animatesIn = try container.decodeIfPresent(Bool.self, forKey: .animatesIn) ?? true
    }
}

/// The final program: intro card, the edited video, outro card. Maps its
/// clock onto the edit timeline, holding the video's first frame under the
/// intro and its last under the outro, which show through the crossfades.
nonisolated struct RecordingProgramTimeline: Sendable, Equatable {
    struct CardFrame: Sendable, Equatable {
        var placement: RecordingTitleCard.Placement
        /// Time into the card.
        var time: TimeInterval
        /// The card's strength over the held video frame.
        var opacity: Double
    }

    let introDuration: TimeInterval
    let videoDuration: TimeInterval
    let outroDuration: TimeInterval

    init(intro: RecordingTitleCard?, videoDuration: TimeInterval, outro: RecordingTitleCard?) {
        introDuration = intro?.clampedDuration ?? 0
        self.videoDuration = max(0, videoDuration.isFinite ? videoDuration : 0)
        outroDuration = outro?.clampedDuration ?? 0
    }

    var duration: TimeInterval { introDuration + videoDuration + outroDuration }

    var hasCards: Bool { introDuration > 0 || outroDuration > 0 }

    /// The video's time at a program time, held at its ends during cards.
    func editorTime(at programTime: TimeInterval) -> TimeInterval {
        min(max(programTime - introDuration, 0), videoDuration)
    }

    func programTime(forEditorTime editorTime: TimeInterval) -> TimeInterval {
        introDuration + min(max(editorTime, 0), videoDuration)
    }

    func card(at programTime: TimeInterval) -> CardFrame? {
        if introDuration > 0, programTime < introDuration {
            let time = max(0, programTime)
            return CardFrame(
                placement: .intro,
                time: time,
                opacity: Self.opacity(fadingOutOver: introDuration, at: time)
            )
        }
        let outroStart = introDuration + videoDuration
        if outroDuration > 0, programTime >= outroStart {
            let time = min(programTime - outroStart, outroDuration)
            return CardFrame(
                placement: .outro,
                time: time,
                opacity: Self.opacity(fadingInOver: outroDuration, at: time)
            )
        }
        return nil
    }

    /// The crossfade, never more than a third of a short card.
    static func transition(for cardDuration: TimeInterval) -> TimeInterval {
        min(RecordingTitleCard.transitionDuration, cardDuration / 3)
    }

    private static func opacity(fadingOutOver duration: TimeInterval, at time: TimeInterval) -> Double {
        let fade = transition(for: duration)
        guard fade > 0 else { return 1 }
        return min(1, max(0, (duration - time) / fade))
    }

    private static func opacity(fadingInOver duration: TimeInterval, at time: TimeInterval) -> Double {
        let fade = transition(for: duration)
        guard fade > 0 else { return 1 }
        return min(1, max(0, time / fade))
    }
}

/// An opaque sRGB color, as a card stores its text and background colors.
nonisolated struct RecordingCardColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
    }

    /// `#RRGGBB` or `RRGGBB`; nil for anything else.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// How a text card sets its type, shared by preview and export so both
/// draw the same card.
nonisolated enum RecordingTitleCardTypography {
    /// Title size against the canvas's shorter side, before the card's own
    /// scale.
    static func titleSize(canvasSize: CGSize, scale: Double = 1) -> CGFloat {
        max(10, min(canvasSize.width, canvasSize.height) * 0.075 * CGFloat(scale))
    }

    static func subtitleSize(canvasSize: CGSize, scale: Double = 1) -> CGFloat {
        max(8, min(canvasSize.width, canvasSize.height) * 0.075 * 0.42 * CGFloat(scale))
    }

    /// Gap kept between the text and the canvas edge, against the shorter
    /// side.
    static let edgeMargin: CGFloat = 0.08

    /// The text block's top-left corner, top-left origin, for a block of
    /// `blockSize` at `position`.
    static func blockOrigin(
        blockSize: CGSize,
        canvasSize: CGSize,
        position: RecordingImageOverlayAnchor
    ) -> CGPoint {
        let margin = min(canvasSize.width, canvasSize.height) * edgeMargin
        let x: CGFloat = switch position.column {
        case 0: margin
        case 2: canvasSize.width - margin - blockSize.width
        default: (canvasSize.width - blockSize.width) / 2
        }
        let y: CGFloat = switch position.row {
        case 0: margin
        case 2: canvasSize.height - margin - blockSize.height
        default: (canvasSize.height - blockSize.height) / 2
        }
        return CGPoint(x: x, y: y)
    }

    /// Lines wrap inside this share of the canvas width.
    static let maximumWidthFraction: CGFloat = 0.8

    /// Light text on dark backgrounds, dark on light, judged by the
    /// background's relative luminance (0–1).
    static func usesDarkText(onBackgroundLuminance luminance: Double) -> Bool {
        luminance > 0.6
    }
}

/// How a card's parts ease in, shared by preview and export. Times are
/// seconds into the card.
nonisolated enum RecordingTitleCardMotion {
    enum Part: Sendable, Equatable {
        case background
        case panel
        case accent
        /// Text and image blocks, in reading order from 0.
        case content(Int)
    }

    /// One part's state at a moment.
    struct State: Sendable, Equatable {
        var opacity: Double = 1
        /// Downward offset, as a share of the canvas height.
        var offset: Double = 0
        var scale: Double = 1
        /// How far an accent has drawn along its length, 0–1.
        var reveal: Double = 1

        static let settled = State()
    }

    /// When every part has arrived; the preview rests here while editing.
    static let settleTime: TimeInterval = 1.2
    static let backgroundZoom = 0.05
    static let riseDistance = 0.03

    static func state(of part: Part, at time: TimeInterval, cardDuration: TimeInterval, animates: Bool) -> State {
        guard animates else { return .settled }
        switch part {
        case .background:
            // A slow push in over the whole card.
            let progress = cardDuration > 0 ? min(max(time / cardDuration, 0), 1) : 1
            return State(scale: 1 + backgroundZoom * ease(progress))
        case .panel:
            let progress = ease(window(time, start: 0.05, length: 0.5))
            return State(opacity: progress)
        case .accent:
            let progress = ease(window(time, start: 0.25, length: 0.6))
            return State(opacity: min(1, progress * 2), reveal: progress)
        case .content(let index):
            let progress = ease(window(time, start: 0.15 + 0.15 * Double(index), length: 0.7))
            return State(opacity: progress, offset: riseDistance * (1 - progress), scale: 0.98 + 0.02 * progress)
        }
    }

    private static func window(_ time: TimeInterval, start: TimeInterval, length: TimeInterval) -> Double {
        min(max((time - start) / length, 0), 1)
    }

    /// The design system's ease-out, cubic-bezier(0.16, 1, 0.3, 1).
    static func ease(_ progress: Double) -> Double {
        cubicBezier(progress, x1: 0.16, y1: 1, x2: 0.3, y2: 1)
    }

    /// y for x on a CSS-style cubic Bézier from (0,0) to (1,1).
    static func cubicBezier(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let x = min(max(x, 0), 1)
        func component(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        // Bisection on the curve's x, which is monotonic for x1, x2 in 0...1.
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0..<40 {
            let current = component(t, x1, x2)
            if abs(current - x) < 1e-7 { break }
            if current < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return component(t, y1, y2)
    }
}
