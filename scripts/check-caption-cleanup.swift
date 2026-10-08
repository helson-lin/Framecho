import Foundation

// Exercises caption filler planning - rules, chunking, parsing the model's
// reply and guarding against its mistakes - without calling any model.
@main
struct CaptionCleanupChecks {
    static func main() {
        func words(_ texts: [String]) -> [RecordingTranscriptWord] {
            texts.enumerated().map {
                RecordingTranscriptWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5)
            }
        }

        // Rules catch pure hesitation sounds only; contextual words wait for the model.
        let chinese = words(["嗯，", "那个", "这个", "工具", "呃", "很好用。"])
        let all = Array(chinese.indices)
        let rules = CaptionCleanupPlanner.ruleSuggestions(in: chinese, candidates: all)
        precondition(rules.map(\.wordIndex) == [0, 4], "\(rules)")
        precondition(rules.allSatisfy { $0.source == .rule && $0.isAccepted })

        // Hidden and cut words are never suggested again.
        var hidden = chinese
        hidden[0].isHiddenInCaptions = true
        precondition(CaptionCleanupPlanner.candidateIndices(in: hidden) { $0 != 4 } == [1, 2, 3, 5])

        // Replies are read through code fences and prose.
        precondition(CaptionCleanupPlanner.parseFillerResponse(#"{"fillers": [1, 2]}"#) == [1, 2])
        precondition(CaptionCleanupPlanner.parseFillerResponse("```json\n{\"fillers\":[\"3\"]}\n```") == [3])
        precondition(CaptionCleanupPlanner.parseFillerResponse(#"{"fillers": []}"#) == [])
        precondition(CaptionCleanupPlanner.parseFillerResponse("I think 1 and 2") == nil)
        // Reasoning blocks, braces in prose, bare arrays and renamed keys.
        precondition(CaptionCleanupPlanner.parseFillerResponse(
            "<think>The set {0, 1} looks like {fillers}...</think>\n{\"fillers\": [0]}"
        ) == [0])
        precondition(CaptionCleanupPlanner.parseFillerResponse(
            "Here you go: {\"note\": \"a } in a string\", \"fillers\": [2, 4]} Hope this helps {:"
        ) == [2, 4])
        precondition(CaptionCleanupPlanner.parseFillerResponse("[1, 3]") == [1, 3])
        precondition(CaptionCleanupPlanner.parseFillerResponse(#"{"filler_indices": [5]}"#) == [5])
        precondition(CaptionCleanupPlanner.parseFillerResponse(#"{"fillers": [1, 2"#) == nil, "Truncated replies fail")
        precondition(CaptionCleanupPlanner.parseCorrectionResponse(#"[{"first": 1, "text": "A"}]"#)?.count == 1)
        precondition(CaptionCleanupPlanner.parseCorrectionResponse(#"{"fixes": [1, 2]}"#) == nil)

        // The model may flag contextual fillers and stutters, never content,
        // numbers or words it wasn't asked about.
        let english = words([
            "So ", "like ", "I ", "I ", "think ", "the ", "app ", "is ", "great. ",
            "Version ", "2 ", "ships ", "today ", "you ", "know.",
        ])
        let chunk = CaptionCleanupChunk(wordIndices: Array(english.indices))
        precondition(
            CaptionCleanupPlanner.validatedModelFillers([1, 2, 6, 10, 99], chunk: chunk, words: english) == [1, 2],
            "Content words, numbers and unknown indices are dropped"
        )
        let narrow = CaptionCleanupChunk(wordIndices: [0, 1])
        precondition(CaptionCleanupPlanner.validatedModelFillers([1, 2], chunk: narrow, words: english) == [1])

        // A model that flags a big share of the chunk misread the task.
        let fillerHeavy = words(Array(repeating: "那个", count: 16))
        let misfire = CaptionCleanupPlanner.validatedModelFillers(
            Array(0..<5),
            chunk: CaptionCleanupChunk(wordIndices: Array(fillerHeavy.indices)),
            words: fillerHeavy
        )
        precondition(misfire.isEmpty, "\(misfire)")

        // Merging keeps one suggestion per word, rules winning.
        let merged = CaptionCleanupPlanner.merged(rules: rules, modelIndices: [1, 4])
        precondition(merged.map(\.wordIndex) == [0, 1, 4])
        precondition(merged.map(\.source) == [.rule, .model, .rule])

        // Only accepted suggestions become revisions, keeping corrections.
        var reviewed = merged
        reviewed[1].isAccepted = false
        var corrected = chinese
        corrected[4].correctedText = "额"
        let revisions = CaptionCleanupPlanner.revisions(for: reviewed, words: corrected)
        precondition(Set(revisions.keys) == [0, 4])
        precondition(revisions[4] == TranscriptWordRevision(correctedText: "额", isHiddenInCaptions: true))

        // End to end: the captions lose exactly the accepted fillers.
        let cue = RecordingSubtitleCue(start: 0, end: 6, text: "嗯，那个这个工具呃很好用。")
        let applied = TranscriptCaptionText.applying(
            CaptionCleanupPlanner.revisions(for: CaptionCleanupPlanner.merged(rules: rules, modelIndices: [1]), words: chinese),
            to: chinese,
            cues: [cue]
        )
        precondition(applied.cues[0].text == "这个工具很好用。", applied.cues[0].text)

        // Chunks break between captions and never exceed the limit.
        let long = words((0..<10).map { "w\($0) " })
        let cues = [
            RecordingSubtitleCue(start: 0, end: 3, text: "a"),
            RecordingSubtitleCue(start: 3, end: 7, text: "b"),
            RecordingSubtitleCue(start: 7, end: 10, text: "c"),
        ]
        let chunks = CaptionCleanupPlanner.chunks(candidates: Array(long.indices), words: long, cues: cues, maximumWords: 7)
        precondition(chunks.map(\.wordIndices) == [[0, 1, 2, 3, 4, 5, 6], [7, 8, 9]], "\(chunks)")
        let tiny = CaptionCleanupPlanner.chunks(candidates: Array(long.indices), words: long, cues: cues, maximumWords: 3)
        precondition(tiny.allSatisfy { $0.wordIndices.count <= 3 })
        precondition(tiny.flatMap(\.wordIndices) == Array(long.indices), "Every word is asked about exactly once")
        let skipping = CaptionCleanupPlanner.chunks(candidates: [1, 8], words: long, cues: cues, maximumWords: 7)
        precondition(skipping.map(\.wordIndices) == [[1, 8]])

        // The prompt numbers words by their transcript index.
        precondition(CaptionCleanupPlanner.prompt(for: narrow, words: english) == "0\tSo\n1\tlike")

        // Corrections: replies parse leniently, single-word fixes default
        // their last index, malformed entries are skipped.
        let parsed = CaptionCleanupPlanner.parseCorrectionResponse(
            #"{"fixes": [{"first": 1, "last": "2", "text": "Framecho"}, {"first": 4, "text": "SwiftUI"}, {"text": "x"}]}"#
        )!
        precondition(parsed.map(\.wordIndices) == [1...2, 4...4])
        precondition(CaptionCleanupPlanner.parseCorrectionResponse("no json") == nil)

        let heard = words(["我们", "用", "佛兰", "切", "录屏，", "再用", "斯威夫特", "写界面。", "大家", "好"])
        let heardChunk = CaptionCleanupChunk(wordIndices: Array(heard.indices))
        func fix(_ first: Int, _ last: Int, _ text: String) -> CaptionCorrectionSuggestion {
            CaptionCorrectionSuggestion(firstWordIndex: first, lastWordIndex: last, replacement: text)
        }
        let checked = CaptionCleanupPlanner.validatedCorrections([
            fix(2, 3, " Framecho "),           // script switch on a short span: allowed
            fix(3, 3, "X"),                    // overlaps the fix above
            fix(6, 6, "SwiftUI"),              // misheard term
            fix(0, 0, "我们"),                 // no change
            fix(8, 9, "各位观众朋友们晚上好"),  // rewrite, not a correction
            fix(9, 12, "好"),                  // runs past the chunk
            fix(5, 4, "x"),                    // inverted span
        ], chunk: heardChunk, words: heard)
        precondition(checked.map(\.wordIndices) == [2...3, 6...6], "\(checked)")
        precondition(checked[0].replacement == "Framecho", "Replacements are trimmed")

        // Same-script fixes stay within a bounded edit distance.
        precondition(CaptionCleanupPlanner.isPlausibleCorrection(of: "在线", to: "再现", span: 1))
        precondition(CaptionCleanupPlanner.isPlausibleCorrection(of: "iphone", to: "iPhone", span: 1))
        precondition(CaptionCleanupPlanner.isPlausibleCorrection(of: "好用", to: "好用。", span: 1))
        precondition(!CaptionCleanupPlanner.isPlausibleCorrection(of: "the app", to: "this wonderful program", span: 2))
        precondition(!CaptionCleanupPlanner.isPlausibleCorrection(of: "a b", to: "ab", span: 2), "Spacing alone isn't a fix")

        // A model rewriting most of a chunk gets nothing through.
        let rewrite = CaptionCleanupPlanner.validatedCorrections(
            stride(from: 0, to: 10, by: 1).map { fix($0, $0, heard[$0].displayText + "了") },
            chunk: heardChunk,
            words: heard
        )
        precondition(rewrite.isEmpty, "\(rewrite)")

        // Applying: the fix lands on the first word, the rest go blank, and
        // the caption, karaoke and restore all follow.
        var reviewedFixes = checked
        reviewedFixes[1].isAccepted = false
        let fixRevisions = CaptionCleanupPlanner.revisions(for: reviewedFixes, words: heard)
        precondition(fixRevisions == [
            2: TranscriptWordRevision(correctedText: "Framecho", isHiddenInCaptions: false),
            3: TranscriptWordRevision(correctedText: "", isHiddenInCaptions: false),
        ])
        let heardCue = RecordingSubtitleCue(start: 0, end: 10, text: TranscriptCaptionText.text(of: heard))
        let fixed = TranscriptCaptionText.applying(fixRevisions, to: heard, cues: [heardCue])
        precondition(fixed.cues[0].text == "我们用Framecho录屏，再用斯威夫特写界面。大家好", fixed.cues[0].text)
        precondition(fixed.words.map(\.text) == heard.map(\.text))

        // Retyped captions are off limits.
        var retyped = heardCue
        retyped.text = "我自己改过"
        precondition(CaptionCleanupPlanner.wordsInHandEditedCaptions(words: heard, cues: [retyped]) == Set(heard.indices))
        precondition(CaptionCleanupPlanner.wordsInHandEditedCaptions(words: heard, cues: [heardCue]).isEmpty)

        print("Caption cleanup checks passed.")
    }
}
