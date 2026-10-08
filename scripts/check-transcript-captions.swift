import Foundation

// Exercises caption revisions (corrections and hidden fillers) and the
// karaoke pieces built from them, without transcribing anything.
@main
struct TranscriptCaptionChecks {
    static func main() {
        func word(_ text: String, _ start: Double) -> RecordingTranscriptWord {
            RecordingTranscriptWord(text: text, start: start, end: start + 0.4)
        }

        // Projects saved before revisions shipped decode unchanged, and
        // unrevised words encode without the new keys.
        let legacy = Data(#"[{"text":"Hello ","start":0,"end":0.4}]"#.utf8)
        let decoded = try! JSONDecoder().decode([RecordingTranscriptWord].self, from: legacy)
        precondition(decoded == [word("Hello ", 0)])
        precondition(!decoded[0].hasCaptionRevision)
        let encoded = String(decoding: try! JSONEncoder().encode(decoded), as: UTF8.self)
        precondition(!encoded.contains("correctedText") && !encoded.contains("isHiddenInCaptions"))
        var revisedWord = word("Framecho", 0)
        revisedWord.isHiddenInCaptions = true
        revisedWord.correctedText = "x"
        let roundTrip = try! JSONDecoder().decode(
            RecordingTranscriptWord.self,
            from: JSONEncoder().encode(revisedWord)
        )
        precondition(roundTrip == revisedWord)

        // Corrections keep the recognizer's spacing; hidden words vanish.
        var corrected = word(" frame echo,", 0)
        corrected.correctedText = "Framecho,"
        precondition(corrected.captionText == " Framecho,")
        var hidden = word("um ", 0)
        hidden.isHiddenInCaptions = true
        precondition(hidden.captionText.isEmpty)

        // English: hide a filler and correct a misheard name.
        let words = [
            word("So ", 0), word("um ", 0.5), word("frame ", 1), word("echo ", 1.5),
            word("records.", 2), word("Next ", 5), word("line.", 5.5),
        ]
        let cues = [
            RecordingSubtitleCue(start: 0, end: 2.4, text: "So um frame echo records."),
            RecordingSubtitleCue(start: 5, end: 5.9, text: "Next line."),
        ]
        let revisions: [Int: TranscriptWordRevision] = [
            1: TranscriptWordRevision(correctedText: nil, isHiddenInCaptions: true),
            2: TranscriptWordRevision(correctedText: "Framecho", isHiddenInCaptions: false),
            3: TranscriptWordRevision(correctedText: "", isHiddenInCaptions: false),
        ]
        let revised = TranscriptCaptionText.applying(revisions, to: words, cues: cues)
        precondition(revised.cues[0].text == "So Framecho records.", revised.cues[0].text)
        precondition(revised.cues[1] == cues[1], "Untouched captions stay as they were")
        precondition(revised.words.map(\.text) == words.map(\.text), "Recognizer text is never rewritten")

        // Karaoke highlights the revised caption with the words' own timing.
        let karaoke = KaraokeTimeline(cues: revised.cues, words: revised.words)
        let line = karaoke.line(at: 2.1)!
        precondition(line.words == ["So", " Framecho", " records."], "\(line.words)")
        precondition(line.words.joined() == revised.cues[0].text)
        precondition(line.activeIndex == 2)
        precondition(karaoke.line(at: 1.1)!.activeIndex == 1, "A span's replacement lights up on its first word")

        // A caption edited by hand keeps what the user typed.
        var handEdited = cues
        handEdited[0].text = "Typed by hand."
        let kept = TranscriptCaptionText.applying(revisions, to: words, cues: handEdited)
        precondition(kept.cues[0].text == "Typed by hand.")
        precondition(kept.words == revised.words)

        // Restoring clears the revisions and the caption reads as heard.
        let restored = TranscriptCaptionText.applying(
            [1: .original, 2: .original, 3: .original],
            to: revised.words,
            cues: revised.cues
        )
        precondition(restored.words == words)
        precondition(restored.cues[0].text == cues[0].text)

        // Chinese: recognizer words carry no spaces, and karaoke must not
        // treat the whole sentence as one word or insert spaces.
        let chinese = [word("嗯", 0), word("这个", 0.5), word("工具", 1), word("很好用。", 1.5)]
        let chineseCue = [RecordingSubtitleCue(start: 0, end: 2, text: "嗯这个工具很好用。")]
        let chineseLine = KaraokeTimeline(cues: chineseCue, words: chinese).line(at: 1.1)!
        precondition(chineseLine.words == ["嗯", "这个", "工具", "很好用。"], "\(chineseLine.words)")
        precondition(chineseLine.activeIndex == 2)
        let cleaned = TranscriptCaptionText.applying(
            [0: TranscriptWordRevision(correctedText: nil, isHiddenInCaptions: true)],
            to: chinese,
            cues: chineseCue
        )
        precondition(cleaned.cues[0].text == "这个工具很好用。")
        precondition(KaraokeTimeline(cues: cleaned.cues, words: cleaned.words).line(at: 0.1)?.activeIndex == nil,
                     "A hidden filler never lights up")

        // A hand-edited Chinese caption falls back to per-character pieces.
        let typed = [RecordingSubtitleCue(start: 0, end: 2, text: "这工具好用。")]
        let typedLine = KaraokeTimeline(cues: typed, words: chinese).line(at: 1.9)!
        precondition(typedLine.words == ["这", "工", "具", "好", "用。"], "\(typedLine.words)")
        precondition(typedLine.words.joined() == typed[0].text)

        // Hidden fillers that empty a caption drop it from playback.
        let onlyFiller = TranscriptCaptionText.applying(
            [0: TranscriptWordRevision(correctedText: nil, isHiddenInCaptions: true)],
            to: [word("嗯", 0)],
            cues: [RecordingSubtitleCue(start: 0, end: 1, text: "嗯")]
        )
        precondition(SubtitleTimeline(cues: onlyFiller.cues).text(at: 0.5) == nil)

        // Hiding a filler never leaves its neighbor's punctuation dangling:
        // no caption opens on a separator, separators never stack, and the
        // stronger one survives.
        func hiding(_ texts: [String], _ hidden: Set<Int>) -> String {
            var timed = texts.enumerated().map { word($0.element, Double($0.offset)) }
            for index in hidden { timed[index].isHiddenInCaptions = true }
            return TranscriptCaptionText.text(of: timed)
        }
        precondition(hiding(["嗯", "，包括", "一些"], [0]) == "包括一些")
        precondition(hiding(["然后，", "包括"], [0]) == "包括")
        precondition(hiding(["问题", "，嗯", "，然后"], [1]) == "问题，然后")
        precondition(hiding(["好，", "嗯", "，然后"], [1]) == "好，然后")
        precondition(hiding(["好，", "那个", "。"], [1]) == "好。")
        precondition(hiding(["Well, ", "um, ", "so ", "yes."], [1]) == "Well, so yes.")
        precondition(hiding(["Um, ", "so ", "yes."], [0]) == "so yes.")
        precondition(hiding(["“好”", "嗯"], [1]) == "“好”", "Quotes are not separators")

        // Karaoke pieces follow the tidy text exactly.
        let dangling = [word("嗯", 0), word("，包括", 0.5), word("一些。", 1)]
        var tidyWords = dangling
        tidyWords[0].isHiddenInCaptions = true
        let tidyCue = [RecordingSubtitleCue(start: 0, end: 1.5, text: TranscriptCaptionText.text(of: tidyWords))]
        let tidyLine = KaraokeTimeline(cues: tidyCue, words: tidyWords).line(at: 1.1)!
        precondition(tidyLine.words == ["包括", "一些。"], "\(tidyLine.words)")
        precondition(tidyLine.activeIndex == 1)

        // Captions saved before tidying still count as derived (not typed)
        // and pick up the tidy text; typed captions are left alone.
        let saved = RecordingSubtitleCue(start: 0, end: 1.5, text: "，包括一些。")
        precondition(TranscriptCaptionText.cue(saved, readsAs: tidyWords))
        precondition(TranscriptCaptionText.tidied([saved], words: tidyWords)[0].text == "包括一些。")
        let typedCue = RecordingSubtitleCue(start: 0, end: 1.5, text: "，我自己写的")
        precondition(TranscriptCaptionText.tidied([typedCue], words: tidyWords)[0].text == "，我自己写的")

        // Words whose audio was cut don't count against a derived caption.
        let cutCue = RecordingSubtitleCue(start: 0, end: 1.5, text: "嗯，包括")
        precondition(!TranscriptCaptionText.cue(cutCue, readsAs: dangling))
        precondition(TranscriptCaptionText.cue(cutCue, readsAs: Array(dangling.prefix(2))))
        precondition(TranscriptCaptionText.tidied([cutCue], words: dangling, isIncluded: { $0 < 2 })[0].text == "嗯，包括")
        let afterCut = TranscriptCaptionText.applying(
            [0: TranscriptWordRevision(correctedText: nil, isHiddenInCaptions: true)],
            to: dangling,
            cues: [RecordingSubtitleCue(start: 0, end: 1.5, text: "嗯，包括")],
            isIncluded: { $0 < 2 }
        )
        precondition(afterCut.cues[0].text == "包括", afterCut.cues[0].text)

        // Fresh transcriptions are tidy from the start.
        let fresh = RecordingTranscriptionService.makeCues(from: [word("，开始", 0), word("吧。", 0.5)])
        precondition(fresh.map(\.text) == ["开始吧。"], "\(fresh)")

        // Timing edits: moves keep a caption's length and stop at its
        // neighbours; trims keep it readable.
        let timed = [
            RecordingSubtitleCue(start: 0, end: 2, text: "a"),
            RecordingSubtitleCue(start: 3, end: 5, text: "b"),
            RecordingSubtitleCue(start: 8, end: 9, text: "c"),
        ]
        let b = timed[1].id
        func cue(_ cues: [RecordingSubtitleCue]) -> RecordingSubtitleCue { cues.first { $0.id == b }! }
        precondition(cue(SubtitleCueTiming.moving(timed, id: b, toStart: 4, sourceDuration: 10)).start == 4)
        precondition(cue(SubtitleCueTiming.moving(timed, id: b, toStart: 4, sourceDuration: 10)).end == 6)
        precondition(cue(SubtitleCueTiming.moving(timed, id: b, toStart: 7.5, sourceDuration: 10)).end == 8, "Stops at the next caption")
        precondition(cue(SubtitleCueTiming.moving(timed, id: b, toStart: 0, sourceDuration: 10)).start == 2, "Stops at the previous caption")
        precondition(cue(SubtitleCueTiming.resizing(timed, id: b, edge: .end, to: 20, sourceDuration: 10)).end == 8)
        precondition(cue(SubtitleCueTiming.resizing(timed, id: b, edge: .end, to: 3.1, sourceDuration: 10)).end == 3 + SubtitleCueTiming.minimumDuration)
        precondition(cue(SubtitleCueTiming.resizing(timed, id: b, edge: .start, to: 1, sourceDuration: 10)).start == 2)
        let last = timed[2].id
        precondition(SubtitleCueTiming.resizing(timed, id: last, edge: .end, to: 30, sourceDuration: 10).first { $0.id == last }!.end == 10)
        // Captions that already overlap aren't pushed apart by an edit.
        let overlapping = [RecordingSubtitleCue(start: 0, end: 3.5, text: "x"), RecordingSubtitleCue(start: 3, end: 4, text: "y")]
        let y = overlapping[1].id
        precondition(cue2(SubtitleCueTiming.resizing(overlapping, id: y, edge: .end, to: 5, sourceDuration: 10), y).start == 3)
        func cue2(_ cues: [RecordingSubtitleCue], _ id: UUID) -> RecordingSubtitleCue { cues.first { $0.id == id }! }

        // A deleted caption's words don't fall into the caption before it,
        // and a trimmed caption keeps only the words inside it.
        let spoken = [word("one ", 0), word("two ", 0.5), word("three ", 3), word("four", 3.5)]
        let pair = [
            RecordingSubtitleCue(start: 0, end: 1, text: "one two"),
            RecordingSubtitleCue(start: 3, end: 4, text: "three four"),
        ]
        precondition(TranscriptCaptionText.wordIndices(for: pair, words: spoken) == [[0, 1], [2, 3]])
        precondition(TranscriptCaptionText.wordIndices(for: [pair[0]], words: spoken) == [[0, 1]], "Deleted caption's words stay out")
        var trimmed = pair[0]
        trimmed.end = 0.4
        precondition(TranscriptCaptionText.wordIndices(for: [trimmed], words: spoken) == [[0]])
        let karaokeAfterDelete = KaraokeTimeline(cues: [pair[0]], words: spoken)
        precondition(karaokeAfterDelete.line(at: 0.6)?.words == ["one", " two"])
        precondition(karaokeAfterDelete.line(at: 3.2) == nil)

        print("Transcript caption checks passed.")
    }
}
