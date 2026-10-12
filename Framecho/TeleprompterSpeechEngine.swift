//
//  TeleprompterSpeechEngine.swift
//  Framecho
//
//  Live narration tracking for the teleprompter: microphone sample buffers
//  are teed off the recording's SCStream (no second capture session), fed
//  into an on-device recognizer that reports words as they are spoken, and
//  every update is matched against the script. Progress only ever moves
//  forward - a revised guess must never scroll the prompter backwards while
//  someone is mid-sentence.
//
//  macOS 26 recognizes with SpeechAnalyzer; earlier versions with
//  SFSpeechRecognizer, which needs the Speech Recognition permission.
//
//  The engine is best-effort by design: if the model asset is missing, the
//  locale unsupported, or the recognizer dies, the teleprompter simply stops
//  auto-advancing. It never interferes with the recording itself.
//

@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import Speech

nonisolated final class TeleprompterSpeechEngine: @unchecked Sendable {
    private let matcher: TeleprompterScriptMatcher
    /// Called with the (monotonic) count of script display words spoken.
    private let onProgress: @Sendable (Int) -> Void

    private let lock = NSLock()
    private var recognizer: (any TeleprompterRecognizer)?
    private var isPaused = false
    private var isFinished = false
    private var reported = 0

    init(matcher: TeleprompterScriptMatcher, onProgress: @escaping @Sendable (Int) -> Void) {
        self.matcher = matcher
        self.onProgress = onProgress
    }

    /// Resolves the locale + on-device model before a recording needs it, so
    /// enabling the teleprompter (not pressing Record) pays the download.
    /// Before macOS 26 the system manages the models; there is nothing to
    /// fetch.
    static func preflightAssets() async {
        if #available(macOS 26.0, *) {
            await SpeechAnalyzerTeleprompterRecognizer.preflightAssets()
        }
    }

    func start() async throws {
        let locale = try await RecordingTranscriptionService.resolveLocale()
        let onSpoken: @Sendable ([String]) -> Void = { [weak self] spoken in self?.report(spoken) }
        let recognizer: any TeleprompterRecognizer
        if #available(macOS 26.0, *) {
            recognizer = try await SpeechAnalyzerTeleprompterRecognizer(locale: locale, onSpoken: onSpoken)
        } else {
            recognizer = try LegacyTeleprompterRecognizer(locale: locale, onSpoken: onSpoken)
        }
        let alreadyFinished: Bool = lock.withLock {
            guard !isFinished else { return true }
            self.recognizer = recognizer
            return false
        }
        if alreadyFinished {
            // The recording ended while the model was still downloading.
            recognizer.finish()
            return
        }
        try await recognizer.start()
    }

    /// Called on the recording's audio sample queue for every microphone
    /// buffer. Must stay cheap: convert, hand over, return.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        ingest(buffer)
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        let recognizer: (any TeleprompterRecognizer)? = lock.withLock {
            guard !isPaused, !isFinished else { return nil }
            return self.recognizer
        }
        recognizer?.append(buffer)
    }

    func setPaused(_ paused: Bool) {
        lock.withLock { isPaused = paused }
    }

    /// Tears the session down without waiting for trailing results - the
    /// overlay is collapsing anyway.
    func finish() {
        let recognizer: (any TeleprompterRecognizer)? = lock.withLock {
            isFinished = true
            defer { self.recognizer = nil }
            return self.recognizer
        }
        recognizer?.finish()
    }

    /// Matching reruns over everything spoken so far, so revised guesses
    /// converge instead of compounding.
    private func report(_ spoken: [String]) {
        let count = matcher.spokenDisplayWordCount(spoken: spoken)
        let advanced: Bool = lock.withLock {
            guard count > reported, !isFinished else { return false }
            reported = count
            return true
        }
        if advanced { onProgress(count) }
    }

    // MARK: - Audio plumbing

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

// MARK: - Recognizers

/// Turns microphone audio into the words spoken so far. `onSpoken` gets the
/// whole list each time: settled words plus the current guess at the rest.
private nonisolated protocol TeleprompterRecognizer: Sendable {
    func start() async throws
    /// On the recording's audio sample queue; must stay cheap.
    func append(_ buffer: AVAudioPCMBuffer)
    func finish()
}

/// Converts microphone buffers to the format a recognizer wants, reusing the
/// converter while the input format stays the same.
private nonisolated final class TeleprompterAudioConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            return buffer
        }

        let converter: AVAudioConverter? = lock.withLock {
            if let existing = self.converter,
               existing.inputFormat == buffer.format,
               existing.outputFormat == format {
                return existing
            }
            let fresh = AVAudioConverter(from: buffer.format, to: format)
            self.converter = fresh
            return fresh
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        nonisolated(unsafe) let inputBuffer = buffer
        nonisolated(unsafe) var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// macOS 26: SpeechAnalyzer with volatile results enabled.
@available(macOS 26.0, *)
private nonisolated final class SpeechAnalyzerTeleprompterRecognizer: TeleprompterRecognizer, @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let onSpoken: @Sendable ([String]) -> Void
    private let audio = TeleprompterAudioConverter()

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var inputSequence: AsyncStream<AnalyzerInput>?
    private var analysisTask: Task<Void, Never>?

    static func preflightAssets() async {
        guard let locale = try? await RecordingTranscriptionService.resolveLocale() else { return }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let installation = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await installation.downloadAndInstall()
        }
    }

    init(locale: Locale, onSpoken: @escaping @Sendable ([String]) -> Void) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CocoaError(.featureUnsupported)
        }
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.format = format
        self.onSpoken = onSpoken
        self.continuation = continuation
        self.inputSequence = inputSequence
    }

    func start() async throws {
        let inputSequence: AsyncStream<AnalyzerInput>? = lock.withLock {
            defer { self.inputSequence = nil }
            return self.inputSequence
        }
        guard let inputSequence else { return }
        let task = Task { [transcriber, onSpoken] in
            // Finalized segments accumulate; the volatile tail is replaced on
            // every update.
            var finalizedWords: [String] = []
            do {
                for try await result in transcriber.results {
                    let words = TeleprompterScriptText.normalizedWords(String(result.text.characters))
                    if result.isFinal {
                        finalizedWords.append(contentsOf: words)
                        onSpoken(finalizedWords)
                    } else {
                        onSpoken(finalizedWords + words)
                    }
                }
            } catch {
                // Recognition died; the prompter stays put and the recording
                // is unaffected.
            }
        }
        lock.withLock { analysisTask = task }
        try await analyzer.start(inputSequence: inputSequence)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = lock.withLock({ self.continuation }),
              let converted = audio.convert(buffer, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() {
        let (continuation, task) = lock.withLock {
            defer {
                self.continuation = nil
                self.analysisTask = nil
            }
            return (self.continuation, self.analysisTask)
        }
        continuation?.finish()
        Task { [analyzer] in
            await analyzer.cancelAndFinishNow()
            task?.cancel()
        }
    }
}

/// Before macOS 26: SFSpeechRecognizer with partial results. After a long
/// pause it starts transcribing afresh and stops repeating what came
/// before; the result that closes each stretch carries
/// `speechRecognitionMetadata`, so those words are kept as settled.
private nonisolated final class LegacyTeleprompterRecognizer: TeleprompterRecognizer, @unchecked Sendable {
    /// Restarting after this many consecutive failures stops trying: the
    /// recognizer isn't going to work this session.
    private static let maximumRestarts = 5

    private let recognizer: SFSpeechRecognizer
    private let onSpoken: @Sendable ([String]) -> Void
    private let audio = TeleprompterAudioConverter()

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var settledWords: [String] = []
    private var failedRestarts = 0
    private var isFinished = false

    init(locale: Locale, onSpoken: @escaping @Sendable ([String]) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw LegacySpeechTranscription.Failure.noOnDeviceRecognition
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        recognizer.queue = queue
        self.recognizer = recognizer
        self.onSpoken = onSpoken
    }

    func start() async throws {
        beginRequest()
    }

    private func beginRequest() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result, error)
        }
        let cancelled: Bool = lock.withLock {
            guard !isFinished else { return true }
            self.request = request
            self.task = task
            return false
        }
        if cancelled { task.cancel() }
    }

    private func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
        if let result {
            let words = TeleprompterScriptText.normalizedWords(result.bestTranscription.formattedString)
            let isSettled = result.speechRecognitionMetadata != nil || result.isFinal
            let spoken: [String] = lock.withLock {
                if !words.isEmpty { failedRestarts = 0 }
                if isSettled {
                    settledWords += words
                    return settledWords
                }
                return settledWords + words
            }
            onSpoken(spoken)
            // A final result with nothing in it counts against restarting,
            // so a recognizer that ends at once can't spin.
            if result.isFinal { restartUnlessFinished(afterFailure: words.isEmpty) }
        } else if error != nil {
            restartUnlessFinished(afterFailure: true)
        }
    }

    /// A recognition task can end on its own, after a long silence for
    /// instance; the prompter keeps listening with a fresh one.
    private func restartUnlessFinished(afterFailure: Bool) {
        let shouldRestart: Bool = lock.withLock {
            guard !isFinished else { return false }
            if afterFailure { failedRestarts += 1 }
            request = nil
            task = nil
            return failedRestarts <= Self.maximumRestarts
        }
        if shouldRestart { beginRequest() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let request = lock.withLock({ self.request }),
              let converted = audio.convert(buffer, to: request.nativeAudioFormat) else { return }
        request.append(converted)
    }

    func finish() {
        let (request, task): (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) = lock.withLock {
            isFinished = true
            defer {
                self.request = nil
                self.task = nil
            }
            return (self.request, self.task)
        }
        request?.endAudio()
        task?.cancel()
    }
}
