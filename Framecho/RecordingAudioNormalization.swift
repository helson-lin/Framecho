import AVFoundation

/// Integrated K-weighted loudness of the edited soundtrack, before the
/// volume slider and background music. PCM is decoded as 48 kHz stereo,
/// matching the fixed filter coefficients in ITU-R BS.1770, Annex 1.
/// https://www.itu.int/rec/R-REC-BS.1770/en
nonisolated enum RecordingAudioNormalization {
    static let sampleRate = 48_000.0
    static let targetLUFS = -16.0
    static let peakCeiling = pow(10.0, -1.0 / 20)

    struct Measurement: Sendable, Equatable {
        let integratedLUFS: Double?
        /// Sample peak of the summed stereo soundtrack, not a true-peak meter.
        let samplePeak: Double

        func gain(volume: Double) -> Double {
            let volume = RecordingAudioGain.normalized(volume)
            guard let integratedLUFS, integratedLUFS.isFinite,
                  samplePeak.isFinite, samplePeak > 0 else { return volume }
            // Avoid amplifying a nearly silent/noisy recording by more than
            // 20 dB. Peak safety takes priority over reaching the target,
            // including when the user raises the volume after normalizing.
            let correction = min(10, pow(10, (targetLUFS - integratedLUFS) / 20))
            return min(volume * correction, peakCeiling / samplePeak)
        }
    }

    /// Streaming meter: 400 ms windows, 75% overlap, -70 LUFS absolute
    /// gate and -10 LU relative gate (EBU Tech 3341, section 2.3).
    /// https://tech.ebu.ch/docs/tech/tech3341.pdf
    struct Meter {
        private struct Biquad {
            let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
            var z1 = 0.0, z2 = 0.0

            mutating func process(_ input: Double) -> Double {
                let output = b0 * input + z1
                z1 = b1 * input - a1 * output + z2
                z2 = b2 * input - a2 * output
                return output
            }
        }

        private struct Channel {
            var shelf = Biquad(
                b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                a1: -1.69065929318241, a2: 0.73248077421585
            )
            var highpass = Biquad(
                b0: 1, b1: -2, b2: 1,
                a1: -1.99004745483398, a2: 0.99007225036621
            )

            mutating func process(_ input: Double) -> Double {
                highpass.process(shelf.process(input))
            }
        }

        private var left = Channel(), right = Channel()
        private var bucketEnergy = 0.0
        private var bucketFrames = 0
        private var buckets = [Double](repeating: 0, count: 4)
        private var bucketIndex = 0
        private var completedBuckets = 0
        private var blockEnergies: [Double] = []
        private var totalEnergy = 0.0
        private var totalFrames = 0
        private var peak = 0.0

        mutating func consume(_ samples: UnsafeBufferPointer<Float>) {
            for frame in 0..<(samples.count / 2) {
                let l = samples[frame * 2].isFinite ? Double(samples[frame * 2]) : 0
                let r = samples[frame * 2 + 1].isFinite ? Double(samples[frame * 2 + 1]) : 0
                peak = max(peak, abs(l), abs(r))
                let filteredLeft = left.process(l)
                let filteredRight = right.process(r)
                let energy = filteredLeft * filteredLeft + filteredRight * filteredRight
                bucketEnergy += energy
                totalEnergy += energy
                totalFrames += 1
                bucketFrames += 1
                if bucketFrames == 4_800 {
                    buckets[bucketIndex] = bucketEnergy
                    bucketIndex = (bucketIndex + 1) % 4
                    completedBuckets += 1
                    if completedBuckets >= 4 {
                        blockEnergies.append(buckets.reduce(0, +) / 19_200)
                    }
                    bucketFrames = 0
                    bucketEnergy = 0
                }
            }
        }

        var measurement: Measurement {
            // Sub-400 ms clips cannot form a standard gating block. Use
            // their complete energy instead so short clips remain usable.
            let energies = blockEnergies.isEmpty && totalFrames > 0
                ? [totalEnergy / Double(totalFrames)] : blockEnergies
            let absolute = energies.filter { $0 > pow(10, (-70 + 0.691) / 10) }
            guard !absolute.isEmpty else {
                return Measurement(integratedLUFS: nil, samplePeak: peak)
            }
            let relativeThreshold = absolute.reduce(0, +) / Double(absolute.count) / 10
            let gated = absolute.filter { $0 > relativeThreshold }
            let energy = gated.reduce(0, +) / Double(gated.count)
            return Measurement(integratedLUFS: -0.691 + 10 * log10(energy), samplePeak: peak)
        }
    }

    enum AnalysisError: LocalizedError {
        case unreadableAudio

        var errorDescription: String? {
            String(localized: "The audio could not be analyzed for loudness normalization.")
        }
    }

    /// Sum all narration tracks before metering so simultaneous system
    /// audio and microphone audio share one gain and one peak constraint.
    @concurrent
    static func measure(
        asset: AVAsset,
        excludingTrackIDs: [CMPersistentTrackID] = [],
        timeRange: CMTimeRange
    ) async throws -> Measurement? {
        try Task.checkCancellation()
        let tracks = try await asset.loadTracks(withMediaType: .audio)
            .filter { !excludingTrackIDs.contains($0.trackID) }
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.unreadableAudio }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var meter = Meter()
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw AnalysisError.unreadableAudio }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0 else { continue }
            guard size % (2 * MemoryLayout<Float>.size) == 0 else { throw AnalysisError.unreadableAudio }
            // Copy also handles noncontiguous block buffers. Only one
            // decoded buffer is retained, regardless of recording length.
            var samples = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw AnalysisError.unreadableAudio }
            samples.withUnsafeBufferPointer { meter.consume($0) }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? AnalysisError.unreadableAudio }
        return meter.measurement
    }
}
