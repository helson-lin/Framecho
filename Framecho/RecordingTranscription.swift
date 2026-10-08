//
//  RecordingTranscription.swift
//  Framecho
//
//  Narration subtitles for the recording studio: SpeechAnalyzer (the
//  macOS 26 on-device transcription engine) turns the recorded microphone
//  track into timed subtitle cues on the source timeline. The timeline and
//  bar metrics are shared verbatim by the live preview and the offline
//  exporter, exactly like the keystroke caption.
//

import AVFoundation
import CoreGraphics
import Foundation
import Speech

/// One transcribed word on the source (unedited) timeline, in seconds.
/// `text` keeps the transcript's original trailing punctuation/spacing so
/// concatenating words reconstructs the transcript exactly.
nonisolated struct RecordingTranscriptWord: Codable, Sendable, Equatable {
    /// What the recognizer heard. Never rewritten, so revisions can always
    /// be reverted to it.
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// Replacement for the word in captions (a correction). Spans of
    /// several words carry the replacement on the first word and an empty
    /// string on the rest, so the span keeps its timing.
    var correctedText: String?
    /// Dropped from captions (a filler) without cutting its audio.
    var isHiddenInCaptions = false

    init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        correctedText: String? = nil,
        isHiddenInCaptions: Bool = false
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.correctedText = correctedText
        self.isHiddenInCaptions = isHiddenInCaptions
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case correctedText
        case isHiddenInCaptions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        // Words saved before caption revisions shipped carry neither.
        correctedText = try container.decodeIfPresent(String.self, forKey: .correctedText)
        isHiddenInCaptions = try container.decodeIfPresent(Bool.self, forKey: .isHiddenInCaptions) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        // Unrevised words - nearly all of them - stay as small as before.
        try container.encodeIfPresent(correctedText, forKey: .correctedText)
        if isHiddenInCaptions {
            try container.encode(true, forKey: .isHiddenInCaptions)
        }
    }

    /// Word as shown in the transcript editor, without the glued spacing.
    var displayText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The word as captions show it, keeping the recognizer's glued
    /// spacing around a correction so concatenation still reads naturally.
    /// Empty when hidden.
    var captionText: String {
        if isHiddenInCaptions { return "" }
        guard let correctedText else { return text }
        let corrected = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { return "" }
        let leading = text.prefix { $0.isWhitespace }
        let trailing = text.reversed().prefix { $0.isWhitespace }.reversed()
        return leading + corrected + String(trailing)
    }

    var hasCaptionRevision: Bool {
        correctedText != nil || isHiddenInCaptions
    }

    var midpoint: TimeInterval {
        (start + end) / 2
    }
}

/// A caption revision for one word, as suggested by caption cleanup and
/// applied in one undoable step.
nonisolated struct TranscriptWordRevision: Sendable, Equatable {
    var correctedText: String?
    var isHiddenInCaptions: Bool

    static let original = TranscriptWordRevision(correctedText: nil, isHiddenInCaptions: false)
}

/// How transcript words map onto subtitle cues, and the caption text the
/// words produce. A word belongs to the last cue starting at or before it -
/// the same rule the cues were chunked by - as long as it starts before
/// that cue ends, so this holds after cues are moved, trimmed or deleted.
nonisolated enum TranscriptCaptionText {
    /// Indices into `words` for each cue in `cues`, in cue order.
    static func wordIndices(
        for cues: [RecordingSubtitleCue],
        words: [RecordingTranscriptWord]
    ) -> [[Int]] {
        var result: [[Int]] = cues.map { _ in [] }
        let cueOrder = cues.indices
            .filter { cues[$0].start.isFinite }
            .sorted { cues[$0].start < cues[$1].start }
        guard !cueOrder.isEmpty else { return result }

        var position = 0
        for index in words.indices.sorted(by: { words[$0].start < words[$1].start }) {
            let start = words[index].start
            while position < cueOrder.count - 1,
                  start >= cues[cueOrder[position + 1]].start - 0.001 {
                position += 1
            }
            // Words before the first cue, and words past the end of the cue
            // they follow (its tail was trimmed, or the cue after it was
            // deleted), have no caption to belong to.
            let cue = cues[cueOrder[position]]
            guard start >= cue.start - 0.001, start < cue.end else { continue }
            result[cueOrder[position]].append(index)
        }
        return result
    }

    /// The caption a run of words reads as.
    static func text(of words: some Sequence<RecordingTranscriptWord>) -> String {
        pieces(of: words).map(\.text).joined()
    }

    /// The caption's visible words, in order, each carrying its own leading
    /// space so plain concatenation reads as the caption, with the offset of
    /// the word it came from. Punctuation the recognizer glued to a word can
    /// dangle once its neighbor is hidden or corrected away ("嗯，包括" →
    /// "，包括"), so a caption never opens with a separator and two separators
    /// never stack ("好，，然后"); the stronger one wins ("好，。" → "好。").
    static func pieces(
        of words: some Sequence<RecordingTranscriptWord>
    ) -> [(offset: Int, text: String)] {
        var pieces: [(offset: Int, text: String)] = []
        var pendingSpace = false
        for (offset, word) in words.enumerated() {
            let caption = word.captionText
            var trimmed = Substring(caption.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !trimmed.isEmpty else {
                pendingSpace = pendingSpace || !caption.isEmpty
                continue
            }

            let lead = trimmed.prefix(while: \.isCaptionSeparator)
            if !lead.isEmpty {
                trimmed = trimmed.dropFirst(lead.count)
                if let last = pieces.indices.last {
                    let previous = pieces[last].text
                    let trail = previous.reversed().prefix(while: \.isCaptionSeparator)
                    if trail.isEmpty {
                        // Punctuation that belongs to the previous word.
                        pieces[last].text += lead
                    } else if lead.contains(where: \.isSentenceEnd), !trail.contains(where: \.isSentenceEnd) {
                        pieces[last].text = String(previous.dropLast(trail.count)) + lead
                    }
                }
                // Nothing before it: a caption doesn't open on punctuation.
            }
            if trimmed.isEmpty {
                pendingSpace = caption.last?.isWhitespace == true
                continue
            }

            let spaced = !pieces.isEmpty && (pendingSpace || caption.first?.isWhitespace == true)
            pieces.append((offset, spaced ? " " + trimmed : String(trimmed)))
            pendingSpace = caption.last?.isWhitespace == true
        }
        return pieces
    }

    /// Whether a cue still reads as its words rather than as text the user
    /// typed. Captions derived before punctuation was tidied (plain
    /// concatenation) still count, so they keep following their words.
    static func cue(_ cue: RecordingSubtitleCue, readsAs words: [RecordingTranscriptWord]) -> Bool {
        cue.text == text(of: words)
            || cue.text == words.map(\.captionText).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-derives captions that still read as their words, so captions
    /// saved with dangling punctuation pick up the tidy text. Captions the
    /// user typed are left alone.
    static func tidied(
        _ cues: [RecordingSubtitleCue],
        words: [RecordingTranscriptWord],
        isIncluded: (Int) -> Bool = { _ in true }
    ) -> [RecordingSubtitleCue] {
        guard !words.isEmpty else { return cues }
        var result = cues
        for (cueIndex, indices) in wordIndices(for: cues, words: words).enumerated() where !indices.isEmpty {
            let cueWords = indices.filter(isIncluded).map { words[$0] }
            if cue(cues[cueIndex], readsAs: cueWords) {
                result[cueIndex].text = text(of: cueWords)
            }
        }
        return result
    }

    /// Applies word revisions and rewrites the captions they touch. A cue
    /// whose text no longer matches its words was edited by hand and keeps
    /// its text; revising a word never overwrites what the user typed.
    /// `isIncluded` leaves out words whose audio was cut, which their
    /// captions no longer show.
    static func applying(
        _ revisions: [Int: TranscriptWordRevision],
        to words: [RecordingTranscriptWord],
        cues: [RecordingSubtitleCue],
        isIncluded: (Int) -> Bool = { _ in true }
    ) -> (words: [RecordingTranscriptWord], cues: [RecordingSubtitleCue]) {
        var revisedWords = words
        for (index, revision) in revisions where revisedWords.indices.contains(index) {
            revisedWords[index].correctedText = revision.correctedText
            revisedWords[index].isHiddenInCaptions = revision.isHiddenInCaptions
        }
        guard revisedWords != words else { return (words, cues) }

        var revisedCues = cues
        for (cueIndex, allIndices) in wordIndices(for: cues, words: words).enumerated() {
            let shown = allIndices.filter(isIncluded)
            guard shown.contains(where: { revisions[$0] != nil }),
                  cue(cues[cueIndex], readsAs: shown.map { words[$0] }) else {
                continue
            }
            revisedCues[cueIndex].text = text(of: shown.map { revisedWords[$0] })
        }
        return (revisedWords, revisedCues)
    }
}

/// A full transcription: the word-level timing (drives transcript-based
/// video editing) plus the readable cues derived from it (drive the
/// subtitle bar).
nonisolated struct RecordingTranscript: Sendable {
    var words: [RecordingTranscriptWord]
    var cues: [RecordingSubtitleCue]
}

/// One subtitle on the source (unedited) timeline, in seconds.
nonisolated struct RecordingSubtitleCue: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case text
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Cues saved before editing shipped carry no identity; mint one so
        // the editor's list rows stay stable for this session.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
    }
}

/// User-adjustable subtitle appearance. The bar is always center-locked
/// horizontally; only its height position and text size are editable.
nonisolated struct SubtitleBarStyle: Sendable, Equatable {
    static let verticalRange: ClosedRange<Double> = 0.1...0.95
    static let fontScaleRange: ClosedRange<Double> = 0.6...1.8

    /// Normalized (0...1, top-left origin) center of the bar along the
    /// card's height.
    var verticalPosition: Double = 0.92
    /// Multiplier on the default font size (which the paddings and corner
    /// radius derive from, so the whole bar scales together).
    var fontScale: Double = 1
    /// Karaoke mode: the word being spoken renders in the accent color.
    /// Needs word-level timings; the bar falls back to plain cues without.
    var highlightsSpokenWord: Bool = false

    var clampedVerticalPosition: Double {
        min(max(verticalPosition, Self.verticalRange.lowerBound), Self.verticalRange.upperBound)
    }

    var clampedFontScale: Double {
        min(max(fontScale, Self.fontScaleRange.lowerBound), Self.fontScaleRange.upperBound)
    }
}

// MARK: - Subtitle timing edits

/// Moving and resizing one caption on the timeline. A caption stays between
/// its neighbours and never gets shorter than it can be read in; captions
/// that already overlap (a short cue padded to its minimum) aren't forced
/// apart by an edit to either one. Times are on the source timeline.
nonisolated enum SubtitleCueTiming {
    static let minimumDuration: TimeInterval = 0.3

    enum Edge: Sendable {
        case start
        case end
    }

    /// Where the cue may sit, given its neighbours by start time.
    private static func room(
        for cue: RecordingSubtitleCue,
        in cues: [RecordingSubtitleCue],
        sourceDuration: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        let others = cues.filter { $0.id != cue.id }
        let previousEnd = others.filter { $0.start <= cue.start }.map(\.end).max() ?? 0
        let nextStart = others.filter { $0.start > cue.start }.map(\.start).min() ?? max(sourceDuration, cue.end)
        let lower = min(previousEnd, cue.start)
        return lower...max(lower, max(nextStart, cue.end))
    }

    /// The cue slid to start at `start`, keeping its length.
    static func moving(
        _ cues: [RecordingSubtitleCue],
        id: UUID,
        toStart start: TimeInterval,
        sourceDuration: TimeInterval
    ) -> [RecordingSubtitleCue] {
        guard let index = cues.firstIndex(where: { $0.id == id }), start.isFinite else { return cues }
        var result = cues
        let cue = cues[index]
        let length = cue.end - cue.start
        let room = room(for: cue, in: cues, sourceDuration: sourceDuration)
        let newStart = min(max(start, room.lowerBound), max(room.lowerBound, room.upperBound - length))
        result[index].start = newStart
        result[index].end = newStart + length
        return result
    }

    /// The cue with one edge dragged to `time`.
    static func resizing(
        _ cues: [RecordingSubtitleCue],
        id: UUID,
        edge: Edge,
        to time: TimeInterval,
        sourceDuration: TimeInterval
    ) -> [RecordingSubtitleCue] {
        guard let index = cues.firstIndex(where: { $0.id == id }), time.isFinite else { return cues }
        var result = cues
        let cue = cues[index]
        let room = room(for: cue, in: cues, sourceDuration: sourceDuration)
        switch edge {
        case .start:
            result[index].start = min(max(time, room.lowerBound), cue.end - minimumDuration)
        case .end:
            result[index].end = max(min(time, room.upperBound), cue.start + minimumDuration)
        }
        return result
    }
}

// MARK: - Subtitle timeline

/// Deterministic subtitle playback: the cue covering a source time, if any.
nonisolated struct SubtitleTimeline: Sendable, Equatable {
    private let cues: [RecordingSubtitleCue]

    static let empty = SubtitleTimeline(cues: [])

    init(cues: [RecordingSubtitleCue]) {
        self.cues = cues
            .filter { $0.start.isFinite && $0.end > $0.start && !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
    }

    var isEmpty: Bool {
        cues.isEmpty
    }

    var count: Int {
        cues.count
    }

    func text(at time: TimeInterval) -> String? {
        cue(at: time)?.text
    }

    func cue(at time: TimeInterval) -> RecordingSubtitleCue? {
        guard !cues.isEmpty, time.isFinite else { return nil }

        // Last cue that has already started.
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low - 1
        guard index >= 0 else { return nil }

        let cue = cues[index]
        return time < cue.end ? cue : nil
    }
}

// MARK: - Karaoke word timing

/// Word-level state of the subtitle bar at a moment in time: the active
/// cue's words plus which one is being spoken. Shared verbatim by the
/// SwiftUI preview and the CoreGraphics exporter so highlights match.
nonisolated struct KaraokeTimeline: Sendable {
    struct Line: Equatable {
        /// Display pieces of the active cue in order, each carrying its own
        /// leading spacing, so plain concatenation reads as the caption.
        /// Unspaced scripts (Chinese, Japanese) need no separator at all.
        var words: [String]
        /// Index into `words` currently being spoken; nil between words
        /// and after the cue's last word ends.
        var activeIndex: Int?
        /// How many words have started; spoken words render fully lit
        /// even once the active highlight has moved on.
        var spokenCount: Int
    }

    private struct CueLine {
        var start: TimeInterval
        var end: TimeInterval
        /// Display pieces from the cue's (possibly hand-edited) text.
        var words: [String]
        /// Per-piece timing: exact when the caption still reads as its
        /// words, index-mapped from the timed words after a hand edit so
        /// it keeps working even when word counts drift.
        var timings: [(start: TimeInterval, end: TimeInterval)]
    }

    private let cues: [CueLine]

    static let empty = KaraokeTimeline(cues: [], words: [])

    /// Groups timed words into cues the same way the cues were chunked
    /// from them (a word belongs to the last cue starting at or before
    /// it), but displays the cue's *text* - the editable source of truth -
    /// with timings carried over from the recognizer's words.
    init(cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord]) {
        let sortedCues = cues
            .filter { $0.start.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        let timedByCue = TranscriptCaptionText.wordIndices(for: sortedCues, words: words)
            .map { indices in indices.map { words[$0] } }

        self.cues = zip(sortedCues, timedByCue).compactMap { cue, timed in
            guard !timed.isEmpty else { return nil }
            if let line = Self.exactLine(for: cue, timed: timed) {
                return line
            }
            let displayWords = Self.displayPieces(of: cue.text)
            guard !displayWords.isEmpty else { return nil }
            let timings = displayWords.indices.map { index in
                let timedIndex = min(
                    timed.count - 1,
                    index * timed.count / displayWords.count
                )
                return (start: timed[timedIndex].start, end: timed[timedIndex].end)
            }
            return CueLine(
                start: cue.start,
                end: cue.end,
                words: displayWords,
                timings: timings
            )
        }
    }

    /// A caption that still reads exactly as its words (corrections and
    /// hidden fillers included) highlights word by word with the
    /// recognizer's own timing.
    private static func exactLine(
        for cue: RecordingSubtitleCue,
        timed: [RecordingTranscriptWord]
    ) -> CueLine? {
        let pieces = TranscriptCaptionText.pieces(of: timed)
        guard !pieces.isEmpty, cue.text == pieces.map(\.text).joined() else { return nil }
        let timings = pieces.map { (start: timed[$0.offset].start, end: timed[$0.offset].end) }
        return CueLine(start: cue.start, end: cue.end, words: pieces.map(\.text), timings: timings)
    }

    /// Hand-edited text split into pieces: by whitespace for spaced
    /// scripts, by character for unspaced ones (a whole Chinese sentence
    /// would otherwise light up as a single word).
    private static func displayPieces(of text: String) -> [String] {
        let spaced = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard spaced.count == 1, let only = spaced.first, only.contains(where: \.isUnspacedScript) else {
            return spaced.enumerated().map { $0.offset > 0 ? " " + $0.element : $0.element }
        }
        // Punctuation rides with the character before it.
        var pieces: [String] = []
        for character in only {
            if !pieces.isEmpty, character.isPunctuation {
                pieces[pieces.count - 1].append(character)
            } else {
                pieces.append(String(character))
            }
        }
        return pieces
    }

    var isEmpty: Bool {
        cues.isEmpty
    }

    /// The karaoke line covering a source time; nil when nobody is
    /// speaking or the cue carries no word timings.
    func line(at time: TimeInterval) -> Line? {
        guard !cues.isEmpty, time.isFinite else { return nil }
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low - 1
        guard index >= 0, time < cues[index].end else { return nil }

        let cue = cues[index]
        var activeIndex: Int?
        var spokenCount = 0
        if let lastStarted = cue.timings.lastIndex(where: { $0.start <= time }) {
            spokenCount = lastStarted + 1
            let timing = cue.timings[lastStarted]
            // The highlight rides each word until the next one starts; on
            // the cue's last word a small bridge past its end keeps it from
            // flickering off early, after which the line reads fully spoken.
            if lastStarted < cue.timings.count - 1 || time <= timing.end + 0.25 {
                activeIndex = lastStarted
            }
        }
        return Line(
            words: cue.words,
            activeIndex: activeIndex,
            spokenCount: spokenCount
        )
    }
}

private extension Character {
    /// Punctuation that separates clauses, which a caption must not open
    /// with or repeat. Quotes and brackets are left alone.
    nonisolated var isCaptionSeparator: Bool {
        "，。、；：！？,.;:!?…．".contains(self)
    }

    nonisolated var isSentenceEnd: Bool {
        "。！？.!?…".contains(self)
    }

    /// Written without spaces between words: Han, kana, Hangul.
    nonisolated var isUnspacedScript: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                true
            default:
                false
            }
        }
    }
}

// MARK: - Subtitle bar metrics

/// Geometry shared verbatim by the SwiftUI preview and the CoreGraphics
/// exporter: a rounded black bar with white text, center-locked
/// horizontally at the style's vertical position. Everything derives from
/// the full canvas height - the bar belongs to the composition, background
/// included, not just the recording card - so it is identical at any
/// render resolution and stays put in padded or portrait layouts.
nonisolated struct SubtitleBarMetrics: Sendable {
    let fontSize: CGFloat
    let paddingHorizontal: CGFloat
    let paddingVertical: CGFloat
    let cornerRadius: CGFloat

    static let backgroundAlpha: Double = 0.78

    /// Karaoke palette, shared by preview and export: the spoken word in
    /// warm yellow, words not yet spoken slightly dimmed.
    static let karaokeAccent = CGColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
    static let karaokeUpcomingAlpha: Double = 0.55

    /// Widest the bar may grow, as a fraction of the canvas width; text
    /// that would exceed it wraps into centered lines.
    static let maximumWidthFraction: CGFloat = 0.92
    /// Wrapped lines allowed before the font starts scaling down.
    static let maximumLineCount = 3
    /// Baseline-to-baseline advance as a multiple of ascent + descent,
    /// shared by the preview's lineSpacing and the exporter's layout.
    static let lineSpacingFactor: CGFloat = 1.12

    /// Sized off the canvas's smaller dimension: identical to the old
    /// height-based sizing in landscape, and keeps the bar inside narrow
    /// portrait/square canvases.
    init(canvasSize: CGSize, style: SubtitleBarStyle = SubtitleBarStyle()) {
        let reference = min(canvasSize.width, canvasSize.height)
        fontSize = max(11, reference * 0.032 * style.clampedFontScale)
        paddingHorizontal = fontSize * 0.85
        paddingVertical = fontSize * 0.5
        cornerRadius = fontSize * 0.6
    }

    /// Room available for the text line itself on this canvas.
    func maximumTextWidth(canvasWidth: CGFloat) -> CGFloat {
        max(24, canvasWidth * Self.maximumWidthFraction - paddingHorizontal * 2)
    }
}

// MARK: - Transcription service

nonisolated enum RecordingTranscriptionService {
    enum TranscriptionError: LocalizedError {
        case noNarrationTrack
        case unsupportedLocale
        case narrationUnreadable
        case noSpeechDetected

        var errorDescription: String? {
            switch self {
            case .noNarrationTrack:
                String(localized: "This recording has no microphone audio to transcribe.")
            case .unsupportedLocale:
                String(localized: "On-device transcription isn't available for your language yet.")
            case .narrationUnreadable:
                String(localized: "The narration audio could not be read.")
            case .noSpeechDetected:
                String(localized: "No speech was detected in the narration.")
            }
        }
    }

    /// A subtitle should stay readable at a glance, so speech is chunked
    /// into short cues at natural pauses rather than whole sentences.
    private static let maximumCueCharacters = 42
    private static let maximumCueDuration: TimeInterval = 4
    private static let cueGapThreshold: TimeInterval = 0.9
    private static let minimumCueDuration: TimeInterval = 0.8

    static func transcribe(screenMovieURL: URL) async throws -> RecordingTranscript {
        let narrationURL = try await extractNarrationAudio(from: screenMovieURL)
        defer { try? FileManager.default.removeItem(at: narrationURL) }

        let locale = try await resolveLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: narrationURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Result collection must be consuming before audio is fed in, or the
        // analyzer's early results are dropped on the floor.
        async let collectedWords = collectWords(from: transcriber)
        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let words = try await collectedWords
        let cues = makeCues(from: words)
        guard !cues.isEmpty else { throw TranscriptionError.noSpeechDetected }
        return RecordingTranscript(words: words, cues: cues)
    }

    /// Best transcription locale for the user's language; on-device models
    /// are per-locale, so an unsupported language has to fail loudly rather
    /// than produce gibberish English cues. Also used by the live
    /// teleprompter, which tracks the same narration as it is spoken.
    static func resolveLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let exact = supported.first(where: {
            $0.identifier(.bcp47) == current.identifier(.bcp47)
        }) {
            return exact
        }
        if let sameLanguage = supported.first(where: {
            $0.language.languageCode == current.language.languageCode
        }) {
            return sameLanguage
        }
        if let english = supported.first(where: { $0.language.languageCode?.identifier == "en" }) {
            return english
        }
        throw TranscriptionError.unsupportedLocale
    }

    /// Pulls the narration out of the screen movie into a standalone audio
    /// file. The recorder writes system audio as stereo and the microphone
    /// as mono, so the mono track is the narration whenever both exist.
    /// Track timing is preserved so cue timestamps stay on the movie's
    /// timeline.
    private static func extractNarrationAudio(from movieURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: movieURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard var narrationTrack = audioTracks.last else {
            throw TranscriptionError.noNarrationTrack
        }
        if audioTracks.count > 1 {
            for track in audioTracks {
                let descriptions = try await track.load(.formatDescriptions)
                let channels = descriptions
                    .compactMap { $0.audioStreamBasicDescription?.mChannelsPerFrame }
                    .max() ?? 0
                if channels == 1 {
                    narrationTrack = track
                    break
                }
            }
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TranscriptionError.narrationUnreadable
        }
        let timeRange = try await narrationTrack.load(.timeRange)
        try compositionTrack.insertTimeRange(timeRange, of: narrationTrack, at: timeRange.start)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw TranscriptionError.narrationUnreadable
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("framecho-narration-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try await exportSession.export(to: outputURL, as: .m4a)
        return outputURL
    }

    private static func collectWords(from transcriber: SpeechTranscriber) async throws -> [RecordingTranscriptWord] {
        var words: [RecordingTranscriptWord] = []
        for try await result in transcriber.results where result.isFinal {
            for run in result.text.runs {
                let runText = String(result.text[run.range].characters)
                guard let timeRange = run.audioTimeRange else {
                    // Punctuation and whitespace runs carry no audio range;
                    // glue them onto the previous word so cues keep them.
                    if !words.isEmpty {
                        words[words.count - 1].text += runText
                    }
                    continue
                }
                let start = timeRange.start.seconds
                let end = timeRange.end.seconds
                guard start.isFinite, end.isFinite else { continue }
                words.append(RecordingTranscriptWord(text: runText, start: start, end: max(start, end)))
            }
        }
        return words
    }

    static func makeCues(from words: [RecordingTranscriptWord]) -> [RecordingSubtitleCue] {
        var cues: [RecordingSubtitleCue] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0

        var cueWords: [RecordingTranscriptWord] = []

        func flush() {
            let trimmed = TranscriptCaptionText.text(of: cueWords)
            cueWords = []
            text = ""
            guard !trimmed.isEmpty else { return }
            cues.append(RecordingSubtitleCue(
                start: start,
                end: max(end, start + minimumCueDuration),
                text: trimmed
            ))
        }

        for word in words {
            let wordLength = word.text.trimmingCharacters(in: .whitespaces).count
            if !text.isEmpty {
                let breaksOnLength = text.count + wordLength > maximumCueCharacters
                let breaksOnSilence = word.start - end > cueGapThreshold
                let breaksOnDuration = word.end - start > maximumCueDuration
                if breaksOnLength || breaksOnSilence || breaksOnDuration {
                    flush()
                }
            }
            if text.isEmpty {
                start = word.start
                end = word.end
            }
            // Runs keep the transcript's original spacing, so plain
            // concatenation reconstructs the text exactly.
            text += word.text
            cueWords.append(word)
            end = max(end, word.end)
        }
        flush()
        return cues
    }
}
