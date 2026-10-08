import AVFoundation
import Foundation

@main
nonisolated struct AudioNormalizationChecks {
    nonisolated static func tone(amplitude: Float, seconds: Double, frequency: Double = 1_000) -> [Float] {
        (0..<Int(seconds * 48_000)).flatMap { frame in
            let sample = amplitude * Float(sin(2 * .pi * frequency * Double(frame) / 48_000))
            return [sample, sample]
        }
    }

    nonisolated static func measure(_ samples: [Float], chunkSize: Int = 2_048) -> RecordingAudioNormalization.Measurement {
        var meter = RecordingAudioNormalization.Meter()
        samples.withUnsafeBufferPointer { buffer in
            for start in stride(from: 0, to: buffer.count, by: chunkSize) {
                meter.consume(UnsafeBufferPointer(rebasing: buffer[start..<min(start + chunkSize, buffer.count)]))
            }
        }
        return meter.measurement
    }

    nonisolated static func close(_ a: Double, _ b: Double, tolerance: Double = 0.1) {
        precondition(abs(a - b) < tolerance, "Expected \(b), got \(a)")
    }

    static func writeFixture(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<2 { buffer.floatChannelData![channel][frame] = samples[frame * 2 + channel] }
        }
        try file.write(from: buffer)
    }

    static func processedMeasurement(
        asset: AVAsset, normalization: RecordingAudioNormalization.Measurement
    ) async throws -> RecordingAudioNormalization.Measurement {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000,
        ])
        output.audioMix = RecordingAudioGain.makeMix(tracks: tracks, volume: 1, normalization: normalization)
        reader.add(output)
        precondition(reader.startReading())
        var result = RecordingAudioNormalization.Meter()
        while let sample = output.copyNextSampleBuffer() {
            let block = CMSampleBufferGetDataBuffer(sample)!
            let size = CMBlockBufferGetDataLength(block)
            var pcm = [Float](repeating: 0, count: size / 4)
            let status = pcm.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            precondition(status == noErr)
            pcm.withUnsafeBufferPointer { result.consume($0) }
        }
        precondition(reader.status == .completed)
        return result.measurement
    }

    @MainActor static func main() async throws {
        try await run()
    }

    @concurrent static func run() async throws {
        let samples = tone(amplitude: 0.1, seconds: 2)
        let quiet = measure(samples)
        // BS.1770 calibration: a stereo 1 kHz sine with -20 dBFS sample
        // peaks measures approximately -20 LUFS (mono is 3 LU lower).
        close(quiet.integratedLUFS!, -20)
        close(quiet.samplePeak, 0.1, tolerance: 0.00001)
        close(measure(samples, chunkSize: 960).integratedLUFS!, quiet.integratedLUFS!, tolerance: 0.000001)

        let loud = measure(tone(amplitude: 0.4, seconds: 2))
        close(loud.integratedLUFS! - quiet.integratedLUFS!, 20 * log10(4))
        let quieter = measure(tone(amplitude: 0.02, seconds: 2))
        precondition(quieter.gain(volume: 1) > 2, "Normalization must bypass the manual 200% gain cap")
        for input in [quieter, quiet, loud] {
            close(input.integratedLUFS! + 20 * log10(input.gain(volume: 1)), -16, tolerance: 0.00001)
            precondition(input.samplePeak * input.gain(volume: 2) <= RecordingAudioNormalization.peakCeiling + 0.00001)
            precondition(input.gain(volume: 0) == 0)
        }
        close(quiet.gain(volume: 0.5), quiet.gain(volume: 1) / 2, tolerance: 0.00001)
        let impulse = RecordingAudioNormalization.Measurement(integratedLUFS: -35, samplePeak: 0.95)
        close(impulse.gain(volume: 1) * 0.95, RecordingAudioNormalization.peakCeiling, tolerance: 0.00001)
        let barelyAudible = RecordingAudioNormalization.Measurement(integratedLUFS: -60, samplePeak: 0.001)
        precondition(barelyAudible.gain(volume: 1) == 10)

        let silent = measure([Float](repeating: 0, count: 48_000 * 2))
        precondition(silent.integratedLUFS == nil && silent.gain(volume: 1) == 1)
        precondition(measure([]).integratedLUFS == nil)
        precondition(measure([.nan, .infinity, -.infinity, .nan]).integratedLUFS == nil)
        let short = measure(tone(amplitude: 0.1, seconds: 0.1))
        precondition(short.integratedLUFS?.isFinite == true && short.gain(volume: 1).isFinite)

        let padded = [Float](repeating: 0, count: 48_000 * 2) + samples
            + [Float](repeating: 0, count: 48_000 * 2)
        // Partly silent boundary blocks remain above the relative gate.
        // Reference result from FFmpeg ebur128 for this padded fixture.
        close(measure(padded).integratedLUFS!, -20.60, tolerance: 0.1)
        let noisyTail = samples + tone(amplitude: 0.001, seconds: 4)
        close(measure(noisyTail).integratedLUFS!, quiet.integratedLUFS!, tolerance: 0.4)

        // Exercise decoding, timeline ranges, simultaneous tracks, and the
        // processing tap that applies gains greater than 200% at export.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.wav")
        let fixture = tone(amplitude: 0.02, seconds: 2)
        try writeFixture(fixture, to: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        let decoded = try await RecordingAudioNormalization.measure(asset: asset, timeRange: range)!
        close(decoded.integratedLUFS!, quieter.integratedLUFS!, tolerance: 0.01)
        let trimmed = try await RecordingAudioNormalization.measure(
            asset: asset,
            timeRange: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                  duration: CMTime(seconds: 1, preferredTimescale: 600))
        )!
        close(trimmed.integratedLUFS!, decoded.integratedLUFS!, tolerance: 0.01)

        let composition = AVMutableComposition()
        for _ in 0..<2 {
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try track.insertTimeRange(range, of: tracks[0], at: .zero)
        }
        let ids = composition.tracks(withMediaType: .audio).map(\.trackID)
        let compositionSnapshot = composition.copy() as! AVAsset
        let mixed = try await RecordingAudioNormalization.measure(asset: compositionSnapshot, timeRange: range)!
        close(mixed.integratedLUFS! - decoded.integratedLUFS!, 20 * log10(2), tolerance: 0.01)
        close(mixed.samplePeak, decoded.samplePeak * 2, tolerance: 0.0001)
        let excluded = try await RecordingAudioNormalization.measure(
            asset: compositionSnapshot, excludingTrackIDs: [ids[0]], timeRange: range
        )!
        close(excluded.integratedLUFS!, decoded.integratedLUFS!, tolerance: 0.01)
        close(try await processedMeasurement(asset: asset, normalization: decoded).integratedLUFS!, -16)

        // Cancellation between loud tracks must happen before clipping.
        // Each track exceeds unity with this gain, but their sum does not.
        let cancelling = AVMutableComposition()
        for (index, amplitude) in [Float(0.8), -0.78].enumerated() {
            let partURL = directory.appendingPathComponent("part-\(index).wav")
            try writeFixture(tone(amplitude: amplitude, seconds: 2), to: partURL)
            let sourceAsset = AVURLAsset(url: partURL)
            let source = try await sourceAsset.loadTracks(withMediaType: .audio)[0]
            let track = cancelling.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try withExtendedLifetime(sourceAsset) {
                try track.insertTimeRange(range, of: source, at: .zero)
            }
        }
        let cancellingSnapshot = cancelling.copy() as! AVAsset
        let cancellingLevel = try await RecordingAudioNormalization.measure(asset: cancellingSnapshot, timeRange: range)!
        close(try await processedMeasurement(asset: cancellingSnapshot, normalization: cancellingLevel).integratedLUFS!, -16)

        let cancelled = Task {
            try Task.checkCancellation()
            return try await RecordingAudioNormalization.measure(asset: asset, timeRange: range)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("A cancelled analysis must not return a measurement")
        } catch is CancellationError { }
        print("Audio normalization: calibration, gating, gain, silence, decoding, track summing and processing tap passed.")
    }
}
