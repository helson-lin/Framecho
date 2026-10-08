import Foundation

// Exercises the background music gain plan - fades, ducking under speech,
// and its length against the cut - and the library's catalog, without
// playing anything.
@main
struct BackgroundMusicChecks {
    static func main() {
        func gain(_ plan: BackgroundMusicGainPlan, at time: TimeInterval) -> Double {
            guard let segment = plan.segments.first(where: { $0.start <= time && time <= $0.end }) else { return 0 }
            let span = segment.end - segment.start
            let progress = span > 0 ? (time - segment.start) / span : 0
            return segment.fromGain + (segment.toGain - segment.fromGain) * progress
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }

        // No speech: fade in, hold the level, fade out at the end of the cut.
        let plain = BackgroundMusicGainPlan(musicDuration: 120, videoDuration: 60, volume: 0.4, speech: [])
        precondition(plain.length == 60, "Music stops with the video")
        precondition(near(gain(plain, at: 0), 0))
        precondition(near(gain(plain, at: 0.5), 0.2))
        precondition(near(gain(plain, at: 30), 0.4))
        precondition(near(gain(plain, at: 60), 0))
        precondition(gain(plain, at: 59) < 0.4 && gain(plain, at: 59) > 0)

        // Segments tile the music without gaps or overlaps.
        for (a, b) in zip(plain.segments, plain.segments.dropFirst()) {
            precondition(near(a.end, b.start), "Segments are contiguous")
        }
        precondition(near(plain.segments.first!.start, 0) && near(plain.segments.last!.end, 60))

        // A short track plays once and fades out at its own end.
        let short = BackgroundMusicGainPlan(musicDuration: 20, videoDuration: 60, volume: 0.4, speech: [])
        precondition(short.length == 20)
        precondition(near(gain(short, at: 20), 0))

        // Speech ducks the music: down just before, low during, back up after.
        let ducked = BackgroundMusicGainPlan(musicDuration: 120, videoDuration: 60, volume: 0.5, speech: [10...20])
        let low = 0.5 * BackgroundMusicGainPlan.duckRatio
        precondition(near(gain(ducked, at: 5), 0.5))
        precondition(near(gain(ducked, at: 10), low), "Ducked by the first word")
        precondition(near(gain(ducked, at: 15), low))
        precondition(near(gain(ducked, at: 20), low))
        precondition(gain(ducked, at: 20.3) > low && gain(ducked, at: 20.3) < 0.5, "Releases gradually")
        precondition(near(gain(ducked, at: 21), 0.5))
        precondition(gain(ducked, at: 9.9) < 0.5, "Attack starts before the word")

        // Short pauses between sentences stay ducked; long ones lift.
        precondition(BackgroundMusicGainPlan.mergedSpeech([1...2, 2.5...3, 10...11]) == [1...3, 10...11])
        let bridged = BackgroundMusicGainPlan(musicDuration: 60, videoDuration: 60, volume: 0.5, speech: [10...12, 12.8...15])
        precondition(near(gain(bridged, at: 12.4), low), "No pumping in a short pause")

        // Silence and nothing to play produce no ramps.
        precondition(BackgroundMusicGainPlan(musicDuration: 60, videoDuration: 60, volume: 0, speech: []).segments.isEmpty)
        precondition(BackgroundMusicGainPlan(musicDuration: 0, videoDuration: 60, volume: 0.5, speech: []).segments.isEmpty)

        // Looping: a 60 s track under a 200 s video plays four passes that
        // overlap by the crossfade, alternating between two lanes.
        func laneGain(_ lane: BackgroundMusicGainPlan.Lane, at time: TimeInterval) -> Double {
            guard let segment = lane.segments.first(where: { $0.start <= time && time <= $0.end }) else { return 0 }
            let span = segment.end - segment.start
            let progress = span > 0 ? (time - segment.start) / span : 0
            return segment.fromGain + (segment.toGain - segment.fromGain) * progress
        }
        let looped = BackgroundMusicGainPlan(musicDuration: 60, videoDuration: 200, volume: 0.5, speech: [], loops: true)
        precondition(looped.length == 200, "Loops fill the video")
        precondition(looped.passes.map(\.start) == [0, 58, 116, 174], "\(looped.passes)")
        precondition(looped.passes.map(\.duration) == [60, 60, 60, 26])
        precondition(looped.lanes.count == 2)
        for lane in looped.lanes {
            for (a, b) in zip(lane.passes, lane.passes.dropFirst()) {
                precondition(a.end <= b.start, "A lane's passes never overlap")
            }
        }
        precondition(looped.loopPoints == [59, 117, 175], "\(looped.loopPoints)")
        // Equal-power crossfade: at the seam each pass sits at ~0.707, so the
        // summed power holds at the set level.
        let seamPower = looped.lanes.map { pow(laneGain($0, at: 59), 2) }.reduce(0, +)
        precondition(abs(seamPower.squareRoot() - 0.5) < 0.01, "\(seamPower.squareRoot())")
        precondition(near(laneGain(looped.lanes[0], at: 30), 0.5))
        precondition(near(laneGain(looped.lanes[1], at: 30), 0), "The other lane is silent between seams")
        precondition(near(laneGain(looped.lanes[1], at: 90), 0.5))
        precondition(near(gain(looped, at: 200), 0), "The last pass fades out with the video")

        // With a loop region, repeats skip the quiet intro and fade-out tail:
        // the first pass plays the intro up to the region's end, later passes
        // play only the region.
        let trimmed = BackgroundMusicGainPlan(
            musicDuration: 60, videoDuration: 200, volume: 0.5, speech: [],
            loops: true, loopRegion: 3...50
        )
        precondition(trimmed.passes[0].sourceStart == 0 && trimmed.passes[0].duration == 50, "\(trimmed.passes)")
        precondition(trimmed.passes.dropFirst().allSatisfy { $0.sourceStart == 3 })
        precondition(trimmed.passes[1].start == 48 && trimmed.passes[1].duration == 47)
        precondition(trimmed.passes.last!.end == 200)
        // A region too short to crossfade in is ignored.
        precondition(BackgroundMusicGainPlan(
            musicDuration: 60, videoDuration: 200, volume: 0.5, speech: [], loops: true, loopRegion: 10...14
        ).passes[0].duration == 60)

        // Detecting the region: quiet intro and long fade-out are trimmed;
        // a single loud window in the fade doesn't count.
        var levels = Array(repeating: 0.001, count: 20)      // 2 s near silence
            + Array(repeating: 0.2, count: 300)               // 30 s of music
            + Array(repeating: 0.02, count: 50)               // 5 s fade tail
        levels[340] = 0.3
        let region = BackgroundMusicLoopRegion.detect(levels: levels)!
        precondition(abs(region.lowerBound - 2) < 0.15 && abs(region.upperBound - 32) < 0.15, "\(region)")
        precondition(BackgroundMusicLoopRegion.detect(levels: Array(repeating: 0.1, count: 50)) == nil, "Too short")
        let steady = BackgroundMusicLoopRegion.detect(levels: Array(repeating: 0.1, count: 600))!
        precondition(steady.lowerBound == 0 && abs(steady.upperBound - 60) < 0.01, "A steady track keeps its ends")

        // A track made to loop joins end to start on one lane, no overlap.
        let seamless = BackgroundMusicGainPlan(musicDuration: 60, videoDuration: 150, volume: 0.5, speech: [], loops: true, isSeamlessLoop: true)
        precondition(seamless.lanes.count == 1)
        precondition(seamless.passes.map(\.start) == [0, 60, 120])
        precondition(near(laneGain(seamless.lanes[0], at: 60), 0.5), "No dip at a seamless seam")

        // Looping off, or a track long enough: one pass.
        precondition(BackgroundMusicGainPlan(musicDuration: 60, videoDuration: 200, volume: 0.5, speech: []).passes.count == 1)
        precondition(BackgroundMusicGainPlan(musicDuration: 300, videoDuration: 200, volume: 0.5, speech: [], loops: true).passes.count == 1)

        // Ducking reaches every pass.
        let duckedLoop = BackgroundMusicGainPlan(musicDuration: 60, videoDuration: 200, volume: 0.5, speech: [130...140], loops: true)
        precondition(near(laneGain(duckedLoop.lanes[0], at: 135), 0.5 * BackgroundMusicGainPlan.duckRatio))

        // Speech ranges come from words on the edited timeline; cut words drop out.
        let words = [
            RecordingTranscriptWord(text: "Hello ", start: 1, end: 1.4),
            RecordingTranscriptWord(text: "cut ", start: 5, end: 5.4),
            RecordingTranscriptWord(text: "world", start: 1.6, end: 2),
        ]
        let ranges = BackgroundMusicGainPlan.speechRanges(words: words) { source in
            (4...6).contains(source) ? nil : source
        }
        precondition(ranges == [1...2], "\(ranges)")

        // The catalog: unique ids and files, every track playable.
        let tracks = BackgroundMusicCatalog.tracks
        precondition(Set(tracks.map(\.id)).count == tracks.count)
        precondition(Set(tracks.map(\.fileName)).count == tracks.count)
        precondition(tracks.allSatisfy { $0.duration > 0 && !$0.fileName.contains(" ") })
        precondition(BackgroundMusicCatalog.track(id: "flutey-jazz")?.remoteURL.absoluteString
            == "https://github.com/helson-lin/Framecho/releases/download/bgm-v1/flutey-jazz.mp3")

        // Projects saved with only a track decode to the defaults.
        let legacy = try! JSONDecoder().decode(
            RecordingBackgroundMusic.self,
            from: Data(#"{"trackID":"wonder"}"#.utf8)
        )
        precondition(legacy == RecordingBackgroundMusic(trackID: "wonder"))
        precondition(legacy.loops, "Older projects loop by default")
        precondition(BackgroundMusicCatalog.track(id: "four-loop")?.isSeamlessLoop == true)
        precondition(RecordingBackgroundMusic(trackID: "x", volume: 4).clampedVolume == 1)

        print("Background music checks passed.")
    }
}
