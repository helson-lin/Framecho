//
//  RecordingControlPresenter.swift
//  Screendrop
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
    @AppStorage(ScreendropPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""

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
                if isPaused {
                    manager.resumeRecording()
                } else {
                    manager.pauseRecording()
                }
            }
            .disabled(isSettling)

            BarActionButton(
                id: .restart,
                title: String(localized: "Start over"),
                systemImage: "arrow.counterclockwise",
                accessibility: String(localized: "Restart - discard what's recorded and start again")
            ) {
                manager.restartRecording()
            }
            .disabled(isSettling)

            BarActionButton(
                id: .stop,
                title: String(localized: "Stop and save"),
                systemImage: "stop.fill",
                tint: BarMetrics.recordTint,
                accessibility: String(localized: "Stop and save the recording")
            ) {
                manager.stopRecording()
            }
            .disabled(isSettling)

            BarActionButton(
                id: .discard,
                title: String(localized: "Discard recording"),
                systemImage: "trash.fill",
                accessibility: String(localized: "Discard - delete this recording without saving")
            ) {
                manager.deleteRecording()
            }
            .disabled(manager.state == .starting)
        }
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
