import Foundation

// Exercises the parts of transcription before macOS 26 that don't need a
// recognizer: turning SFSpeechRecognizer segments into timed words, picking
// quiet cut points, and choosing a language.
@main
struct LegacyTranscriptionChecks {
    static func main() {
        checkEnglishWords()
        checkChineseWords()
        checkTimingAndBadSegments()
        checkUtterancesAfterPauses()
        checkQuietestSample()
        checkLocalePreference()
        print("Legacy transcription checks passed.")
    }

    /// Segments for each word of `text` in order, `0.5` s apart.
    static func segments(_ text: String, _ tokens: [String]) -> [LegacyRecognizedSegment] {
        let string = text as NSString
        var from = 0
        return tokens.enumerated().map { index, token in
            let range = string.range(of: token, range: NSRange(location: from, length: string.length - from))
            precondition(range.location != NSNotFound, "\(token) is in \(text)")
            from = range.location + range.length
            return LegacyRecognizedSegment(
                range: range.location..<(range.location + range.length),
                timestamp: Double(index) * 0.5,
                duration: 0.4
            )
        }
    }

    static func checkEnglishWords() {
        let text = "Hello, world. This is Framecho."
        let words = LegacyTranscriptAssembly.words(
            formattedString: text,
            segments: segments(text, ["Hello", "world", "This", "is", "Framecho"]),
            offset: 0
        )
        // Like SpeechAnalyzer's runs: punctuation trails its word, spaces lead.
        precondition(words.map(\.text) == ["Hello,", " world.", " This", " is", " Framecho."], "\(words.map(\.text))")
        precondition(words.map(\.text).joined() == text, "Concatenated words read as the transcript")
        precondition(TranscriptCaptionText.text(of: words) == text, "Captions read as the transcript")
    }

    static func checkChineseWords() {
        let text = "你好，世界。我们开始吧。"
        let words = LegacyTranscriptAssembly.words(
            formattedString: text,
            segments: segments(text, ["你好", "世界", "我们", "开始", "吧"]),
            offset: 0
        )
        precondition(words.map(\.text) == ["你好，", "世界。", "我们", "开始", "吧。"], "\(words.map(\.text))")
        precondition(TranscriptCaptionText.text(of: words) == text, "Chinese captions get no spaces")
    }

    static func checkTimingAndBadSegments() {
        let text = "one two three"
        var parts = segments(text, ["one", "two", "three"])
        parts[1].duration = -1
        parts.append(LegacyRecognizedSegment(range: 2..<6, timestamp: 9, duration: 1))     // overlaps "one"
        parts.append(LegacyRecognizedSegment(range: 40..<44, timestamp: 9, duration: 1))   // past the end
        parts.append(LegacyRecognizedSegment(range: 13..<13, timestamp: 9, duration: 1))   // empty
        let words = LegacyTranscriptAssembly.words(formattedString: text, segments: parts.shuffled(), offset: 60)

        precondition(words.map(\.text) == ["one", " two", " three"], "Bad segments are skipped: \(words.map(\.text))")
        precondition(words.map(\.start) == [60, 60.5, 61], "Times are offset to the chunk's place: \(words.map(\.start))")
        precondition(words[1].end == words[1].start, "A negative duration is treated as zero")
        precondition(words[2].end == 61.4)

        precondition(LegacyTranscriptAssembly.words(formattedString: "", segments: [], offset: 0).isEmpty)
        precondition(LegacyTranscriptAssembly.words(formattedString: "…", segments: [], offset: 0).isEmpty,
                     "Punctuation with no word to attach to is dropped")
    }

    static func utterance(_ text: String, _ tokens: [String], from start: Double) -> LegacyRecognizedUtterance {
        var parts = segments(text, tokens)
        for index in parts.indices { parts[index].timestamp += start }
        return LegacyRecognizedUtterance(formattedString: text, segments: parts)
    }

    static func checkUtterancesAfterPauses() {
        // After a long pause the recognizer starts over and stops repeating
        // the earlier speech; the final result may repeat the last stretch.
        var utterances: [LegacyRecognizedUtterance] = []
        let results = [
            utterance("大家好，今天", ["大家好", "今天"], from: 0),
            utterance("大家好，今天开始", ["大家好", "今天", "开始"], from: 0.1),  // a revision
            utterance("视频会自动打开。", ["视频", "会", "自动", "打开"], from: 23.5),
            utterance("视频会自动打开。", ["视频", "会", "自动", "打开"], from: 23.5),  // final repeats it
        ]
        for result in results { LegacyTranscriptAssembly.merge(result, into: &utterances) }
        LegacyTranscriptAssembly.merge(LegacyRecognizedUtterance(formattedString: "", segments: []), into: &utterances)
        precondition(utterances.map(\.formattedString) == ["大家好，今天开始", "视频会自动打开。"],
                     "Revisions replace, speech after a pause is kept: \(utterances.map(\.formattedString))")

        let chinese = LegacyTranscriptAssembly.words(utterances: utterances, offset: 0)
        precondition(TranscriptCaptionText.text(of: chinese) == "大家好，今天开始视频会自动打开。", "Chinese utterances join without a space")
        precondition(chinese.first?.start == 0.1 && chinese.last?.start == 25,
                     "Utterances keep their own times: \(chinese.map(\.start))")

        var english: [LegacyRecognizedUtterance] = []
        LegacyTranscriptAssembly.merge(utterance("Hello there.", ["Hello", "there"], from: 0), into: &english)
        LegacyTranscriptAssembly.merge(utterance("Next", ["Next"], from: 5), into: &english)
        let englishWords = LegacyTranscriptAssembly.words(utterances: english, offset: 0)
        precondition(TranscriptCaptionText.text(of: englishWords) == "Hello there. Next", "English utterances join with a space")
    }

    static func checkQuietestSample() {
        // Loud speech with a silent gap from 600 to 700.
        var samples = (0..<1000).map { Float(sin(Double($0) * 0.3)) * 0.8 }
        for index in 600..<700 { samples[index] = 0 }
        let cut = LegacyTranscriptAssembly.quietestSample(in: samples, window: 50)
        precondition((600..<700).contains(cut), "Cuts inside the silence, not at \(cut)")

        precondition(LegacyTranscriptAssembly.quietestSample(in: [0.5, 0.5], window: 10) == 1,
                     "Fewer samples than the window cut in the middle")
        precondition(LegacyTranscriptAssembly.quietestSample(in: [], window: 10) == 0)
    }

    static func checkLocalePreference() {
        let supported = ["en-US", "zh-CN", "zh-TW", "ja-JP"].map(Locale.init(identifier:))
        func best(_ current: String) -> String? {
            RecordingTranscriptionService.bestLocale(among: supported, for: Locale(identifier: current))?.identifier
        }
        precondition(best("zh-TW") == "zh-TW", "The exact language and region first")
        precondition(best("zh-SG") == "zh-CN", "Then the same language elsewhere")
        precondition(best("fr-FR") == "en-US", "Then English")
        precondition(RecordingTranscriptionService.bestLocale(among: [], for: .current) == nil)
    }
}
