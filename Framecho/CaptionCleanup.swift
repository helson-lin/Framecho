//
//  CaptionCleanup.swift
//  Framecho
//
//  Planning for AI caption cleanup. Fillers: which transcript words to hide
//  from the captions - rules catch pure hesitation sounds on their own, a
//  language model judges the words that are fillers only in context ("那个"
//  as a pause vs. "that"). Corrections: misheard words the model rewrites,
//  kept to small, local fixes. Everything here is pure so the checks can
//  exercise it; the model call itself lives in CaptionCleanupEngine.
//

import Foundation

/// One word the cleanup suggests hiding from the captions. The user reviews
/// suggestions before any are applied.
nonisolated struct CaptionFillerSuggestion: Sendable, Equatable, Identifiable {
    enum Source: Sendable, Equatable {
        /// A pure hesitation sound, found without AI.
        case rule
        /// Judged a filler in context by the language model.
        case model
    }

    var wordIndex: Int
    var source: Source
    var isAccepted = true

    var id: Int { wordIndex }
}

/// A misheard run of words the cleanup suggests rewriting in the captions.
/// The replacement lands on the first word and the rest go blank, so the
/// span keeps its timing.
nonisolated struct CaptionCorrectionSuggestion: Sendable, Equatable, Identifiable {
    var firstWordIndex: Int
    var lastWordIndex: Int
    var replacement: String
    var isAccepted = true

    var id: Int { firstWordIndex }

    var wordIndices: ClosedRange<Int> { firstWordIndex...lastWordIndex }
}

/// A run of words sent to the model in one request, on whole-caption
/// boundaries so the model sees complete phrases.
nonisolated struct CaptionCleanupChunk: Sendable, Equatable {
    /// Indices into the transcript words the model may flag.
    var wordIndices: [Int]
}

nonisolated enum CaptionCleanupPlanner {
    /// Hesitation sounds that are fillers wherever they appear.
    private static let certainFillers: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "uhmm",
        "er", "erm", "hmm", "hm", "hmmm", "mhm", "mmm",
        "嗯", "嗯嗯", "呃", "呃呃", "额", "额额", "唔", "呣", "嗯哼",
    ]

    /// Words that are fillers only in some contexts; only the model may
    /// flag them, and the model may flag nothing else.
    private static let contextualFillers: Set<String> = [
        "like", "so", "well", "actually", "basically", "literally", "right", "okay", "ok",
        "youknow", "imean", "kindof", "sortof",
        "啊", "哦", "噢", "呀", "吧", "嘛", "哈",
        "那个", "这个", "就是", "就是说", "然后", "然后呢", "其实", "反正", "对吧", "对", "的话",
        "那么", "所以说", "怎么说", "怎么说呢", "这样子", "那样子",
    ]

    /// Longest word (in characters, punctuation excluded) the model may
    /// flag even outside the lexicons, to allow stutters like "我我".
    private static let maximumStutterLength = 3

    /// The model is told to be conservative; a chunk where it flags more
    /// than this share of the words is treated as a misfire and dropped.
    static let maximumModelFillerShare = 0.25

    static func normalized(_ word: RecordingTranscriptWord) -> String {
        word.displayText
            .lowercased()
            .filter { $0.isLetter }
    }

    static func isCertainFiller(_ word: RecordingTranscriptWord) -> Bool {
        certainFillers.contains(normalized(word))
    }

    /// Words worth asking about: hidden or cut words are already gone.
    static func candidateIndices(
        in words: [RecordingTranscriptWord],
        isAvailable: (Int) -> Bool
    ) -> [Int] {
        words.indices.filter { !words[$0].isHiddenInCaptions && isAvailable($0) }
    }

    /// Words in captions the user retyped; cleanup leaves those alone, as
    /// revising their words could never show anyway.
    static func wordsInHandEditedCaptions(
        words: [RecordingTranscriptWord],
        cues: [RecordingSubtitleCue],
        isIncluded: (Int) -> Bool = { _ in true }
    ) -> Set<Int> {
        var result = Set<Int>()
        for (cue, indices) in zip(cues, TranscriptCaptionText.wordIndices(for: cues, words: words))
        where !TranscriptCaptionText.cue(cue, readsAs: indices.filter(isIncluded).map { words[$0] }) {
            result.formUnion(indices)
        }
        return result
    }

    static func ruleSuggestions(
        in words: [RecordingTranscriptWord],
        candidates: [Int]
    ) -> [CaptionFillerSuggestion] {
        candidates
            .filter { isCertainFiller(words[$0]) }
            .map { CaptionFillerSuggestion(wordIndex: $0, source: .rule) }
    }

    /// Splits candidate words into requests of at most `maximumWords`,
    /// breaking only between captions unless one caption alone is longer.
    static func chunks(
        candidates: [Int],
        words: [RecordingTranscriptWord],
        cues: [RecordingSubtitleCue],
        maximumWords: Int
    ) -> [CaptionCleanupChunk] {
        let candidateSet = Set(candidates)
        var groups = TranscriptCaptionText.wordIndices(for: cues, words: words)
            .enumerated()
            .sorted { cues[$0.offset].start < cues[$1.offset].start }
            .map { $0.element.filter(candidateSet.contains) }
            .filter { !$0.isEmpty }
        // Words outside every caption still deserve a look.
        let grouped = Set(groups.joined())
        let loose = candidates.filter { !grouped.contains($0) }
        if !loose.isEmpty { groups.append(loose) }

        var chunks: [CaptionCleanupChunk] = []
        var current: [Int] = []
        for group in groups {
            if !current.isEmpty, current.count + group.count > maximumWords {
                chunks.append(CaptionCleanupChunk(wordIndices: current))
                current = []
            }
            for start in stride(from: 0, to: group.count, by: maximumWords) {
                let slice = group[start..<min(group.count, start + maximumWords)]
                if slice.count == maximumWords {
                    chunks.append(CaptionCleanupChunk(wordIndices: Array(slice)))
                } else {
                    current.append(contentsOf: slice)
                }
            }
        }
        if !current.isEmpty { chunks.append(CaptionCleanupChunk(wordIndices: current)) }
        return chunks
    }

    // MARK: - Prompt

    static let fillerInstructions = """
    You clean up subtitles of spoken narration from a screen recording. \
    You receive the transcript as numbered words, one per line as "number<TAB>word". \
    Find filler words: hesitation sounds and verbal tics that carry no meaning \
    in context and can be dropped from the subtitle without changing what was said. \
    Examples: 嗯, 呃, 那个 or 这个 used as a pause, 就是 or 然后 used as a habit, \
    stuttered repeats like 我我, um, uh, like or you know used as a pause. \
    Keep words that carry meaning: 那个 meaning "that", 就是 meaning "is exactly", \
    然后 that really joins two steps, like meaning "similar to". \
    Never flag names, numbers, technical terms or content words. When unsure, keep the word. \
    Reply with JSON only, in the form {"fillers": [numbers]}, using the numbers from the input.
    """

    /// Words as the captions currently read them, numbered by transcript
    /// index so replies can point back at them.
    static func prompt(for chunk: CaptionCleanupChunk, words: [RecordingTranscriptWord]) -> String {
        chunk.wordIndices
            .map { "\($0)\t\(words[$0].captionText.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
    }

    // MARK: - Response

    /// Word numbers from a model reply. Tolerates code fences and prose
    /// around the JSON; nil when no `fillers` array can be found.
    static func parseFillerResponse(_ response: String) -> [Int]? {
        for value in jsonValues(in: response) {
            if let values = list(in: value, key: "fillers"),
               values.allSatisfy({ integer($0) != nil }) {
                return values.compactMap(integer)
            }
        }
        return nil
    }

    /// The model's picks that are safe to suggest: numbers it was actually
    /// asked about, short filler-shaped words only, and nothing at all when
    /// it flagged so much of the chunk that it clearly misread the task.
    static func validatedModelFillers(
        _ indices: [Int],
        chunk: CaptionCleanupChunk,
        words: [RecordingTranscriptWord]
    ) -> [Int] {
        let asked = Set(chunk.wordIndices)
        let picked = Set(indices).filter { index in
            guard asked.contains(index) else { return false }
            let word = words[index]
            let normalized = normalized(word)
            guard !normalized.isEmpty,
                  !word.displayText.contains(where: \.isNumber) else {
                return false
            }
            return certainFillers.contains(normalized)
                || contextualFillers.contains(normalized)
                || isStutter(at: index, in: words, normalized: normalized)
        }
        // Short chunks may always flag a few words; one filler in a short
        // caption is already a big share.
        let allowed = max(3, Int((Double(chunk.wordIndices.count) * maximumModelFillerShare).rounded(.up)))
        guard picked.count <= allowed else { return [] }
        return picked.sorted()
    }

    /// A short word immediately repeated, like "我 我" or "the the".
    private static func isStutter(at index: Int, in words: [RecordingTranscriptWord], normalized: String) -> Bool {
        guard normalized.count <= maximumStutterLength, index + 1 < words.count else { return false }
        return Self.normalized(words[index + 1]).hasPrefix(normalized)
    }

    /// Rule and model suggestions merged, one per word, in transcript order.
    static func merged(
        rules: [CaptionFillerSuggestion],
        modelIndices: [Int]
    ) -> [CaptionFillerSuggestion] {
        var byWord = Dictionary(uniqueKeysWithValues: rules.map { ($0.wordIndex, $0) })
        for index in modelIndices where byWord[index] == nil {
            byWord[index] = CaptionFillerSuggestion(wordIndex: index, source: .model)
        }
        return byWord.values.sorted { $0.wordIndex < $1.wordIndex }
    }

    /// Accepted suggestions as caption revisions: hide the word, keep any
    /// correction it already had for when it is shown again.
    static func revisions(
        for suggestions: [CaptionFillerSuggestion],
        words: [RecordingTranscriptWord]
    ) -> [Int: TranscriptWordRevision] {
        var revisions: [Int: TranscriptWordRevision] = [:]
        for suggestion in suggestions where suggestion.isAccepted && words.indices.contains(suggestion.wordIndex) {
            revisions[suggestion.wordIndex] = TranscriptWordRevision(
                correctedText: words[suggestion.wordIndex].correctedText,
                isHiddenInCaptions: true
            )
        }
        return revisions
    }

    // MARK: - Corrections

    /// Most words one fix may rewrite; anything longer is a rewrite, not
    /// a correction.
    static let maximumCorrectionSpan = 4
    /// Share of a chunk's words the model may touch before the whole
    /// chunk counts as a misfire (rewriting instead of correcting).
    static let maximumCorrectionShare = 0.35

    static let correctionInstructions = """
    You proofread subtitles produced by speech recognition of narration in a screen recording. \
    You receive the transcript as numbered words, one per line as "number<TAB>word". \
    Fix only clear recognition errors: wrong homophones or near-homophones (同音错别字), \
    misheard product names, brand names and technical terms (for example 佛兰切 → Framecho, \
    斯威夫特 UI → SwiftUI, iphone → iPhone), wrong capitalization of names, and clearly missing \
    or wrong punctuation. Do not rephrase, polish, translate, shorten or reorder anything, \
    and do not change words that are merely informal. Keep the speaker's language. \
    Each fix replaces a run of consecutive words, from number "first" to number "last" (at most 4 words), \
    with "text": the corrected text for that run, including its punctuation. \
    Reply with JSON only, in the form {"fixes": [{"first": 12, "last": 13, "text": "SwiftUI"}]}. \
    Reply {"fixes": []} when nothing needs fixing.
    """

    /// Fixes from a model reply; nil when no `fixes` array can be found.
    /// Malformed entries are skipped rather than failing the chunk.
    static func parseCorrectionResponse(_ response: String) -> [CaptionCorrectionSuggestion]? {
        guard let values = jsonValues(in: response).lazy.compactMap({ list(in: $0, key: "fixes") }).first(where: {
            $0.allSatisfy { $0 is [String: Any] }
        }) else {
            return nil
        }
        return values.compactMap { value in
            guard let fix = value as? [String: Any],
                  let first = integer(fix["first"]),
                  let text = fix["text"] as? String else {
                return nil
            }
            let last = integer(fix["last"]) ?? first
            return CaptionCorrectionSuggestion(firstWordIndex: first, lastWordIndex: last, replacement: text)
        }
    }

    /// The model's fixes that are safe to suggest: spans it was asked
    /// about, short, really different, and close enough to what was heard
    /// to be a correction rather than a rewrite. Overlapping fixes keep the
    /// first; a chunk where the model touched too much is dropped whole.
    static func validatedCorrections(
        _ fixes: [CaptionCorrectionSuggestion],
        chunk: CaptionCleanupChunk,
        words: [RecordingTranscriptWord]
    ) -> [CaptionCorrectionSuggestion] {
        let asked = Set(chunk.wordIndices)
        var claimed = Set<Int>()
        var accepted: [CaptionCorrectionSuggestion] = []
        for fix in fixes.sorted(by: { $0.firstWordIndex < $1.firstWordIndex }) {
            guard fix.firstWordIndex <= fix.lastWordIndex,
                  fix.wordIndices.count <= maximumCorrectionSpan,
                  fix.wordIndices.allSatisfy({ asked.contains($0) && !claimed.contains($0) }) else {
                continue
            }
            var cleaned = fix
            cleaned.replacement = fix.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let original = TranscriptCaptionText.text(of: fix.wordIndices.map { words[$0] })
            guard !cleaned.replacement.isEmpty,
                  isPlausibleCorrection(of: original, to: cleaned.replacement, span: fix.wordIndices.count) else {
                continue
            }
            claimed.formUnion(fix.wordIndices)
            accepted.append(cleaned)
        }
        let touched = accepted.reduce(0) { $0 + $1.wordIndices.count }
        let allowed = max(4, Int((Double(chunk.wordIndices.count) * maximumCorrectionShare).rounded(.up)))
        return touched <= allowed ? accepted : []
    }

    /// A correction changes something beyond spacing and stays close to
    /// the original. Within one script that means a bounded edit distance;
    /// a switch of script (佛兰切 → Framecho) can't be measured that way, so
    /// it is held to a short span and a short replacement instead.
    static func isPlausibleCorrection(of original: String, to replacement: String, span: Int) -> Bool {
        let before = Array(original.filter { !$0.isWhitespace })
        let after = Array(replacement.filter { !$0.isWhitespace })
        guard !after.isEmpty, before != after else { return false }

        let beforeUnspaced = before.contains(where: \.isUnspacedScriptCharacter)
        let afterUnspaced = after.contains(where: \.isUnspacedScriptCharacter)
        if beforeUnspaced != afterUnspaced {
            return span <= 3 && after.count <= 24
        }

        let longest = max(before.count, after.count)
        guard after.count <= before.count * 2 + 2 else { return false }
        let distance = editDistance(before.map { $0.lowercased() }, after.map { $0.lowercased() })
        return distance <= max(2, Int((Double(longest) * 0.6).rounded(.down)))
    }

    static func revisions(
        for corrections: [CaptionCorrectionSuggestion],
        words: [RecordingTranscriptWord]
    ) -> [Int: TranscriptWordRevision] {
        var revisions: [Int: TranscriptWordRevision] = [:]
        for correction in corrections where correction.isAccepted {
            guard correction.wordIndices.allSatisfy(words.indices.contains) else { continue }
            for index in correction.wordIndices {
                revisions[index] = TranscriptWordRevision(
                    correctedText: index == correction.firstWordIndex ? correction.replacement : "",
                    isHiddenInCaptions: words[index].isHiddenInCaptions
                )
            }
        }
        return revisions
    }

    // MARK: - Helpers

    /// Every JSON object or array in a reply, in order. Models wrap their
    /// answer in code fences, prose or a reasoning block (`<think>…</think>`)
    /// that may itself contain braces, so each balanced bracket run is
    /// tried on its own rather than trusting the first `{` and last `}`.
    static func jsonValues(in response: String) -> [Any] {
        var text = response
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }

        let characters = Array(text)
        var values: [Any] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "{" || characters[index] == "[",
                  let end = matchingBracket(in: characters, from: index),
                  let data = String(characters[index...end]).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) else {
                index += 1
                continue
            }
            values.append(value)
            index = end + 1
        }
        return values
    }

    /// Index of the bracket closing the one at `start`, skipping brackets
    /// inside JSON strings; nil when it never closes (a truncated reply).
    private static func matchingBracket(in characters: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// The answer list in a reply value: under `key`, under the only array
    /// an object holds (models rename keys), or the value itself when the
    /// model replied with a bare array.
    private static func list(in value: Any, key: String) -> [Any]? {
        if let array = value as? [Any] { return array }
        guard let object = value as? [String: Any] else { return nil }
        if let array = object[key] as? [Any] { return array }
        let arrays = object.values.compactMap { $0 as? [Any] }
        return arrays.count == 1 ? arrays[0] : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

private extension Character {
    /// Written without spaces between words: Han, kana, Hangul.
    nonisolated var isUnspacedScriptCharacter: Bool {
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
