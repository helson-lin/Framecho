//
//  RecordingControlPresenter.swift
//  Framecho
//
//  Created by Codex on 01/05/26.
//
//  The in-session mode of the floating bar: elapsed time and the transport
//  controls for the recording that's running. It shares its panel and chrome
//  with the pre-record picker (RecordingPickerBar), so starting a recording
//  morphs one into the other instead of swapping windows.
//

import AppKit
import SwiftUI

/// Retained as the entry point callers already use; the bar itself is owned
/// by RecordingBarPresenter.
@MainActor
enum RecordingControlPresenter {
    static var shared: RecordingBarPresenter { RecordingBarPresenter.shared }
}

extension RecordingBarPresenter {
    func show(displayID: CGDirectDisplayID?) {
        showRecording(displayID: displayID)
    }
}

// MARK: - Controls

struct RecordingSessionControls: View {
    @State private var manager = ScreenRecordingManager.shared
    @State private var microphoneLevel = MicrophoneLevelMonitor.shared
    /// Present from the morph onwards rather than from the first audio
    /// buffer, so the bar doesn't widen again a moment after it settles. A
    /// microphone that can't be used is cleared here before capture starts.
    @AppStorage(FramechoPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    /// The destructive control waiting for its second click, if any.
    @State private var armed: BarTooltipID?
    @State private var disarmTask: Task<Void, Never>?

    /// Below this there's too little to lose to ask twice - a false start is
    /// thrown away in one click.
    private static let confirmationThreshold: TimeInterval = 10
    /// How long an armed control waits for its second click.
    private static let armedDuration = Duration.seconds(3)

    private var isPaused: Bool {
        manager.state == .paused
    }

    /// Starting and finishing are both moments where the transport can't
    /// safely be driven - the capture graph is being wired up or torn down.
    private var isSettling: Bool {
        manager.state == .starting || manager.state == .finishing
    }

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            elapsed

            if !microphoneID.isEmpty {
                microphoneReadout
            }

            BarDivider()

            BarActionButton(
                id: .pauseResume,
                title: isPaused ? String(localized: "Resume recording") : String(localized: "Pause recording"),
                systemImage: isPaused ? "play.fill" : "pause.fill"
            ) {
                disarm()
                if isPaused {
                    manager.resumeRecording()
                } else {
                    manager.pauseRecording()
                }
            }
            .disabled(isSettling)

            BarActionButton(
                id: .restart,
                title: armed == .restart
                    ? String(localized: "Click again to start over")
                    : String(localized: "Start over"),
                systemImage: armed == .restart ? "arrow.counterclockwise.circle.fill" : "arrow.counterclockwise",
                tint: armed == .restart ? BarMetrics.recordTint : BarMetrics.activeTint,
                accessibility: armed == .restart
                    ? String(localized: "Confirm restart - discard what's recorded and start again")
                    : String(localized: "Restart - discard what's recorded and start again")
            ) {
                confirm(.restart) { manager.restartRecording() }
            }
            .disabled(isSettling)

            BarActionButton(
                id: .stop,
                title: String(localized: "Stop and save"),
                systemImage: "stop.fill",
                tint: BarMetrics.recordTint,
                accessibility: String(localized: "Stop and save the recording")
            ) {
                disarm()
                manager.stopRecording()
            }
            .disabled(isSettling)

            // Kept apart from Stop: the two sit where a hurried click lands,
            // and one of them throws the recording away.
            BarDivider()

            BarActionButton(
                id: .discard,
                title: armed == .discard
                    ? String(localized: "Click again to discard")
                    : String(localized: "Discard recording"),
                systemImage: armed == .discard ? "trash.circle.fill" : "trash.fill",
                tint: armed == .discard ? BarMetrics.recordTint : BarMetrics.activeTint,
                accessibility: armed == .discard
                    ? String(localized: "Confirm discard - delete this recording without saving")
                    : String(localized: "Discard - delete this recording without saving")
            ) {
                confirm(.discard) { manager.deleteRecording() }
            }
            .disabled(manager.state == .starting)
        }
        .onChange(of: manager.state) { _, state in
            if state != .recording && state != .paused {
                disarm()
            }
        }
        .onDisappear {
            disarm()
        }
    }

    /// Throwing a recording away takes two clicks once there's something to
    /// lose: the first arms the control - its glyph, colour and tooltip all
    /// change - and only a second click within a few seconds acts. No
    /// dialog, so the bar never steals focus from what's being recorded.
    private func confirm(_ id: BarTooltipID, action: () -> Void) {
        if armed == id || manager.elapsedTime < Self.confirmationThreshold {
            disarm()
            action()
            return
        }
        armed = id
        disarmTask?.cancel()
        disarmTask = Task {
            try? await Task.sleep(for: Self.armedDuration)
            guard !Task.isCancelled else { return }
            armed = nil
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        armed = nil
    }

    /// The recording's own microphone level. A readout, not a control: the
    /// input can't change mid-recording, but whether it's still delivering
    /// sound is exactly what's worth a glance.
    private var microphoneReadout: some View {
        let isFaulty = microphoneLevel.status == .silent || microphoneLevel.status == .unavailable
        return BarActionLabel(
            id: .microphoneLevel,
            title: microphoneReadoutTitle,
            systemImage: isFaulty ? "mic.badge.xmark" : "mic.fill",
            tint: isFaulty ? BarMetrics.warningTint : BarMetrics.activeTint,
            level: microphoneLevel.status == .live ? microphoneLevel.level : nil,
            isInteractive: false
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(microphoneReadoutTitle)
    }

    private var microphoneReadoutTitle: String {
        switch microphoneLevel.status {
        case .silent: String(localized: "Microphone muted - no sound")
        case .unavailable: String(localized: "Microphone not responding")
        case .idle, .starting, .live: String(localized: "Recording microphone")
        }
    }

    private var elapsed: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(BarMetrics.recordTint)
                .frame(width: 8, height: 8)
                .opacity(isPaused ? 0.35 : 1)

            Text(manager.formattedElapsedTime)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(BarMetrics.activeTint)
                // Fixed width so the clock ticking over from 9:59 to 10:00
                // doesn't nudge the whole bar sideways.
                .frame(minWidth: 56, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: BarMetrics.controlSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isPaused
                ? String(localized: "Recording paused at \(manager.formattedElapsedTime)")
                : String(localized: "Recording, \(manager.formattedElapsedTime) elapsed")
        )
    }
}
