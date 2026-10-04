import CoreMedia

// Exercises the host-clock pause bookkeeping the screen and camera writers
// share, without starting a recording.
@main
struct RecordingPauseChecks {
    static func main() {
        func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }
        func paused(_ timeline: RecordingPauseTimeline, _ seconds: Double) -> Double? {
            timeline.pausedDuration(before: t(seconds))?.seconds
        }

        var timeline = RecordingPauseTimeline()
        precondition(paused(timeline, 5) == 0)

        // A static screen delivers no frames during the pause; the interval
        // must still come off the timeline in full.
        timeline.pause(at: t(10))
        precondition(timeline.isPaused)
        precondition(paused(timeline, 9.99) == 0, "A frame queued before Pause still lands")
        precondition(paused(timeline, 10) == nil)
        precondition(paused(timeline, 20) == nil)
        timeline.resume(at: t(40))
        precondition(!timeline.isPaused)
        precondition(paused(timeline, 39.9) == nil, "A frame captured during the pause never lands")
        precondition(paused(timeline, 40) == 30)

        // Sample times outside pauses map monotonically onto the movie.
        precondition(9.99 - paused(timeline, 9.99)! < 40.01 - paused(timeline, 40.01)!)

        timeline.pause(at: t(50))
        timeline.resume(at: t(52))
        precondition(paused(timeline, 45) == 30, "Later pauses never move earlier samples")
        precondition(paused(timeline, 60) == 32)

        // Repeated presses are idempotent, and a zero-length pause is a no-op.
        timeline.resume(at: t(70))
        timeline.pause(at: t(80))
        timeline.pause(at: t(81))
        timeline.resume(at: t(80))
        precondition(paused(timeline, 90) == 32)

        timeline.reset()
        precondition(paused(timeline, 90) == 0)
        print("Recording pause checks passed.")
    }
}
