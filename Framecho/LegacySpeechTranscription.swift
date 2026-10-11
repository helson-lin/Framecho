//
//  LegacySpeechTranscription.swift
//  Framecho
//
//  Narration transcription before macOS 26, which has no SpeechAnalyzer:
//  SFSpeechRecognizer recognizes the narration on device, a chunk at a time,
//  and its segments become the same timed words SpeechAnalyzer produces, so
//  captions, cutting by words and the agent tools work unchanged. The parts
//  that don't need a recognizer are checked by
//  scripts/check-legacy-transcription.swift.
//

import AVFoundation
import Foundation
import Speech

/// One recognized segment, copied out of `SFTranscriptionSegment` so it can
/// leave the recognizer's queue. `range` is in UTF-16 offsets into the
/// transcription's formatted string; times are seconds into the chunk.
nonisolated struct LegacyRecognizedSegment: Sendable, Equatable {
    var range: Range<Int>
    var timestamp: TimeInterval
    var duration: TimeInterval
}

/// One stretch of speech the recognizer transcribed on its own. After a
/// long pause SFSpeechRecognizer starts transcribing afresh, and its later
/// results no longer include what came before, so each stretch is kept.
/// Only results that close a stretch (they carry
/// `speechRecognitionMetadata`) or end the request have segment times;
/// partial results report zero.
nonisolated struct LegacyRecognizedUtterance: Sendable, Equatable {
    var formattedString: String
    var segments: [LegacyRecognizedSegment]

    var start: TimeInterval? { segments.map(\.timestamp).min() }
    var end: TimeInterval? { segments.map { $0.timestamp + max(0, $0.duration) }.max() }
}

nonisolated enum LegacyTranscriptAssembly {
    /// Folds a completed utterance into those so far. One that starts
    /// before the latest ends repeats or revises it, as the final result can;
    /// one that starts after it is speech after a pause.
    static func merge(_ result: LegacyRecognizedUtterance, into utterances: inout [LegacyRecognizedUtterance]) {
        guard let start = result.start else { return }
        if let last = utterances.last, let lastEnd = last.end, start < lastEnd - 0.05 {
            utterances[utterances.count - 1] = result
        } else {
            utterances.append(result)
        }
    }

    /// A chunk's utterances as one run of words, spaced like the language
    /// they're in.
    static func words(utterances: [LegacyRecognizedUtterance], offset: TimeInterval) -> [RecordingTranscriptWord] {
        let usesSpaces = utterances.contains { $0.formattedString.contains(" ") }
        var words: [RecordingTranscriptWord] = []
        for utterance in utterances {
            var next = Self.words(formattedString: utterance.formattedString, segments: utterance.segments, offset: offset)
            if usesSpaces, !words.isEmpty, let first = next.first, first.text.first?.isWhitespace != true {
                next[0].text = " " + first.text
            }
            words += next
        }
        return words
    }

    /// The segments as words carrying the transcript's own spacing and
    /// punctuation, like SpeechAnalyzer's runs: text between two segments
    /// splits into punctuation, which stays with the word before it, and
    /// whitespace, which leads the word after.
    static func words(
        formattedString: String,
        segments: [LegacyRecognizedSegment],
        offset: TimeInterval
    ) -> [RecordingTranscriptWord] {
        let text = formattedString as NSString
        var words: [RecordingTranscriptWord] = []
        var cursor = 0

        func appendPunctuation(_ gap: String) {
            let punctuation = gap.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !punctuation.isEmpty, !words.isEmpty else { return }
            words[words.count - 1].text += punctuation
        }

        for segment in segments.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard segment.range.lowerBound >= cursor,
                  segment.range.upperBound <= text.length,
                  !segment.range.isEmpty else { continue }
            let gap = text.substring(with: NSRange(location: cursor, length: segment.range.lowerBound - cursor))
            let spaceStart = gap.lastIndex(where: { !$0.isWhitespace }).map { gap.index(after: $0) } ?? gap.startIndex
            appendPunctuation(String(gap[..<spaceStart]))
            let space = words.isEmpty ? "" : String(gap[spaceStart...])

            let start = offset + segment.timestamp
            words.append(RecordingTranscriptWord(
                text: space + text.substring(with: NSRange(segment.range)),
                start: start,
                end: start + max(0, segment.duration)
            ))
            cursor = segment.range.upperBound
        }
        appendPunctuation(text.substring(from: cursor))
        return words
    }

    /// Where to cut audio between words: the middle of the quietest stretch
    /// of `window` samples, as an index into `samples`.
    static func quietestSample(in samples: [Float], window: Int) -> Int {
        let window = max(1, min(window, samples.count))
        guard samples.count > window else { return samples.count / 2 }
        var energy: Float = 0
        for sample in samples[0..<window] { energy += sample * sample }
        var quietest = energy
        var quietestStart = 0
        for start in 1...(samples.count - window) {
            let leaving = samples[start - 1]
            let entering = samples[start + window - 1]
            energy += entering * entering - leaving * leaving
            if energy < quietest {
                quietest = energy
                quietestStart = start
            }
        }
        return quietestStart + window / 2
    }
}

nonisolated enum LegacySpeechTranscription {
    /// SFSpeechRecognizer is steadiest on short requests, so the narration
    /// goes in pieces of at most this long, each cut where it's quietest
    /// within its last `cutSearchSpan` seconds rather than mid-word.
    static let chunkDuration: TimeInterval = 55
    static let cutSearchSpan: TimeInterval = 8
    static let cutWindow: TimeInterval = 0.25

    enum Failure: LocalizedError {
        case noOnDeviceRecognition

        var errorDescription: String? {
            String(localized: "On-device speech recognition isn't available for your language on this Mac. Turning on Dictation for it in System Settings → Keyboard may add it.")
        }
    }

    /// The best language this Mac can recognize on device; recognition never
    /// falls back to Apple's servers.
    static func locale(for current: Locale = .current) throws -> Locale {
        let onDevice = SFSpeechRecognizer.supportedLocales().filter {
            SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
        }
        guard let locale = RecordingTranscriptionService.bestLocale(among: Array(onDevice), for: current) else {
            throw Failure.noOnDeviceRecognition
        }
        return locale
    }

    /// Words on the narration file's timeline, which is the movie's.
    static func transcribe(narrationURL: URL, locale: Locale) async throws -> [RecordingTranscriptWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw Failure.noOnDeviceRecognition
        }
        // Results arrive here rather than on the main queue, the default.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        recognizer.queue = queue

        let file = try AVAudioFile(forReading: narrationURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        let chunkFrames = AVAudioFramePosition(chunkDuration * sampleRate)

        var words: [RecordingTranscriptWord] = []
        var previousUsedSpaces = false
        var start: AVAudioFramePosition = 0
        while start < totalFrames {
            try Task.checkCancellation()
            let capacity = AVAudioFrameCount(min(chunkFrames, totalFrames - start))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw RecordingTranscriptionService.TranscriptionError.narrationUnreadable
            }
            file.framePosition = start
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { break }

            if start + AVAudioFramePosition(buffer.frameLength) < totalFrames {
                buffer.frameLength = cutPoint(in: buffer, sampleRate: sampleRate)
            }

            let utterances = try await recognize(buffer, with: recognizer)
            var chunkWords = LegacyTranscriptAssembly.words(utterances: utterances, offset: Double(start) / sampleRate)
            // Each chunk is recognized on its own, so the space between the
            // last word of one and the first of the next is missing.
            let usesSpaces = utterances.contains { $0.formattedString.contains(" ") }
            if !words.isEmpty, !chunkWords.isEmpty, usesSpaces || previousUsedSpaces {
                chunkWords[0].text = " " + chunkWords[0].text
            }
            previousUsedSpaces = usesSpaces
            words += chunkWords
            start += AVAudioFramePosition(buffer.frameLength)
        }
        return words
    }

    /// The frame to end a chunk at: the quietest moment in its last few
    /// seconds.
    private static func cutPoint(in buffer: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioFrameCount {
        let length = Int(buffer.frameLength)
        guard let channel = buffer.floatChannelData?[0] else { return buffer.frameLength }
        let searchStart = max(0, length - Int(cutSearchSpan * sampleRate))
        let tail = Array(UnsafeBufferPointer(start: channel + searchStart, count: length - searchStart))
        let cut = searchStart + LegacyTranscriptAssembly.quietestSample(in: tail, window: Int(cutWindow * sampleRate))
        return AVAudioFrameCount(max(1, cut))
    }

    /// Recognizes one chunk; empty when it holds no speech.
    private static func recognize(
        _ buffer: AVAudioPCMBuffer,
        with recognizer: SFSpeechRecognizer
    ) async throws -> [LegacyRecognizedUtterance] {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        // The final result holds only the speech since the last long pause;
        // each earlier stretch arrives as a partial result that closes it.
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.append(buffer)
        request.endAudio()

        let pending = PendingRecognition()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                    if let result {
                        // Other partial results are drafts, without times.
                        guard result.speechRecognitionMetadata != nil || result.isFinal else { return }
                        let transcription = result.bestTranscription
                        pending.merge(LegacyRecognizedUtterance(
                            formattedString: transcription.formattedString,
                            segments: transcription.segments.map {
                                LegacyRecognizedSegment(
                                    range: $0.substringRange.location..<($0.substringRange.location + $0.substringRange.length),
                                    timestamp: $0.timestamp,
                                    duration: $0.duration
                                )
                            }
                        ))
                        if result.isFinal {
                            pending.finish { utterances in continuation.resume(returning: utterances) }
                        }
                    } else if let error {
                        pending.finish { utterances in
                            if isNoSpeech(error) {
                                continuation.resume(returning: utterances)
                            } else {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
                pending.track(task)
            }
        } onCancel: {
            pending.cancel()
        }
    }

    /// The recognizer reports a chunk of silence as an error rather than an
    /// empty result.
    private static func isNoSpeech(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }
}

/// Collects a recognition's utterances and resumes its continuation once,
/// whichever of result, error or cancellation comes first; cancels its task
/// on request.
private nonisolated final class PendingRecognition: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var utterances: [LegacyRecognizedUtterance] = []
    private var isFinished = false
    private var isCancelled = false

    func merge(_ result: LegacyRecognizedUtterance) {
        lock.withLock { LegacyTranscriptAssembly.merge(result, into: &utterances) }
    }

    func track(_ task: SFSpeechRecognitionTask) {
        let cancelNow = lock.withLock {
            self.task = task
            return isCancelled
        }
        if cancelNow { task.cancel() }
    }

    func finish(_ resume: ([LegacyRecognizedUtterance]) -> Void) {
        let (first, utterances) = lock.withLock {
            defer { isFinished = true }
            return (!isFinished, self.utterances)
        }
        if first { resume(utterances) }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}
