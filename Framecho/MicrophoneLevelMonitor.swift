//
//  MicrophoneLevelMonitor.swift
//  Framecho
//
//  The microphone's live input level, for the recording bar. Without it the
//  icon only says a microphone is *selected* - not that it's delivering
//  sound - and a muted or dead input is only discovered after the recording
//  is made.
//
//  It has two feeds. While the pre-record picker is up it opens the selected
//  device itself, writing nothing, and closes it as soon as the picker leaves
//  - before ScreenCaptureKit takes the microphone for the recording. During
//  the recording it's fed from the stream's own microphone buffers instead,
//  so the device is never opened twice.
//

import AVFoundation
@preconcurrency import CoreMedia
import Observation

@Observable
@MainActor
final class MicrophoneLevelMonitor {
    static let shared = MicrophoneLevelMonitor()

    enum Status: Equatable {
        case idle
        /// Listening, and no audio has arrived yet.
        case starting
        case live
        /// Audio is arriving, but as digital silence - the input is muted
        /// at the device or in the system. A quiet room never reads as this:
        /// it still carries a noise floor.
        case silent
        /// The device couldn't be opened, or opened and stopped sending audio.
        case unavailable
    }

    fileprivate enum Feed {
        /// The picker's own capture session.
        case preview
        /// The running recording's microphone buffers.
        case recording
    }

    private enum Source: Equatable {
        case preview(deviceID: String)
        case recording
    }

    private(set) var status: Status = .idle
    /// 0...1 for display, already smoothed.
    private(set) var level: Double = 0
    @ObservationIgnored private var source: Source?

    @ObservationIgnored private let engine = MicrophoneLevelEngine { power in
        Task { @MainActor in MicrophoneLevelMonitor.shared.receive(power: power, from: .preview) }
    }
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var silentSince: ContinuousClock.Instant?
    @ObservationIgnored private var lastSignal: ContinuousClock.Instant?

    /// How long input has to stay at digital zero before it's called muted.
    /// Some devices open with a few hundred milliseconds of zeros.
    private static let silenceGrace = Duration.seconds(2)
    /// How long a running feed may go without delivering a buffer.
    private static let signalTimeout = Duration.seconds(2)

    private init() {}

    /// The picker's feed: starts listening to `deviceID`, switches to it, or
    /// stops with nil. Ignored while a recording is metering - the picker
    /// stepping aside for the recording must not end the recording's feed.
    func monitor(deviceID: String?) {
        guard source != .recording else { return }
        let newSource = deviceID.map { Source.preview(deviceID: $0) }
        guard newSource != source else { return }
        stop()
        source = newSource
        guard let deviceID else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = RecordingDeviceCatalog.microphone(withID: deviceID) else {
            status = .unavailable
            return
        }

        beginListening()
        Task {
            let started = await engine.start(device: device)
            guard source == newSource else { return }
            if !started { status = .unavailable }
        }
    }

    /// Switches to the recording's feed. Call once its buffers are flowing,
    /// so the time it takes to start the stream isn't read as a dead input.
    func beginRecording() {
        stop()
        source = .recording
        beginListening()
    }

    func endRecording() {
        guard source == .recording else { return }
        stop()
    }

    private func beginListening() {
        status = .starting
        let start = ContinuousClock.now
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let reference = self.lastSignal ?? start
                if ContinuousClock.now - reference > Self.signalTimeout {
                    self.status = .unavailable
                    self.level = 0
                }
            }
        }
    }

    private func stop() {
        if case .preview = source {
            Task { await engine.stop() }
        }
        source = nil
        watchdog?.cancel()
        watchdog = nil
        silentSince = nil
        lastSignal = nil
        status = .idle
        level = 0
    }

    /// A buffer still in flight from a feed that was just stopped is dropped
    /// here; one from the previous device during a switch only stands in for
    /// the new one for a moment.
    fileprivate func receive(power: Float, from feed: Feed) {
        switch (feed, source) {
        case (.preview, .preview?), (.recording, .recording?):
            break
        default:
            return
        }
        let now = ContinuousClock.now
        lastSignal = now

        if power <= MicrophoneLevelMeter.digitalSilence {
            let since = silentSince ?? now
            silentSince = since
            level = 0
            if now - since >= Self.silenceGrace {
                status = .silent
            } else if status != .silent {
                status = .live
            }
            return
        }

        silentSince = nil
        status = .live
        level = MicrophoneLevelMeter.smoothed(
            previous: level,
            target: MicrophoneLevelMeter.level(forPower: power)
        )
    }
}

/// Meters the recording's microphone buffers on the stream's audio queue.
/// One per recording; ScreenCaptureKit delivers a stream's buffers on a
/// serial queue, so its state is never touched concurrently.
nonisolated final class MicrophoneLevelTap: @unchecked Sendable {
    private var lastDelivery: UInt64 = 0

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastDelivery >= MicrophoneLevelMeter.deliveryInterval else { return }
        guard let power = MicrophoneLevelMeter.power(of: sampleBuffer) else { return }
        lastDelivery = now
        Task { @MainActor in
            MicrophoneLevelMonitor.shared.receive(power: power, from: .recording)
        }
    }
}

/// The meter's ballistics, kept apart from the capture plumbing.
nonisolated enum MicrophoneLevelMeter {
    /// Below this the input is exact zeros rather than a quiet room.
    static let digitalSilence: Float = -100
    /// The floor of the visible range. A typical room sits around -60 dB, so
    /// it reads as empty; ordinary speech lands around the middle.
    static let floor: Float = -50

    /// ~20 updates a second: smooth to the eye, cheap on the main actor.
    static let deliveryInterval: UInt64 = 50_000_000

    static func level(forPower decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        let clamped = min(max(decibels, floor), 0)
        return Double((clamped - floor) / -floor)
    }

    /// Rises immediately and falls back gently, like a VU meter - a meter
    /// that drops as fast as it rises flickers on every syllable.
    static func smoothed(previous: Double, target: Double) -> Double {
        target >= previous ? target : max(target, previous - 0.08)
    }

    /// RMS power in dB of a linear PCM buffer, across all its channels -
    /// the same measure `AVCaptureAudioChannel.averagePowerLevel` reports.
    static func power(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM else { return nil }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = format.mBitsPerChannel

        var sumOfSquares: Double = 0
        var count = 0
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    let bytes = Int(buffer.mDataByteSize)
                    switch (isFloat, bits) {
                    case (true, 32):
                        let samples = data.bindMemory(to: Float.self, capacity: bytes / 4)
                        for index in 0..<(bytes / 4) {
                            let value = Double(samples[index])
                            sumOfSquares += value * value
                        }
                        count += bytes / 4
                    case (false, 16):
                        let samples = data.bindMemory(to: Int16.self, capacity: bytes / 2)
                        for index in 0..<(bytes / 2) {
                            let value = Double(samples[index]) / Double(Int16.max)
                            sumOfSquares += value * value
                        }
                        count += bytes / 2
                    case (false, 32):
                        let samples = data.bindMemory(to: Int32.self, capacity: bytes / 4)
                        for index in 0..<(bytes / 4) {
                            let value = Double(samples[index]) / Double(Int32.max)
                            sumOfSquares += value * value
                        }
                        count += bytes / 4
                    default:
                        continue
                    }
                }
            }
        } catch {
            return nil
        }
        guard count > 0 else { return nil }
        let rms = (sumOfSquares / Double(count)).squareRoot()
        return rms > 0 ? Float(20 * log10(rms)) : -.infinity
    }
}

// MARK: - Capture engine

nonisolated private final class MicrophoneLevelEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.jarinhe.framecho.microphone-level.session", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.jarinhe.framecho.microphone-level.audio", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureAudioDataOutput?
    /// Only touched on the audio queue.
    private var lastDelivery: UInt64 = 0
    /// Peak channel power in dB, at most ~20 times a second.
    private let onPower: @Sendable (Float) -> Void

    init(onPower: @escaping @Sendable (Float) -> Void) {
        self.onPower = onPower
    }

    func start(device: AVCaptureDevice) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { [self] in
                teardown()
                do {
                    try configure(device: device)
                    session.startRunning()
                    continuation.resume(returning: session.isRunning)
                } catch {
                    teardown()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                teardown()
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastDelivery >= MicrophoneLevelMeter.deliveryInterval else { return }
        lastDelivery = now
        let power = connection.audioChannels.map(\.averagePowerLevel).max() ?? -.infinity
        onPower(power)
    }

    private func configure(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        self.input = input

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
        session.addOutput(output)
        self.output = output
    }

    private func teardown() {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        if let input {
            session.removeInput(input)
        }
        if let output {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        session.commitConfiguration()
        input = nil
        output = nil
    }
}
