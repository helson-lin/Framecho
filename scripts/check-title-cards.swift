import CoreGraphics
import Foundation

// Intro and outro cards without a movie: how the program clock maps onto
// the edit, the crossfades, and how saved cards decode. See run-checks.sh
// for the files.
@main
struct TitleCardChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func near(_ actual: Double?, _ expected: Double, _ message: String) {
        guard let actual else {
            expect(false, "\(message): expected \(expected), got nil")
            return
        }
        expect(abs(actual - expected) < 0.000_1, "\(message): expected \(expected), got \(actual)")
    }

    static func main() {
        checkProgramClock()
        checkCrossfades()
        checkWithoutCards()
        checkDecoding()
        checkTextStyle()
        checkMotion()
        checkLayouts()
        print("Title card checks passed (\(checks) assertions).")
    }

    static func checkProgramClock() {
        let program = RecordingProgramTimeline(
            intro: RecordingTitleCard(duration: 3),
            videoDuration: 60,
            outro: RecordingTitleCard(duration: 2)
        )
        near(program.duration, 65, "the program is intro + video + outro")
        expect(program.hasCards, "cards are reported")

        near(program.editorTime(at: 0), 0, "the intro holds the video's first frame")
        near(program.editorTime(at: 2.9), 0, "all the way through")
        near(program.editorTime(at: 13), 10, "the video runs after the intro")
        near(program.editorTime(at: 64), 60, "the outro holds the last frame")
        near(program.programTime(forEditorTime: 10), 13, "edit time maps back past the intro")

        expect(program.card(at: 1)?.placement == .intro, "the intro shows first")
        expect(program.card(at: 3) == nil, "no card once the video starts")
        expect(program.card(at: 62.99) == nil, "no card while the video plays")
        let outro = program.card(at: 64)
        expect(outro?.placement == .outro, "the outro shows last")
        near(outro?.time, 1, "time into the outro")
        near(program.card(at: 99)?.time, 2, "past the end it rests on the outro's end")
    }

    static func checkCrossfades() {
        let program = RecordingProgramTimeline(
            intro: RecordingTitleCard(duration: 3),
            videoDuration: 10,
            outro: RecordingTitleCard(duration: 3)
        )
        near(program.card(at: 1)?.opacity, 1, "the intro is solid")
        near(program.card(at: 2.85)?.opacity, 0.5, "half way out of the intro")
        near(program.card(at: 13.15)?.opacity, 0.5, "half way into the outro")
        near(program.card(at: 15)?.opacity, 1, "the outro ends solid")

        let short = RecordingProgramTimeline(intro: RecordingTitleCard(duration: 0.6), videoDuration: 10, outro: nil)
        near(short.introDuration, 1, "a card is never shorter than a second")
        near(RecordingProgramTimeline.transition(for: 0.6), 0.2, "a short card's fade is a third of it")

        let long = RecordingProgramTimeline(intro: RecordingTitleCard(duration: 40), videoDuration: 10, outro: nil)
        near(long.introDuration, 10, "or longer than ten")
    }

    static func checkWithoutCards() {
        let plain = RecordingProgramTimeline(intro: nil, videoDuration: 42, outro: nil)
        expect(!plain.hasCards, "no cards")
        near(plain.duration, 42, "the program is the video")
        near(plain.editorTime(at: 17), 17, "times pass straight through")
        expect(plain.card(at: 0) == nil && plain.card(at: 42) == nil, "and nothing covers it")

        let outroOnly = RecordingProgramTimeline(intro: nil, videoDuration: 10, outro: RecordingTitleCard(duration: 2))
        near(outroOnly.editorTime(at: 5), 5, "an outro alone doesn't move the video")
        expect(outroOnly.card(at: 10.5)?.placement == .outro, "it follows the video")
    }

    static func checkDecoding() {
        let minimal = try! JSONDecoder().decode(RecordingTitleCard.self, from: Data("{}".utf8))
        expect(minimal.kind == .text && minimal.duration == RecordingTitleCard.defaultDuration, "an empty card is a 3 s text card")
        expect(minimal.imageFit == .fit, "images fit by default")

        let future = Data(#"{"kind":"video","imageFit":"stretch","title":"Hi"}"#.utf8)
        let decoded = try! JSONDecoder().decode(RecordingTitleCard.self, from: future)
        expect(decoded.kind == .text && decoded.imageFit == .fit && decoded.title == "Hi",
               "values from a later build fall back instead of losing the card")

        let card = RecordingTitleCard(kind: .image, duration: 4.5, title: "T", subtitle: "S",
                                      imageFileName: "a.png", imageDisplayName: "a", imageFit: .fill)
        expect(try! JSONDecoder().decode(RecordingTitleCard.self, from: JSONEncoder().encode(card)) == card,
               "every field round-trips")

        expect(RecordingTitleCardTypography.usesDarkText(onBackgroundLuminance: 0.9), "dark text on a light background")
        expect(!RecordingTitleCardTypography.usesDarkText(onBackgroundLuminance: 0.1), "light text on a dark one")
        let size = RecordingTitleCardTypography.titleSize(canvasSize: CGSize(width: 1920, height: 1080))
        near(Double(size), 81, "the title scales with the canvas's shorter side")
    }

    static func checkTextStyle() {
        let canvas = CGSize(width: 1920, height: 1080)
        near(Double(RecordingTitleCardTypography.titleSize(canvasSize: canvas, scale: 2)), 162, "the title scale multiplies the size")
        near(Double(RecordingTitleCardTypography.subtitleSize(canvasSize: canvas, scale: 1)), 81 * 0.42, "the subtitle has its own size")

        var card = RecordingTitleCard()
        card.titleScale = 9
        card.subtitleScale = .nan
        near(card.clampedTitleScale, 2, "the title scale is clamped")
        near(card.clampedSubtitleScale, 1, "a broken scale falls back")

        let block = CGSize(width: 800, height: 200)
        let margin = 1080 * Double(RecordingTitleCardTypography.edgeMargin)
        let centered = RecordingTitleCardTypography.blockOrigin(blockSize: block, canvasSize: canvas, position: .center)
        near(Double(centered.x), 560, "a centered block centers horizontally")
        near(Double(centered.y), 440, "and vertically")
        let corner = RecordingTitleCardTypography.blockOrigin(blockSize: block, canvasSize: canvas, position: .bottomLeading)
        near(Double(corner.x), margin, "bottom-left keeps the margin from the left")
        near(Double(corner.y) + 200, 1080 - margin, "and from the bottom")
        let top = RecordingTitleCardTypography.blockOrigin(blockSize: block, canvasSize: canvas, position: .topTrailing)
        near(Double(top.x) + 800, 1920 - margin, "top-right keeps the margin from the right")
        near(Double(top.y), margin, "and from the top")

        let orange = RecordingCardColor(hex: "#FF8000")
        expect(orange == RecordingCardColor(red: 1, green: 128.0 / 255, blue: 0), "hex colors parse")
        expect(orange?.hex == "#FF8000", "and print back")
        expect(RecordingCardColor(hex: "00ff00") != nil, "the # is optional and case doesn't matter")
        expect(RecordingCardColor(hex: "#12345") == nil && RecordingCardColor(hex: "blue") == nil, "anything else is refused")
        expect(RecordingCardColor(red: 1, green: 1, blue: 1).luminance > 0.99, "white is bright")

        let old = try! JSONDecoder().decode(RecordingTitleCard.self, from: Data(#"{"title":"Hi"}"#.utf8))
        expect(old.fontStyle == .system && old.titleWeight == .bold && old.textPosition == .center, "older cards keep the original look")
        expect(old.textColor == nil && old.backgroundColor == nil && !old.hasTextShadow, "with automatic color and the project background")

        var styled = RecordingTitleCard(title: "T")
        styled.fontStyle = .serif
        styled.titleWeight = .heavy
        styled.textColor = RecordingCardColor(red: 1, green: 0.5, blue: 0)
        styled.textPosition = .bottomLeading
        styled.hasTextShadow = true
        styled.backgroundColor = RecordingCardColor(red: 0, green: 0, blue: 0)
        expect(try! JSONDecoder().decode(RecordingTitleCard.self, from: JSONEncoder().encode(styled)) == styled,
               "the style round-trips")
    }

    static func checkMotion() {
        near(RecordingTitleCardMotion.ease(0), 0, "the ease starts at 0")
        near(RecordingTitleCardMotion.ease(1), 1, "and ends at 1")
        expect(RecordingTitleCardMotion.ease(0.3) > 0.8, "it is front-loaded, like the design system's ease-out")
        var previous = -1.0
        for step in 0...20 {
            let value = RecordingTitleCardMotion.ease(Double(step) / 20)
            expect(value >= previous - 1e-9, "the ease never goes backwards")
            previous = value
        }

        func state(_ part: RecordingTitleCardMotion.Part, _ time: Double, animates: Bool = true) -> RecordingTitleCardMotion.State {
            RecordingTitleCardMotion.state(of: part, at: time, cardDuration: 3, animates: animates)
        }
        expect(state(.content(0), 0).opacity == 0, "the title starts hidden")
        expect(state(.content(0), 0).offset > 0, "and lowered")
        expect(state(.content(1), 0.2).opacity == 0, "the subtitle waits for the title")
        expect(state(.content(0), 0.5).opacity > state(.content(1), 0.5).opacity, "and follows it")
        expect(state(.accent, 0).reveal == 0, "the accent starts undrawn")
        let settle = RecordingTitleCardMotion.settleTime
        for part in [RecordingTitleCardMotion.Part.panel, .accent, .content(0), .content(1)] {
            let settled = state(part, settle)
            expect(settled.opacity > 0.999 && abs(settled.offset) < 1e-6 && settled.reveal > 0.999 && abs(settled.scale - 1) < 1e-6,
                   "\(part) has arrived by the settle time")
        }
        near(state(.background, 0).scale, 1, "the background starts unzoomed")
        near(state(.background, 3).scale, 1 + RecordingTitleCardMotion.backgroundZoom, "and has pushed in by the end")
        expect(state(.background, 1).scale < state(.background, 2).scale, "pushing in all the way through")
        expect(state(.content(0), 0, animates: false) == .settled, "a card that doesn't animate shows settled")
        expect(state(.background, 2, animates: false) == .settled, "including its background")
    }

    static func checkLayouts() {
        var card = RecordingTitleCard(title: "Hello", subtitle: "World")
        expect(RecordingTitleCard.Layout.matching(card) == .centered, "a new card is the centered layout")
        RecordingTitleCard.Layout.lowerThird.apply(to: &card)
        expect(card.textPosition == .bottomLeading && card.accent == .bar && card.hasTextPanel, "lower third: corner, bar, panel")
        expect(card.title == "Hello" && card.subtitle == "World", "a layout keeps the words")
        expect(RecordingTitleCard.Layout.matching(card) == .lowerThird, "and is recognized again")
        card.titleScale = 0.9
        expect(RecordingTitleCard.Layout.matching(card) == nil, "an adjusted card no longer matches a layout")
        RecordingTitleCard.Layout.hero.apply(to: &card)
        expect(card.titleWeight == .heavy && card.titleScale > 1.5 && card.accent == .line, "hero: a big heavy title over a line")
        let decoded = try! JSONDecoder().decode(RecordingTitleCard.self, from: JSONEncoder().encode(card))
        expect(decoded == card, "accent, panel and motion round-trip")
        let old = try! JSONDecoder().decode(RecordingTitleCard.self, from: Data(#"{"title":"Hi"}"#.utf8))
        expect(old.accent == .none && !old.hasTextPanel && old.animatesIn, "older cards gain the entrance and no decoration")
    }
}
