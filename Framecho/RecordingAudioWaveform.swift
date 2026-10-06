//
//  RecordingAudioWaveform.swift
//  Framecho
//
//  Peak levels of a recording's audio, sampled on the source timeline for the
//  Studio audio lane. Decoding downmixes to a low-rate mono stream, so even a
//  long recording reads in a moment and the result stays a few hundred KB.
//

import AVFoundation

nonisolated struct RecordingAudioWaveform: Sendable, Equatable {
    /// Peak buckets per second of source time.
    static let bucketsPerSecond: Double = 100
    private static let decodeSampleRate: Double = 8_000

    /// Normalized 0...1 peak per bucket, loudest bucket = 1.
    let peaks: [Float]

    var duration: TimeInterval {
        Double(peaks.count) / Self.bucketsPerSecond
    }

    /// Loudest bucket touching `start..<end` in source seconds; a span
    /// shorter than one bucket reads the bucket it falls in.
    func peak(from start: TimeInterval, to end: TimeInterval) -> Float {
        guard !peaks.isEmpty, end.isFinite, start.isFinite else { return 0 }
        let lower = max(0, min(peaks.count - 1, Int(start * Self.bucketsPerSecond)))
        let upper = max(lower + 1, min(peaks.count, Int((end * Self.bucketsPerSecond).rounded(.up))))
        var loudest: Float = 0
        for index in lower..<upper where peaks[index] > loudest {
            loudest = peaks[index]
        }
        return loudest
    }

    /// Reads the first audio track of `url`, or nil when it has none, it
    /// can't be decoded, or the task is cancelled. `@concurrent` keeps the
    /// decode off the caller's actor.
    @concurrent
    static func load(url: URL) async -> RecordingAudioWaveform? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: decodeSampleRate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let framesPerBucket = max(1, Int(decodeSampleRate / bucketsPerSecond))
        var peaks: [Float] = []
        var bucketPeak: Float = 0
        var bucketFrames = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { continue }

            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                for index in 0..<count {
                    let magnitude = abs(samples[index])
                    if magnitude > bucketPeak { bucketPeak = magnitude }
                    bucketFrames += 1
                    if bucketFrames == framesPerBucket {
                        peaks.append(bucketPeak)
                        bucketPeak = 0
                        bucketFrames = 0
                    }
                }
            }
        }
        if bucketFrames > 0 {
            peaks.append(bucketPeak)
        }
        guard reader.status == .completed, let loudest = peaks.max(), loudest > 0 else {
            return nil
        }
        return RecordingAudioWaveform(peaks: peaks.map { $0 / loudest })
    }
}
