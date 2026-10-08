//
//  BackgroundMusic.swift
//  Framecho
//
//  Background music for Studio projects: a catalog of tracks downloaded on
//  first use, the project's choice of track and level, and the gain plan
//  that lays the music under the narration - faded in and out, and ducked
//  while someone is speaking. The plan is pure so playback, export and the
//  checks all share it; AVFoundation only turns it into volume ramps.
//

import AVFoundation
import Foundation

/// A track in the music library. Files are hosted as release assets and
/// cached locally the first time a project uses them, so the app and its
/// updates stay small.
nonisolated struct BackgroundMusicTrack: Identifiable, Sendable, Equatable {
    enum Mood: String, CaseIterable, Identifiable, Sendable {
        case calm
        case cinematic
        case upbeat
        case jazz

        var id: Self { self }

        var title: String {
            switch self {
            case .calm: String(localized: "Calm")
            case .cinematic: String(localized: "Cinematic")
            case .upbeat: String(localized: "Upbeat")
            case .jazz: String(localized: "Jazz")
            }
        }
    }

    var id: String
    var title: String
    var artist: String?
    var mood: Mood
    var duration: TimeInterval
    /// Name of the hosted file, which is also the cached file's name.
    var fileName: String
    /// Terms the track ships under; nil until its license is confirmed.
    var license: String?
    /// Made to repeat: its end runs straight into its start, so loops join
    /// without a crossfade.
    var isSeamlessLoop = false

    var remoteURL: URL {
        BackgroundMusicCatalog.baseURL.appending(path: fileName)
    }
}

nonisolated enum BackgroundMusicCatalog {
    /// Release holding the library's files. A new or changed track goes up
    /// as an asset here (scripts/publish-bgm.sh) before it joins `tracks`.
    static let baseURL = URL(string: "https://github.com/helson-lin/Framecho/releases/download/bgm-v1")!

    static let tracks: [BackgroundMusicTrack] = [
        BackgroundMusicTrack(id: "river-meditation", title: "River Meditation", mood: .calm, duration: 167.1, fileName: "river-meditation.mp3", license: "Public domain (CC0), freepd.com"),
        BackgroundMusicTrack(id: "just-relax", title: "Just Relax", mood: .calm, duration: 309.8, fileName: "just-relax.mp3"),
        BackgroundMusicTrack(id: "peaceful-sleep-music", title: "Peaceful Sleep Music", artist: "Liborio Conti", mood: .calm, duration: 417.6, fileName: "peaceful-sleep-music.mp3"),
        BackgroundMusicTrack(id: "serenity-in-the-woods", title: "Serenity in the Woods", mood: .calm, duration: 608.2, fileName: "serenity-in-the-woods.mp3"),
        BackgroundMusicTrack(id: "cinelax", title: "Cinelax", mood: .calm, duration: 365.7, fileName: "cinelax.mp3"),
        BackgroundMusicTrack(id: "i-believe", title: "I Believe", artist: "Liborio Conti", mood: .cinematic, duration: 313.1, fileName: "i-believe.mp3"),
        BackgroundMusicTrack(id: "deeper-meaning", title: "Deeper Meaning", mood: .cinematic, duration: 429.8, fileName: "deeper-meaning.mp3"),
        BackgroundMusicTrack(id: "horizon", title: "Horizon", mood: .cinematic, duration: 642.3, fileName: "horizon.mp3"),
        BackgroundMusicTrack(id: "wonder", title: "Wonder", mood: .cinematic, duration: 599.5, fileName: "wonder.mp3"),
        BackgroundMusicTrack(id: "light-and-balanced", title: "Light and Balanced", mood: .upbeat, duration: 259.0, fileName: "light-and-balanced.mp3"),
        BackgroundMusicTrack(id: "advertime", title: "Advertime", mood: .upbeat, duration: 134.0, fileName: "advertime.mp3", license: "Public domain (CC0), freepd.com"),
        BackgroundMusicTrack(id: "four-loop", title: "Four Loop", mood: .upbeat, duration: 96.5, fileName: "four-loop.mp3", isSeamlessLoop: true),
        BackgroundMusicTrack(id: "once-upon-a-time", title: "Once Upon a Time", mood: .upbeat, duration: 57.7, fileName: "once-upon-a-time.mp3", isSeamlessLoop: true),
        BackgroundMusicTrack(id: "village-tarantella", title: "Village Tarantella", mood: .upbeat, duration: 53.0, fileName: "village-tarantella.mp3"),
        BackgroundMusicTrack(id: "3-am-west-end", title: "3 am West End", mood: .jazz, duration: 291.2, fileName: "3-am-west-end.mp3", license: "Public domain (CC0), freepd.com"),
        BackgroundMusicTrack(id: "flutey-jazz", title: "Flutey Jazz", mood: .jazz, duration: 247.3, fileName: "flutey-jazz.mp3", license: "Public domain (CC0), freepd.com"),
        BackgroundMusicTrack(id: "a-good-bass-for-gambling", title: "A Good Bass for Gambling", mood: .jazz, duration: 156.0, fileName: "a-good-bass-for-gambling.mp3", license: "Public domain (CC0), freepd.com"),
    ]

    static func track(id: String) -> BackgroundMusicTrack? {
        tracks.first { $0.id == id }
    }

    /// Where a downloaded track lives. Shared by every project, and safe to
    /// delete: a missing file is downloaded again when next needed.
    /// Beside History and Wallpapers in Framecho's Application Support
    /// folder (ScreenshotHistoryStore's, which is main-actor bound).
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Framecho", isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
    }

    static func cachedURL(for track: BackgroundMusicTrack) -> URL {
        cacheDirectory.appendingPathComponent(track.fileName)
    }

    static func cachedFileIfPresent(for track: BackgroundMusicTrack) -> URL? {
        let url = cachedURL(for: track)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// The project's background music: which track and how it sits under the
/// narration.
nonisolated struct RecordingBackgroundMusic: Codable, Sendable, Equatable {
    static let defaultVolume = 0.35
    static let volumeRange: ClosedRange<Double> = 0...1

    var trackID: String
    var volume: Double = defaultVolume
    /// Lowers the music while the narration speaks.
    var ducksUnderSpeech = true
    /// Repeats a track shorter than the video until the video ends.
    var loops = true

    init(trackID: String, volume: Double = defaultVolume, ducksUnderSpeech: Bool = true, loops: Bool = true) {
        self.trackID = trackID
        self.volume = volume
        self.ducksUnderSpeech = ducksUnderSpeech
        self.loops = loops
    }

    private enum CodingKeys: String, CodingKey {
        case trackID
        case volume
        case ducksUnderSpeech
        case loops
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decode(String.self, forKey: .trackID)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? Self.defaultVolume
        ducksUnderSpeech = try container.decodeIfPresent(Bool.self, forKey: .ducksUnderSpeech) ?? true
        loops = try container.decodeIfPresent(Bool.self, forKey: .loops) ?? true
    }

    var clampedVolume: Double {
        volume.isFinite ? min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound) : Self.defaultVolume
    }

    var track: BackgroundMusicTrack? {
        BackgroundMusicCatalog.track(id: trackID)
    }
}

// MARK: - Gain plan

/// The music laid over the cut: where each pass of the track plays, and its
/// level as straight segments, ready to become AVAudioMix volume ramps.
/// The music starts at zero. A track shorter than the cut loops - passes
/// overlap and crossfade on two alternating lanes, or butt together on one
/// for a track made to loop - and the whole fades in, fades out where the
/// music or the video ends, and dips under speech.
nonisolated struct BackgroundMusicGainPlan: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var fromGain: Double
        var toGain: Double
    }

    /// One pass of the track, placed on the cut's timeline.
    struct Pass: Sendable, Equatable {
        var start: TimeInterval
        var duration: TimeInterval
        /// Where in the track this pass starts playing.
        var sourceStart: TimeInterval = 0
        var end: TimeInterval { start + duration }
    }

    /// Passes that never overlap, so they can share one audio track, with
    /// that track's gain over them.
    struct Lane: Sendable, Equatable {
        var passes: [Pass]
        var segments: [Segment]
    }

    static let fadeIn: TimeInterval = 1
    static let fadeOut: TimeInterval = 1.5
    /// How long consecutive passes of a looping track overlap.
    static let crossfade: TimeInterval = 2
    /// Music level under speech, relative to its set level (about -14 dB).
    static let duckRatio = 0.2
    /// The music starts dipping this long before a word, so the first
    /// syllable already sits clear of it.
    static let duckAttack: TimeInterval = 0.25
    /// And comes back up over this long after the last word.
    static let duckRelease: TimeInterval = 0.6
    /// Pauses shorter than this stay ducked; pumping up between sentences
    /// sounds busier than staying low.
    static let speechGapBridge: TimeInterval = 1.2

    /// How long the music plays on the cut.
    var length: TimeInterval
    /// The overall level - fades and ducking, without the crossfades - for
    /// drawing the music lane.
    var segments: [Segment]
    var lanes: [Lane]

    /// Every pass in timeline order.
    var passes: [Pass] {
        lanes.flatMap(\.passes).sorted { $0.start < $1.start }
    }

    /// Where a new pass takes over, for marking loop points.
    var loopPoints: [TimeInterval] {
        let passes = passes
        return zip(passes, passes.dropFirst()).map { previous, next in
            (next.start + min(previous.end, next.start + Self.crossfade)) / 2
        }
    }

    /// `loopRegion` is the part of the track at full strength (see
    /// BackgroundMusicLoopRegion). Repeats play only it, so a crossfade
    /// meets music rather than the track's fade-out and quiet intro; the
    /// first pass still opens with the intro.
    init(
        musicDuration: TimeInterval,
        videoDuration: TimeInterval,
        volume: Double,
        speech: [ClosedRange<TimeInterval>],
        loops: Bool = false,
        isSeamlessLoop: Bool = false,
        loopRegion: ClosedRange<TimeInterval>? = nil
    ) {
        let musicDuration = max(0, musicDuration)
        let videoDuration = max(0, videoDuration)
        let repeats = loops && musicDuration > 0 && musicDuration < videoDuration
        let length = repeats ? videoDuration : min(musicDuration, videoDuration)
        self.length = length
        guard length > 0, volume > 0 else {
            segments = []
            lanes = []
            return
        }

        // Lay out the passes. Overlapping ones alternate lanes; a crossfade
        // never takes more than a third of a pass, so a lane's passes stay
        // apart.
        let region: ClosedRange<TimeInterval> = {
            guard repeats, !isSeamlessLoop, let loopRegion,
                  loopRegion.lowerBound >= 0, loopRegion.upperBound <= musicDuration,
                  loopRegion.upperBound - loopRegion.lowerBound >= 3 * Self.crossfade else {
                return 0...musicDuration
            }
            return loopRegion
        }()
        let regionLength = region.upperBound - region.lowerBound
        let overlap = repeats && !isSeamlessLoop ? min(Self.crossfade, regionLength / 3) : 0
        var passes = [Pass(start: 0, duration: min(repeats ? region.upperBound : musicDuration, length))]
        while repeats, let last = passes.last, last.end < length - 0.05 {
            let start = last.end - overlap
            passes.append(Pass(
                start: start,
                duration: min(regionLength, length - start),
                sourceStart: region.lowerBound
            ))
        }
        let laneCount = overlap > 0 && passes.count > 1 ? 2 : 1

        let fadeIn = min(Self.fadeIn, length / 3)
        let fadeOut = min(Self.fadeOut, length / 3)
        let ducks = Self.mergedSpeech(speech).filter { $0.upperBound > 0 && $0.lowerBound < length }

        func envelope(at time: TimeInterval) -> Double {
            var fade = 1.0
            if time < fadeIn { fade = fadeIn > 0 ? time / fadeIn : 1 }
            if time > length - fadeOut { fade = min(fade, fadeOut > 0 ? (length - time) / fadeOut : 0) }

            var duck = 1.0
            for range in ducks {
                let attackStart = range.lowerBound - Self.duckAttack
                let releaseEnd = range.upperBound + Self.duckRelease
                guard time > attackStart, time < releaseEnd else { continue }
                let depth: Double
                if time < range.lowerBound {
                    depth = (time - attackStart) / Self.duckAttack
                } else if time <= range.upperBound {
                    depth = 1
                } else {
                    depth = 1 - (time - range.upperBound) / Self.duckRelease
                }
                duck = min(duck, 1 - depth * (1 - Self.duckRatio))
            }
            return volume * max(0, fade) * duck
        }

        // Points the envelope bends at; between them it is linear to within
        // what anyone could hear.
        var envelopeTimes: Set<TimeInterval> = [0, fadeIn, length - fadeOut, length]
        for duck in ducks {
            envelopeTimes.formUnion([
                duck.lowerBound - Self.duckAttack, duck.lowerBound,
                duck.upperBound, duck.upperBound + Self.duckRelease,
            ])
        }

        func linearSegments(over times: Set<TimeInterval>, in range: ClosedRange<TimeInterval>, gain: (TimeInterval) -> Double) -> [Segment] {
            let points = times.filter { range.contains($0) }.union([range.lowerBound, range.upperBound]).sorted()
            return zip(points, points.dropFirst()).compactMap { start, end in
                guard end - start > 0.000_5 else { return nil }
                return Segment(start: start, end: end, fromGain: gain(start), toGain: gain(end))
            }
        }

        self.segments = linearSegments(over: envelopeTimes, in: 0...length, gain: envelope)

        // Each pass rises over its overlap with the one before and falls
        // over its overlap with the one after, on an equal-power curve
        // (sampled at the midpoint), so the sum holds steady through the
        // crossfade instead of dipping.
        func crossfadeWeight(of index: Int, at time: TimeInterval) -> Double {
            let pass = passes[index]
            var weight = 1.0
            if index > 0, overlap > 0 {
                let rise = min(passes[index - 1].end, pass.start + overlap) - pass.start
                if rise > 0, time < pass.start + rise {
                    weight = min(weight, sin(.pi / 2 * max(0, time - pass.start) / rise))
                }
            }
            if index < passes.count - 1, overlap > 0 {
                let fallStart = passes[index + 1].start
                let fall = pass.end - fallStart
                if fall > 0, time > fallStart {
                    weight = min(weight, cos(.pi / 2 * min(1, (time - fallStart) / fall)))
                }
            }
            return weight
        }

        lanes = (0..<laneCount).map { lane in
            let indices = passes.indices.filter { $0 % laneCount == lane }
            let laneSegments = indices.flatMap { index -> [Segment] in
                let pass = passes[index]
                var times = envelopeTimes
                if index > 0 {
                    let rise = min(passes[index - 1].end, pass.start + overlap)
                    times.formUnion([(pass.start + rise) / 2, rise])
                }
                if index < passes.count - 1 {
                    let fallStart = passes[index + 1].start
                    times.formUnion([fallStart, (fallStart + pass.end) / 2])
                }
                return linearSegments(over: times, in: pass.start...pass.end) { time in
                    envelope(at: time) * crossfadeWeight(of: index, at: time)
                }
            }
            return Lane(passes: indices.map { passes[$0] }, segments: laneSegments)
        }
    }

    /// Narration words on the edited timeline, joined across short pauses.
    /// Words whose audio was cut have no editor time and drop out.
    static func speechRanges(
        words: [RecordingTranscriptWord],
        editorTime: (TimeInterval) -> TimeInterval?
    ) -> [ClosedRange<TimeInterval>] {
        let ranges = words.compactMap { word -> ClosedRange<TimeInterval>? in
            guard let start = editorTime(word.start) ?? editorTime(word.midpoint),
                  let end = editorTime(word.end) ?? editorTime(word.midpoint) else {
                return nil
            }
            return min(start, end)...max(start, end)
        }
        return mergedSpeech(ranges)
    }

    static func mergedSpeech(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        var merged: [ClosedRange<TimeInterval>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound - last.upperBound < speechGapBridge {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// One lane's level as volume ramps on its composition track.
    static func audioMixParameters(for lane: Lane, track: AVAssetTrack) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(Float(lane.segments.first?.fromGain ?? 0), at: .zero)
        for segment in lane.segments {
            parameters.setVolumeRamp(
                fromStartVolume: Float(segment.fromGain),
                toEndVolume: Float(segment.toGain),
                timeRange: CMTimeRange(
                    start: CMTime(seconds: segment.start, preferredTimescale: 600),
                    end: CMTime(seconds: segment.end, preferredTimescale: 600)
                )
            )
        }
        return parameters
    }
}

// MARK: - Loop region

/// Where a track is at full strength. Most tracks open quietly and end on a
/// long fade - several seconds of near silence - so a crossfade from one
/// pass's end into the next pass's start would dip audibly. Loops play this
/// region instead. Found from the track's loudness once, then kept beside
/// the cached file.
nonisolated enum BackgroundMusicLoopRegion {
    /// Loudness is measured in windows this long.
    static let window: TimeInterval = 0.1
    /// Every window in a run this long must reach the threshold, so a
    /// single loud hit in a fade doesn't count as the music being back.
    static let runLength = 5
    /// Full strength is at least this share of the track's median level.
    static let thresholdRatio = 0.4
    /// Shorter than this, the region isn't worth looping on its own.
    static let minimumLength: TimeInterval = 10

    /// The region from per-window levels (RMS), or nil when the track never
    /// settles into one.
    static func detect(levels: [Double]) -> ClosedRange<TimeInterval>? {
        guard levels.count > runLength * 2 else { return nil }
        let median = levels.sorted()[levels.count / 2]
        let threshold = max(0.004, median * thresholdRatio)
        func sustained(_ range: Range<Int>) -> Bool {
            range.allSatisfy { levels[$0] >= threshold }
        }
        guard let first = (0...(levels.count - runLength)).first(where: { sustained($0..<($0 + runLength)) }),
              let last = (runLength...levels.count).reversed().first(where: { sustained(($0 - runLength)..<$0) }) else {
            return nil
        }
        let start = Double(first) * window
        let end = Double(last) * window
        return end - start >= minimumLength ? start...end : nil
    }

    private struct Stored: Codable {
        var start: TimeInterval
        var end: TimeInterval
    }

    private static func sidecarURL(for url: URL) -> URL {
        url.appendingPathExtension("loop.json")
    }

    /// The stored region, or one measured now and stored for next time.
    static func resolve(url: URL, asset: AVAsset, track: AVAssetTrack) async -> ClosedRange<TimeInterval>? {
        let sidecar = sidecarURL(for: url)
        if let data = try? Data(contentsOf: sidecar),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            return stored.start < stored.end ? stored.start...stored.end : nil
        }
        guard let levels = try? await measureLevels(asset: asset, track: track) else { return nil }
        let region = detect(levels: levels)
        // An empty range records "measured, no region" so it isn't redone.
        let stored = Stored(start: region?.lowerBound ?? 0, end: region?.upperBound ?? 0)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: sidecar, options: .atomic)
        }
        return region
    }

    /// RMS per window, decoded at a low mono rate: loudness is all this
    /// needs, and a ten-minute track reads in under a second.
    private static func measureLevels(asset: AVAsset, track: AVAssetTrack) async throws -> [Double] {
        let sampleRate = 8_000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CancellationError() }

        let samplesPerWindow = Int(sampleRate * window)
        var levels: [Double] = []
        var sum = 0.0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for index in 0..<(length / 4) {
                    sum += Double(samples[index] * samples[index])
                    count += 1
                    if count == samplesPerWindow {
                        levels.append((sum / Double(count)).squareRoot())
                        sum = 0
                        count = 0
                    }
                }
            }
        }
        return levels
    }
}

// MARK: - Mixing

/// A library track resolved for mixing, like RecordingReplacementAudio.
nonisolated struct LoadedBackgroundMusic {
    let trackID: String
    let url: URL
    /// Held so the track stays usable: a track only weakly references its
    /// asset, and inserting from an orphaned track fails (-12780).
    let asset: AVURLAsset
    let track: AVAssetTrack
    /// The audio track's own extent. A compressed file's container duration
    /// can run past it, and inserting beyond it fails the whole composition.
    let timeRange: CMTimeRange
    /// The part of the track at full strength, which loops play.
    let loopRegion: ClosedRange<TimeInterval>?

    var duration: TimeInterval {
        timeRange.duration.seconds
    }

    static func load(trackID: String, url: URL) async -> LoadedBackgroundMusic? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let timeRange = try? await track.load(.timeRange),
              timeRange.duration.seconds.isFinite, timeRange.duration.seconds > 0 else {
            return nil
        }
        let loopRegion = await BackgroundMusicLoopRegion.resolve(url: url, asset: asset, track: track)
        return LoadedBackgroundMusic(
            trackID: trackID,
            url: url,
            asset: asset,
            track: track,
            timeRange: timeRange,
            loopRegion: loopRegion
        )
    }
}

nonisolated enum BackgroundMusicMixer {
    /// Lays the music's passes on one composition track per lane, and
    /// returns those tracks in lane order. Only a composition takes new
    /// tracks, so callers build one even for an unedited recording.
    @discardableResult
    static func addingMusic(
        from source: AVAssetTrack,
        sourceRange: CMTimeRange,
        plan: BackgroundMusicGainPlan,
        to composition: AVMutableComposition
    ) throws -> [AVMutableCompositionTrack] {
        try plan.lanes.compactMap { lane in
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { return nil }
            for pass in lane.passes {
                // Never past the source's own end: a compressed file's
                // container duration can overrun it, which fails the insert.
                let offset = CMTime(seconds: pass.sourceStart, preferredTimescale: 600)
                let duration = CMTimeMinimum(
                    CMTime(seconds: pass.duration, preferredTimescale: 600),
                    sourceRange.duration - offset
                )
                guard duration > .zero else { continue }
                try track.insertTimeRange(
                    CMTimeRange(start: sourceRange.start + offset, duration: duration),
                    of: source,
                    at: CMTime(seconds: pass.start, preferredTimescale: 600)
                )
            }
            return track
        }
    }

    /// The narration at its volume plus the music on its plan, as one mix
    /// for a player item or an audio reader. Nil when neither needs one.
    /// `musicTracks` are the plan's lanes' tracks, in lane order.
    static func makeMix(
        narrationTracks: [AVAssetTrack],
        narrationVolume: Double,
        musicTracks: [AVAssetTrack],
        plan: BackgroundMusicGainPlan?,
        normalization: RecordingAudioNormalization.Measurement? = nil
    ) -> AVAudioMix? {
        let narrationMix = RecordingAudioGain.makeMix(
            tracks: narrationTracks, volume: narrationVolume, normalization: normalization
        )
        guard let plan, !musicTracks.isEmpty, musicTracks.count == plan.lanes.count else { return narrationMix }
        let mix = AVMutableAudioMix()
        mix.inputParameters = (narrationMix?.inputParameters ?? [])
            + zip(plan.lanes, musicTracks).map { BackgroundMusicGainPlan.audioMixParameters(for: $0, track: $1) }
        return mix
    }
}

/// What an export needs to mix the music in: the cached file and the plan
/// already worked out against the cut and its narration.
nonisolated struct BackgroundMusicExport: Sendable {
    let url: URL
    let plan: BackgroundMusicGainPlan
}
