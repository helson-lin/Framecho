//
//  TeleprompterController.swift
//  Framecho
//
//  Glue between the recording lifecycle and the teleprompter: decides
//  whether a starting recording gets the overlay, owns the live speech
//  engine for the session, and tears both down on every finish path.
//  The engine is optional - no microphone means the script still shows,
//  it just doesn't auto-advance.
//

import CoreGraphics
import Foundation

@MainActor
final class TeleprompterController {
    static let shared = TeleprompterController()

    /// The session's live tracker. Read once when the recording wires its
    /// audio callback, so the sample-queue tee never touches the main actor.
    private(set) var activeEngine: TeleprompterSpeechEngine?
    private var hasPreflightedAssets = false

    private init() {}

    /// Kicks off the on-device model download when the user enables the
    /// teleprompter, so pressing Record never waits on an install. Before
    /// macOS 26 this is also when Speech Recognition is asked for, rather
    /// than in the middle of a recording.
    func preflightAssets() {
        guard !hasPreflightedAssets else { return }
        hasPreflightedAssets = true
        if #unavailable(macOS 26.0) {
            Task { _ = await AppPermissionCenter.shared.ensureSpeechRecognition() }
        }
        Task.detached {
            await TeleprompterSpeechEngine.preflightAssets()
        }
    }

    func beginRecordingSession(displayID: CGDirectDisplayID?, microphoneActive: Bool) {
        endRecordingSession()

        guard FramechoPreferences.recordingTeleprompterEnabled else { return }
        let script = FramechoPreferences.recordingTeleprompterScript
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        TeleprompterOverlayPresenter.shared.show(script: script, displayID: displayID)

        guard microphoneActive else { return }
        // Before macOS 26 tracking needs Speech Recognition. It's asked for
        // when the teleprompter is turned on; a prompt now would land in the
        // recording.
        if #unavailable(macOS 26.0) {
            AppPermissionCenter.shared.refresh()
            guard AppPermissionCenter.shared.status(of: .speechRecognition) == .granted else { return }
        }
        let matcher = TeleprompterScriptMatcher(script: script)
        guard !matcher.isEmpty else { return }

        let engine = TeleprompterSpeechEngine(matcher: matcher) { spokenWordCount in
            Task { @MainActor in
                TeleprompterOverlayPresenter.shared.updateProgress(spokenWordCount: spokenWordCount)
            }
        }
        activeEngine = engine
        Task.detached {
            // Best-effort: a failed engine start leaves a static prompter.
            try? await engine.start()
        }
    }

    func setPaused(_ paused: Bool) {
        activeEngine?.setPaused(paused)
    }

    func endRecordingSession() {
        activeEngine?.finish()
        activeEngine = nil
        TeleprompterOverlayPresenter.shared.hide()
    }
}
