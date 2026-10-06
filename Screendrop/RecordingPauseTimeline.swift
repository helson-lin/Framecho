//
//  RecordingPauseTimeline.swift
//  Framecho
//
//  Pause bookkeeping shared by the screen and camera movie writers. Pauses
//  are stamped on the host clock when the user presses Pause/Resume - the
//  same clock ScreenCaptureKit and AVCapture timestamp samples with, and the
//  one PointerActivityRecorder records its pause intervals on. Deriving the
//  pause from sample arrival instead lost every pause during which the
//  screen was static (ScreenCaptureKit delivers no frames then), and left the
//  video, camera, and cursor timelines each shifted by a different amount.
//

import CoreMedia

nonisolated struct RecordingPauseTimeline: Sendable {
    private struct Interval: Sendable {
        let start: CMTime
        let end: CMTime
    }

    private var intervals: [Interval] = []
    private var openPauseStart: CMTime?

    var isPaused: Bool { openPauseStart != nil }

    static func hostTimeNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    mutating func pause(at time: CMTime) {
        guard openPauseStart == nil else { return }
        openPauseStart = time
    }

    mutating func resume(at time: CMTime) {
        guard let start = openPauseStart else { return }
        openPauseStart = nil
        if time > start {
            intervals.append(Interval(start: start, end: time))
        }
    }

    /// Total paused time before a sample taken at `time`, or nil when the
    /// sample falls inside a pause and must not be written. Samples are
    /// judged by their own timestamp rather than by when they are processed,
    /// so a frame queued just before Pause still lands and one captured
    /// during the pause never does.
    func pausedDuration(before time: CMTime) -> CMTime? {
        if let openPauseStart, time >= openPauseStart { return nil }
        var total = CMTime.zero
        for interval in intervals {
            if time >= interval.end {
                total = CMTimeAdd(total, CMTimeSubtract(interval.end, interval.start))
            } else if time >= interval.start {
                return nil
            }
        }
        return total
    }

    mutating func reset() {
        intervals = []
        openPauseStart = nil
    }
}
