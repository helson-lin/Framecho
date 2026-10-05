//
//  CaptureCoordinator.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// What a Capture Text run produced. `cancelled` and `noTextFound` look the
/// same to a caller handed a plain optional, but a Shortcut needs to tell the
/// user which one happened.
enum CaptureTextOutcome {
    case cancelled
    case noTextFound
    case copied(String)
}

/// Single long-lived coordinator that manages the capture → preview flow.
@Observable
final class CaptureCoordinator {
    
    static let shared = CaptureCoordinator()
    
    /// Set by the App to open the preview window. Returns the URL the
    /// capture was imported to in history, so awaitable capture callers
    /// (App Intents) can hand the finished file to their result.
    var onShowPreview: ((URL, CGDirectDisplayID?) -> URL)?
    
    private init() {}
    
    // MARK: - Capture Actions

    func captureFullscreen() {
        Task { await performCaptureFullscreen() }
    }

    func captureWindow() {
        Task { await performCaptureWindow() }
    }

    func captureArea() {
        Task { await performCaptureArea() }
    }

    func captureText() {
        Task { await performCaptureText() }
    }

    func captureAreaAndPin() {
        Task { await performCaptureAreaAndPin() }
    }

    func captureOnTimer() {
        Task { await performCaptureOnTimer() }
    }

    // MARK: - Awaitable Capture Actions

    /// Awaitable variants for callers (App Intents / Shortcuts) that need the
    /// resulting file back to hand off to a following action. Both routes
    /// funnel through the same finish-capture path as the hotkey/menu bar
    /// triggers, so history import, sound, and preview behavior stay
    /// identical either way.
    @discardableResult
    func captureFullscreenAwaiting() async -> URL? {
        await performCaptureFullscreen()
    }

    @discardableResult
    func captureWindowAwaiting() async -> URL? {
        await performCaptureWindow()
    }

    @discardableResult
    func captureAreaAwaiting() async -> URL? {
        await performCaptureArea()
    }

    /// Returns the recognized text rather than a URL - Capture Text produces
    /// no file, and a Shortcuts action that hands back a string is what makes
    /// it composable with the rest of a workflow. The outcome distinguishes a
    /// cancelled selection from a region that simply had no text in it, which
    /// a Shortcut needs to report accurately.
    @discardableResult
    func captureTextAwaiting() async -> CaptureTextOutcome {
        await performCaptureText()
    }

    @discardableResult
    private func performCaptureFullscreen() async -> URL? {
        guard AppPermissionCenter.shared.ensureScreenRecording() else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        PreviewWindowPlacement.shared.setTargetDisplayID(displayID)

        guard await CaptureCountdownPresenter.shared.runIfNeeded(
            seconds: ScreendropPreferences.captureDelaySeconds,
            displayID: displayID
        ) else { return nil }
        guard let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID) else { return nil }
        return finishCapture(url: url, displayID: displayID)
    }

    @discardableResult
    private func performCaptureWindow() async -> URL? {
        guard AppPermissionCenter.shared.ensureScreenRecording() else { return nil }
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the window is picked, not before.
        guard let url = await ScreenshotManager.shared.captureWindow(
            includeShadow: ScreendropPreferences.captureWindowShadow,
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        ) else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return finishCapture(url: url, displayID: displayID)
    }

    @discardableResult
    private func performCaptureArea() async -> URL? {
        guard AppPermissionCenter.shared.ensureScreenRecording() else { return nil }
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the area is drawn, not before.
        guard let url = await ScreenshotManager.shared.captureArea(
            includeShadow: ScreendropPreferences.captureWindowShadow,
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        ) else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return finishCapture(url: url, displayID: displayID)
    }

    /// Pins the drawn area straight to the screen. The capture still goes to
    /// History, so the pin can be annotated and found again, but there is no
    /// preview card or after-capture action: the pin is the result. Skips
    /// the self-timer, which is for staging a screen, not grabbing a reference.
    private func performCaptureAreaAndPin() async {
        guard AppPermissionCenter.shared.ensureScreenRecording() else { return }
        guard let url = await ScreenshotManager.shared.captureArea(
            includeShadow: ScreendropPreferences.captureWindowShadow
        ) else { return }
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url, movingSource: true)
        PinnedScreenshotPresenter.shared.pin(url: historyURL)
    }

    /// Capture Text is the odd one out: it recognizes the text inside the drawn
    /// area, puts it on the clipboard, and throws the image away. It
    /// deliberately skips `finishCapture` - there is no file to import into
    /// history, no preview card to raise, and no after-capture action to run -
    /// so the toast and the capture sound are its only feedback.
    ///
    /// The self-timer is handled by screencapture's `-T`, so the delay happens
    /// after the area is drawn, matching Capture Area.
    @discardableResult
    private func performCaptureText() async -> CaptureTextOutcome {
        guard AppPermissionCenter.shared.ensureScreenRecording() else { return .cancelled }
        guard let url = await ScreenshotManager.shared.captureArea(
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        ) else { return .cancelled }
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = await copyRecognizedText(at: url, from: .area)
        if ScreendropPreferences.playSounds {
            switch outcome {
            case .copied: CaptureFeedbackSound.play()
            case .noTextFound: NSSound.beep()
            case .cancelled: break
            }
        }
        return outcome
    }

    /// Recognizes the text in an image, copies it, and confirms with a toast -
    /// the one path behind Capture Text, the preview card, and pins, so every
    /// entry point reports progress and empty results the same way.
    @discardableResult
    func copyRecognizedText(at url: URL, from source: CaptureTextSource) async -> CaptureTextOutcome {
        // Resolved before recognition runs, so the toast lands on the display
        // the user was just working on rather than wherever the pointer
        // drifted to while Vision worked.
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        let feedback = CaptureTextFeedbackPresenter.shared

        let progress = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            feedback.showRecognizing(displayID: displayID)
        }
        let text = await ImageTextRecognizer.recognizeText(at: url)
        progress.cancel()

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedback.showNoTextFound(in: source, displayID: displayID)
            return .noTextFound
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback.showCopied(text: text, displayID: displayID)
        return .copied(text)
    }

    /// Capture on Timer counts down first, then captures the whole display
    /// with no selection UI, so menus, hover states, and tooltips opened
    /// during the countdown are still on screen for the shot. It uses its own
    /// delay and never the self-timer, so the two never stack.
    @discardableResult
    private func performCaptureOnTimer() async -> URL? {
        guard AppPermissionCenter.shared.ensureScreenRecording() else { return nil }
        guard await CaptureCountdownPresenter.shared.runIfNeeded(
            seconds: ScreendropPreferences.timedCaptureDelaySeconds,
            displayID: ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        ) else { return nil }

        // Resolved after the countdown: the pointer is on whatever the user
        // just opened, which may be on a different display by now.
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        PreviewWindowPlacement.shared.setTargetDisplayID(displayID)
        guard let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID) else { return nil }
        return finishCapture(url: url, displayID: displayID)
    }

    func recordFullscreen(_ display: SCDisplay) {
        Task {
            guard await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: display.displayID
            ) else { return }
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .fullscreen(display)))
        }
    }

    func recordWindow(_ window: SCWindow) {
        Task {
            let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            guard await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: displayID
            ) else { return }
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .window(window)))
        }
    }

    func recordArea(_ display: SCDisplay) {
        RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
            guard let rect else { return }
            Task {
                guard await CaptureCountdownPresenter.shared.runIfNeeded(
                    seconds: ScreendropPreferences.recordingStartDelaySeconds,
                    displayID: display.displayID
                ) else { return }
                ScreenRecordingManager.shared.startRecording(
                    source: ScreenRecordingSource(kind: .area(display: display, rect: rect))
                )
            }
        }
    }
    
    // MARK: - Preview

    @discardableResult
    @MainActor
    private func finishCapture(url: URL, displayID: CGDirectDisplayID?) -> URL {
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        return showPreview(url: url, displayID: displayID)
    }

    @discardableResult
    private func showPreview(url: URL, displayID: CGDirectDisplayID?) -> URL {
        guard let onShowPreview else {
            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url, movingSource: true)
            ScreenshotPreviewStack.shared.add(url: historyURL, displayID: displayID)
            return historyURL
        }

        return onShowPreview(url, displayID)
    }
}

@MainActor
private enum CaptureFeedbackSound {
    private static let sound: NSSound? = {
        let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
        return NSSound(contentsOf: url, byReference: true)
    }()

    static func play() {
        guard let sound else { return }

        sound.stop()
        sound.currentTime = 0
        sound.play()
    }
}
