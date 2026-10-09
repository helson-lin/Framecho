//
//  RecordingStudioModel.swift
//  Framecho
//
//  View-model for the recording studio: loads a recording session (screen
//  movie + optional camera movie + pointer-capture sidecar), owns the style
//  settings and zoom cues, and keeps the screen and camera players in
//  sync. Layout math lives in RecordingStudioLayout so the live preview and
//  the exporter compose frames identically.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation

enum RecordingTranscriptionState: Equatable {
    case idle
    case transcribing
    case failed(String)

    var isTranscribing: Bool {
        self == .transcribing
    }
}

enum CaptionCleanupKind: Equatable {
    case fillers
    case corrections
}

/// AI caption cleanup: finding fillers or fixes, then the review before
/// applying.
enum CaptionCleanupState: Equatable {
    case idle
    case running(completed: Int, total: Int)
    /// Suggestions are waiting for review.
    case reviewing
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum RecordingStudioExportState: Equatable {
    case idle
    case exporting(progress: Double)
    case finished(URL)
    case failed(String)

    var isExporting: Bool {
        if case .exporting = self { return true }
        return false
    }
}

/// Share-to-cloud pipeline: render the current edits, upload, copy link.
enum RecordingStudioShareState: Equatable {
    case idle
    case rendering(progress: Double)
    case uploading
    case finished(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .rendering, .uploading: true
        default: false
        }
    }
}

@MainActor
@Observable
final class RecordingStudioModel {
    let sessionURL: URL
    /// Loaded for an agent rather than a window (AgentStudioModels). It
    /// saves after every edit, so it never writes a draft - which could
    /// otherwise clobber the draft of a Studio window opened on the same
    /// project meanwhile - and it never counts as an open editor.
    let isHeadless: Bool
    private(set) var session: RecordingSession?
    private(set) var manifest: CaptureManifest?
    private(set) var pointerCapture = PointerCaptureFile()
    private(set) var recordedPressTimes: [TimeInterval] = []
    private(set) var sourceDuration: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var videoSize = CGSize(width: 1920, height: 1080)
    private(set) var hasCameraVideo = false
    private(set) var hasRecordedAudio = false
    private(set) var cameraOffset: TimeInterval = 0
    private(set) var isLoaded = false
    private(set) var loadError: String?

    let screenPlayer = AVPlayer()
    let cameraPlayer = AVPlayer()

    var style = RecordingStudioStyle(background: RecordingStudioDefaults.background) {
        didSet {
            if isLoaded, oldValue.background != style.background {
                RecordingStudioDefaults.background = style.background
            }
            scheduleProjectSave()
        }
    }
    /// The style preset currently applied, so the Studio's preset bar can
    /// show its name and detect whether the user has since edited away from
    /// it. Not persisted in the project file: reapplied by content match.
    var appliedStylePresetID: RecordingStudioStylePreset.ID?
    var zoomEnabled = true {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
        }
    }
    var exportSettings = VideoCompressionSettings() {
        didSet { scheduleProjectSave() }
    }
    /// Studio-side input feedback: both are reconstructed from the sidecar,
    /// so they can be toggled after the fact without touching the footage.
    var showsClickEffects = true {
        didSet { scheduleProjectSave() }
    }
    var showsKeystrokes = true {
        didSet { scheduleProjectSave() }
    }
    var keystrokePlacement: RecordingKeystrokePlacement = .bottomCenter {
        didSet { scheduleProjectSave() }
    }
    var showsSubtitles = true {
        didSet { scheduleProjectSave() }
    }
    var subtitleStyle = SubtitleBarStyle() {
        didSet { scheduleProjectSave() }
    }
    /// Output aspect for Export/Share. Anything but `.original` crops the
    /// render with a virtual camera that follows the pointer and zooms;
    /// the Studio preview shows the same crop live.
    var exportAspect: ExportAspectPreset = .original {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
        }
    }
    /// Fill crops with the follow camera; Fit shows the whole recording
    /// framed on the background.
    var exportAspectMode: ExportAspectContentMode = .fill {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
        }
    }
    /// Non-destructive crop of the screen-video source. The Studio background,
    /// camera bubble and captions remain in canvas space around the reshaped
    /// video card.
    var videoCropRect = CropRectEditor.unit {
        didSet { scheduleProjectSave() }
    }
    private(set) var isCroppingVideo = false
    var workingVideoCropRect = CropRectEditor.unit
    var videoCropAspect: CropAspectRatio = .freeform
    /// The preview's copy of the reframe camera, kept current with every
    /// edit that would change the exported crop.
    private(set) var previewReframe: ReframeTrack?
    private var reframeFocusTimeline: PointerTimeline?
    private var reframeFocusResolved = false
    private(set) var subtitleCues: [RecordingSubtitleCue] = []
    private(set) var subtitleTimeline = SubtitleTimeline.empty
    /// Word-level timing behind the cues; empty for projects transcribed
    /// before transcript editing shipped (cues only).
    private(set) var transcriptWords: [RecordingTranscriptWord] = []
    /// Word-timing lookup for karaoke captions; rebuilt with the cues.
    private(set) var karaokeTimeline = KaraokeTimeline.empty
    /// Word under the playhead, updated only on word boundaries so the
    /// transcript view isn't invalidated on every 20 ms playback tick.
    private(set) var activeTranscriptWordIndex: Int?
    var transcriptionState = RecordingTranscriptionState.idle
    private(set) var captionCleanupState = CaptionCleanupState.idle
    /// What the current cleanup looks for.
    private(set) var captionCleanupKind = CaptionCleanupKind.fillers
    /// Fillers found by the last cleanup, awaiting review.
    private(set) var fillerSuggestions: [CaptionFillerSuggestion] = []
    /// Fixes found by the last proofreading, awaiting review.
    private(set) var correctionSuggestions: [CaptionCorrectionSuggestion] = []
    /// Why the last cleanup fell back to rules alone, shown with the review.
    private(set) var captionCleanupNotice: String?
    private(set) var zoomCues: [ZoomCue] = []
    /// Images over the video, in stacking order, and where they fall on the
    /// edited timeline.
    private(set) var imageOverlays: [RecordingImageOverlay] = []
    private(set) var imageOverlayTimeline = RecordingImageOverlayTimeline.empty
    /// Preview-sized images for the canvas, keyed by asset file name.
    private(set) var imageOverlayPreviews: [String: CGImage] = [:]
    /// The image picked on the timeline or canvas.
    var selectedImageOverlayID: UUID? {
        didSet {
            guard selectedImageOverlayID != nil else { return }
            selectedCueID = nil
            selectedClipID = nil
            selectedMotionCueID = nil
            selectedSubtitleCueID = nil
        }
    }
    private var imageOverlayEditSnapshot: [RecordingImageOverlay]?
    private var imageOverlayEditCommitTask: Task<Void, Never>?
    private(set) var viewportTimeline = ViewportTimeline.identity
    /// 3D card pose and motion cues. Edited through the motion methods so
    /// every change is undoable and rebuilds the editor-time timeline.
    private(set) var motion = RecordingMotionSettings.disabled
    private(set) var motionTimeline = RecordingMotionTimeline.disabled
    var selectedMotionCueID: UUID?
    /// The pose being adjusted directly on the canvas, if any.
    private(set) var poseAdjustmentTarget: RecordingPoseAdjustmentTarget?
    private(set) var pointerTimeline = PointerTimeline.empty
    private(set) var keystrokeTimeline = KeystrokeCaptionTimeline.empty
    var selectedCueID: UUID? {
        didSet {
            guard selectedCueID != nil else { return }
            selectedMotionCueID = nil
            selectedSubtitleCueID = nil
            selectedImageOverlayID = nil
            // Zoom editing works on the flat picture; a pose adjustment left
            // open would hide its canvas target.
            endPoseAdjustment()
        }
    }
    private(set) var clipTimeline = RecordingClipTimeline(segments: [])
    var selectedClipID: UUID? {
        didSet {
            guard selectedClipID != nil else { return }
            selectedMotionCueID = nil
            selectedSubtitleCueID = nil
            selectedImageOverlayID = nil
            endPoseAdjustment()
        }
    }
    /// The caption picked on the timeline, for moving, trimming and
    /// deleting it.
    var selectedSubtitleCueID: UUID? {
        didSet {
            guard selectedSubtitleCueID != nil else { return }
            selectedCueID = nil
            selectedClipID = nil
            selectedMotionCueID = nil
            selectedImageOverlayID = nil
        }
    }
    var timelineHoverTime: TimeInterval?
    /// Storyboard tiles for the clip lane, sampled on demand at whatever
    /// density the lane's current zoom needs.
    let timelineThumbnails = RecordingTimelineThumbnailStore()
    /// Peaks of the recorded audio for the timeline's audio lane; nil until
    /// decoded, and for recordings without sound.
    private(set) var audioWaveform: RecordingAudioWaveform?
    private var audioWaveformTask: Task<Void, Never>?

    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0
    /// Live scrub-preview time while the pointer hovers the trim strip
    /// without committing to a new playhead position, matching Final
    /// Cut/iMovie skimming. `nil` shows the real playhead again.
    var hoverPreviewTime: TimeInterval? {
        didSet {
            guard isLoaded, duration > 0, !isPlaying else { return }
            movePlayers(to: hoverPreviewTime ?? currentTime)
        }
    }
    var exportState: RecordingStudioExportState = .idle
    var audioExportState: RecordingStudioExportState = .idle
    var shareState: RecordingStudioShareState = .idle
    /// Upload identity while sharing, so the UI can read the uploader's
    /// live progress and the history card mirrors the state.
    private(set) var shareItemID: UUID?

    /// Gain shared by playback and video/audio export; 1 preserves the source.
    var audioVolume: CGFloat = 1 {
        didSet {
            updatePlaybackVolume()
            scheduleProjectSave()
        }
    }

    var normalizesAudioLoudness = false {
        didSet {
            guard normalizesAudioLoudness != oldValue else { return }
            if !isApplyingDocument { refreshAudioNormalization() }
            scheduleProjectSave()
        }
    }
    private(set) var isAnalyzingAudioLoudness = false
    private(set) var audioNormalizationError: String?
    private var audioNormalization: RecordingAudioNormalization.Measurement?
    private var audioNormalizationTask: Task<Void, Never>?

    private func refreshAudioNormalization() {
        audioNormalizationTask?.cancel()
        audioNormalizationTask = nil
        audioNormalization = nil
        audioNormalizationError = nil
        isAnalyzingAudioLoudness = false
        updatePlaybackVolume()
        guard normalizesAudioLoudness, hasAudio,
              let item = screenPlayer.currentItem else { return }
        let tracks = item.asset.tracks(withMediaType: .audio)
            .filter { !playbackMusicTrackIDs.contains($0.trackID) }
        guard !tracks.isEmpty else { return }
        let musicIDs = playbackMusicTrackIDs
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        isAnalyzingAudioLoudness = true
        audioNormalizationTask = Task { [weak self] in
            do {
                let measurement = try await RecordingAudioNormalization.measure(
                    asset: item.asset, excludingTrackIDs: musicIDs, timeRange: range
                )
                guard let self, !Task.isCancelled, !self.isTornDown,
                      self.screenPlayer.currentItem === item else { return }
                self.audioNormalization = measurement
                self.isAnalyzingAudioLoudness = false
                self.audioNormalizationTask = nil
                self.updatePlaybackVolume()
            } catch {
                guard let self, !Task.isCancelled, !self.isTornDown,
                      self.screenPlayer.currentItem === item else { return }
                self.audioNormalizationError = error.localizedDescription
                self.isAnalyzingAudioLoudness = false
                self.audioNormalizationTask = nil
            }
        }
    }

    private func updatePlaybackVolume() {
        guard let item = screenPlayer.currentItem else { return }
        let tracks = item.asset.tracks(withMediaType: .audio)
        let musicIDs = playbackMusicTrackIDs
        let musicTracks = musicIDs.compactMap { id in tracks.first { $0.trackID == id } }
        item.audioMix = BackgroundMusicMixer.makeMix(
            narrationTracks: tracks.filter { !musicIDs.contains($0.trackID) },
            narrationVolume: Double(audioVolume),
            musicTracks: musicTracks,
            plan: loadedBackgroundMusic.flatMap(backgroundMusicPlan(for:)),
            normalization: normalizesAudioLoudness ? audioNormalization : nil
        )
    }

    /// Format the audio-only export writes.
    var audioExportFormat: RecordingAudioFormat = .m4a {
        didSet { scheduleProjectSave() }
    }
    /// The soundtrack standing in for the recording's own audio, resolved
    /// so both playback and export can use it without reloading tracks.
    private(set) var replacementAudio: RecordingReplacementAudio?
    /// Why the last import was rejected, shown next to the Replace control.
    private(set) var replacementAudioError: String?
    /// Library music laid under the soundtrack; nil when none is chosen.
    private(set) var backgroundMusic: RecordingBackgroundMusic?
    /// The chosen track, once its file is on disk and readable.
    private(set) var loadedBackgroundMusic: LoadedBackgroundMusic?
    private(set) var isLoadingBackgroundMusic = false
    private(set) var backgroundMusicError: String?
    private var backgroundMusicTask: Task<Void, Never>?
    /// The music's tracks in the current player item, one per lane, kept
    /// apart from the narration so each gets its own level.
    private var playbackMusicTrackIDs: [CMPersistentTrackID] = []

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var exportTask: Task<Void, Never>?
    private var audioExportTask: Task<Void, Never>?
    private var replacementAudioTask: Task<Void, Never>?
    /// The screen movie's video track, kept from load so the player item
    /// can be rebuilt synchronously when an imported soundtrack means the
    /// composition has to be assembled track by track.
    private var screenVideoTrack: AVAssetTrack?
    private var shareTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var captionCleanupTask: Task<Void, Never>?
    private var projectSaveTask: Task<Void, Never>?
    private var screenAsset: AVURLAsset?
    private var isTornDown = false
    private var isLoading = false
    private var wallpaperCacheLease: BoundedCGImageCache.Lease?
    private let editUndoManager = UndoManager()
    private(set) var undoRevision = 0
    private var zoomEditSnapshot: [ZoomCue]?
    private var motionEditSnapshot: RecordingMotionSettings?
    /// The captions before a timeline drag, so the whole drag undoes as one.
    private var subtitleEditSnapshot: [RecordingSubtitleCue]?
    private var motionEditCommitTask: Task<Void, Never>?
    /// The document as of the last explicit save. Everything the user does
    /// after that lives in memory and in the autosaved draft until they save
    /// again, which is what makes the close prompt meaningful.
    private var lastSavedDocument: RecordingEditDocument?
    /// Set while a stored document is being applied to the model, so the
    /// resulting property writes don't register as user edits.
    private var isApplyingDocument = false
    /// Whether the editor holds edits that have not been committed with an
    /// explicit save. Stored rather than derived: the title bar and the Save
    /// button read it on every body evaluation, and rebuilding the whole
    /// document to compare it there would cost real time while dragging.
    private(set) var hasUnsavedChanges = false
    private(set) var saveFlash = false

    /// Accepts either a recording session folder or a bare video file (so
    /// history items and old recordings still open, just without events).
    init(url: URL, isHeadless: Bool = false) {
        sessionURL = url
        self.isHeadless = isHeadless
        if RecordingSession.isSessionDirectory(url) {
            session = RecordingSession(directoryURL: url)
        } else {
            session = nil
        }
    }

    var screenURL: URL {
        session?.screenURL ?? sessionURL
    }

    /// False for a bare movie opened from disk: there is no project package
    /// behind it, so there is nothing to save into.
    var isProject: Bool { session != nil }

    /// What the window title, share sheet, and Projects browser call this
    /// project. A bare movie falls back to its file name.
    var projectDisplayName: String {
        session?.displayName ?? sessionURL.deletingPathExtension().lastPathComponent
    }

    func load() async {
        guard !isLoaded, !isLoading, !isTornDown, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        wallpaperCacheLease = AnnotationBackgroundRenderer.beginWallpaperUse()

        if let session {
            manifest = session.loadCaptureManifest()
            pointerCapture = session.loadPointerCapture() ?? PointerCaptureFile()
        }

        let asset = AVURLAsset(url: screenURL)
        screenAsset = asset
        do {
            let (durationTime, tracks) = try await asset.load(.duration, .tracks)
            guard !isTornDown, !Task.isCancelled else { return }
            sourceDuration = durationTime.seconds
            duration = sourceDuration
            if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                screenVideoTrack = videoTrack
                let naturalSize = try await videoTrack.load(.naturalSize)
                guard !isTornDown, !Task.isCancelled else { return }
                if naturalSize.width > 0, naturalSize.height > 0 {
                    videoSize = naturalSize
                }
            }
            hasRecordedAudio = tracks.contains { $0.mediaType == .audio }
        } catch {
            guard !isTornDown, !Task.isCancelled else { return }
            loadError = String(localized: "Could not open the recording: \(error.localizedDescription)")
            return
        }

        if session != nil {
            let pointScale = max(manifest?.pixelScale ?? 1, 1)
            let stream = PointerStreamSanitizer.sanitize(
                pointerCapture,
                options: PointerSanitizeOptions(
                    recordingSizeInPoints: CGSize(
                        width: videoSize.width / CGFloat(pointScale),
                        height: videoSize.height / CGFloat(pointScale)
                    )
                )
            )
            pointerCapture = stream.sanitizedCapture
            recordedPressTimes = pointerCapture.presses
                .filter { $0.phase == .down }
                .map(\.time)
            keystrokeTimeline = KeystrokeCaptionTimeline(events: pointerCapture.keystrokes)
        }

        if let session, session.hasCamera {
            hasCameraVideo = true
            cameraOffset = manifest?.cameraLeadIn ?? 0
            cameraPlayer.replaceCurrentItem(with: AVPlayerItem(url: session.cameraURL))
            cameraPlayer.actionAtItemEnd = .pause
            cameraPlayer.isMuted = true
        } else {
            style.camera.isVisible = false
        }

        lastSavedDocument = session?.loadEditDocument()
        if let session, !isHeadless {
            // Nothing can undo back to an image a stored document no longer
            // uses, so its file can go. A headless model skips this: a
            // Studio window may hold undo history that still needs it.
            let referenced = [lastSavedDocument, session.effectiveEditDocument()]
                .compactMap { $0?.imageOverlays }
                .flatMap { $0.map(\.fileName) }
            RecordingStudioAssets.removeUnused(in: session.directoryURL, keeping: Set(referenced))
        }
        // A draft that outlived its editor means the last session ended
        // without a save - a crash, a force quit, or a Studio window that is
        // still open elsewhere. Reopen on the draft so nothing is lost; the
        // project simply opens dirty.
        let document = session?.effectiveEditDocument()
        // Sessions recorded before the toggle moved into Studio stored the
        // choice in the manifest; honor it as the default.
        showsClickEffects = manifest?.pressEffectsEnabled ?? true
        // A brand new recording has no project yet, so it also starts from
        // the remembered export choice.
        exportSettings = RecordingExportPreferences.lastSettings
        if let document {
            applyDocumentSettings(document)
        } else if session == nil {
            // Legacy bare movies use the same editor, but open visually
            // unchanged until the user explicitly adds styling.
            style = RecordingStudioStyle(
                background: .none,
                padding: 0,
                cornerRadius: 0,
                shadow: 0,
                camera: RecordingCameraBubbleSettings(isVisible: false)
            )
            zoomEnabled = false
        } else {
            zoomCues = ZoomCueSynthesizer.cues(from: pointerCapture, duration: sourceDuration)
            // Few people go looking for this switch, so new recordings start
            // with it on. Saved projects keep what they stored - one from
            // before the setting existed stays off, so it exports unchanged.
            normalizesAudioLoudness = true
            if let defaultPreset = RecordingStudioStylePresetStore.shared.activePreset {
                style = defaultPreset.value
                appliedStylePresetID = defaultPreset.id
            }
            if let appearance = manifest?.cameraAppearance {
                style.camera.appearance = appearance
            }
        }

        clipTimeline = Self.clipTimeline(for: document, sourceDuration: sourceDuration)
        duration = clipTimeline.duration
        // Nothing is selected until the user picks a clip; an unsplit
        // recording would otherwise open wrapped in selection chrome.
        selectedClipID = nil

        // Resolve the imported soundtrack before the first player item is
        // built, so the editor opens already playing what it will export.
        if let session, let fileName = document?.replacementAudioFileName {
            let url = session.directoryURL.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                let loadedAudio = await RecordingReplacementAudio.load(
                    url: url,
                    displayName: document?.replacementAudioDisplayName ?? fileName
                )
                guard !isTornDown, !Task.isCancelled else { return }
                replacementAudio = loadedAudio
            }
        }
        await loadCachedBackgroundMusic()
        guard !isTornDown, !Task.isCancelled else { return }

        do {
            try rebuildScreenPlayerItem(preserving: 0)
        } catch {
            loadError = String(localized: "Could not prepare the recording timeline: \(error.localizedDescription)")
            return
        }
        rebuildPointerTimeline()
        rebuildViewportTimeline()
        rebuildMotionTimeline()
        rebuildImageOverlayTimeline()
        installObservers()
        isLoaded = true
        rebuildPreviewReframe()
        if !isHeadless {
            loadTimelineThumbnails()
        }
        // A track that isn't cached yet downloads in the background and
        // joins playback when it arrives.
        if backgroundMusic != nil, loadedBackgroundMusic == nil {
            resolveBackgroundMusic()
        }

        if let session {
            if session.hasUnsavedDraft {
                // Reopened on a draft that outlived its editor.
                hasUnsavedChanges = true
            } else if lastSavedDocument == nil {
                // A recording that has never been saved is unsaved work by
                // definition, which is what makes the close prompt offer to
                // throw the whole thing away.
                hasUnsavedChanges = true
            } else {
                hasUnsavedChanges = false
                // Adopt the loaded document in its normalized in-memory form
                // as the baseline. Defaults filled in during load (an export
                // preset an older project never stored, clips normalized to
                // the real duration) would otherwise read as edits.
                lastSavedDocument = currentDocument()
            }
            if !isHeadless {
                session.updateProjectMetadata { $0.lastOpenedAt = Date() }
            }
        }
        if !isHeadless {
            StudioProjectRegistry.shared.register(self)
        }
    }

    /// Copies a stored project onto the model. Shared by the initial load and
    /// by discarding changes, so both routes can never drift apart.
    /// The stored cuts, or the trim of projects saved before cuts shipped.
    private static func clipTimeline(
        for document: RecordingEditDocument?,
        sourceDuration: TimeInterval
    ) -> RecordingClipTimeline {
        if let storedClips = document?.clips, !storedClips.isEmpty {
            return RecordingClipTimeline(segments: storedClips)
                .normalized(to: sourceDuration)
        }
        return .legacyTrim(
            start: document?.trimStart,
            end: document?.trimEnd,
            sourceDuration: sourceDuration
        )
    }

    private func applyDocumentSettings(_ document: RecordingEditDocument) {
        isApplyingDocument = true
        defer { isApplyingDocument = false }

        style = document.style.value
        backgroundMusic = document.backgroundMusic
        imageOverlays = document.imageOverlays ?? []
        if let selectedImageOverlayID, !imageOverlays.contains(where: { $0.id == selectedImageOverlayID }) {
            self.selectedImageOverlayID = nil
        }
        loadImageOverlayPreviews()
        zoomEnabled = document.zoomEnabled
        zoomCues = document.zoomCues
        motion = Self.editableMotion(document.motion)
        selectedMotionCueID = nil
        // A project that never chose its own settings inherits whatever
        // was picked last, so "export as MP4" sticks across recordings.
        exportSettings = document.exportSettings ?? RecordingExportPreferences.lastSettings
        if document.exportSettings == nil {
            // Old projects without export settings may inherit quality/codec
            // preferences, but keep their original cadence and blur policy.
            exportSettings.frameRate = nil
            exportSettings.motionBlurEnabled = nil
        }
        showsClickEffects = document.showsClickEffects ?? showsClickEffects
        showsKeystrokes = document.showsKeystrokes ?? true
        keystrokePlacement = document.keystrokePlacement ?? .bottomCenter
        showsSubtitles = document.showsSubtitles ?? true
        transcriptWords = document.subtitleWords ?? []
        // Captions saved with punctuation left dangling by a hidden filler
        // ("，包括…") read tidy again; typed captions are untouched.
        subtitleCues = TranscriptCaptionText.tidied(
            document.subtitleCues ?? [],
            words: transcriptWords,
            isIncluded: { [words = transcriptWords, timeline = Self.clipTimeline(for: document, sourceDuration: sourceDuration)] in
                timeline.editorTime(forSourceTime: words[$0].midpoint) != nil
            }
        )
        subtitleTimeline = SubtitleTimeline(cues: subtitleCues)
        karaokeTimeline = KaraokeTimeline(cues: subtitleCues, words: transcriptWords)
        subtitleStyle = document.subtitleStyle
        exportAspect = document.exportAspectPreset
        exportAspectMode = document.exportAspectContentMode
        videoCropRect = document.normalizedVideoCropRect
        audioExportFormat = document.audioExportFormatValue
        audioVolume = CGFloat(RecordingAudioGain.normalized(document.audioVolume ?? 1))
        normalizesAudioLoudness = document.normalizesAudioLoudness ?? false
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        // Persist only a fully loaded document, before releasing its data.
        if isLoaded { writeDraftNow() }
        isLoaded = false
        StudioProjectRegistry.shared.unregister(self)
        exportTask?.cancel()
        audioExportTask?.cancel()
        replacementAudioTask?.cancel()
        audioWaveformTask?.cancel()
        audioNormalizationTask?.cancel()
        audioNormalizationTask = nil
        audioWaveformTask = nil
        audioWaveform = nil
        cancelShare()
        transcriptionTask?.cancel()
        discardCaptionCleanup()
        backgroundMusicTask?.cancel()
        backgroundMusicTask = nil
        BackgroundMusicStore.shared.stopPreview()
        projectSaveTask?.cancel()
        exportTask = nil
        audioExportTask = nil
        replacementAudioTask = nil
        shareTask = nil
        transcriptionTask = nil
        projectSaveTask = nil
        timelineThumbnails.releaseResources()
        pause()
        if let timeObserver {
            screenPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        screenPlayer.replaceCurrentItem(with: nil)
        cameraPlayer.replaceCurrentItem(with: nil)
        screenAsset?.cancelLoading()
        screenAsset = nil
        screenVideoTrack = nil
        replacementAudio = nil
        editUndoManager.removeAllActions()
        zoomEditSnapshot = nil
        lastSavedDocument = nil
        pointerCapture = PointerCaptureFile()
        pointerTimeline = .empty
        keystrokeTimeline = .empty
        viewportTimeline = .identity
        previewReframe = nil
        reframeFocusTimeline = nil
        recordedPressTimes.removeAll()
        zoomCues.removeAll()
        imageOverlayEditCommitTask?.cancel()
        imageOverlayEditCommitTask = nil
        imageOverlayEditSnapshot = nil
        imageOverlays.removeAll()
        imageOverlayTimeline = .empty
        imageOverlayPreviews.removeAll()
        subtitleCues.removeAll()
        transcriptWords.removeAll()
        subtitleTimeline = .empty
        karaokeTimeline = .empty
        clipTimeline = RecordingClipTimeline(segments: [])
        wallpaperCacheLease = nil
    }

    // MARK: - Style presets

    func applyStylePreset(_ preset: RecordingStudioStylePreset) {
        style = preset.value
        appliedStylePresetID = preset.id
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !isPlaying else { return }
        endPoseAdjustment()
        if hoverPreviewTime != nil {
            hoverPreviewTime = nil
        }
        guard duration >= RecordingClipSegment.minimumDuration else { return }
        if currentTime < 0 || currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        isPlaying = true
        screenPlayer.play()
        syncCameraPlayback()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        screenPlayer.pause()
        cameraPlayer.pause()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), max(duration, 0))
        currentTime = clamped
        updateActiveTranscriptWord()
        movePlayers(to: clamped)
        if isPlaying {
            syncCameraPlayback()
        }
    }

    /// Moves both players to a source time without touching `currentTime`,
    /// so hover skimming can preview a frame and cleanly hand back to the
    /// real playhead position afterward.
    private func movePlayers(to time: TimeInterval) {
        let editorTime = min(max(time, 0), max(duration, 0))
        let sourceTime = clipTimeline.sourceTime(at: editorTime)
        let target = CMTime(seconds: editorTime, preferredTimescale: 600)
        screenPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if hasCameraVideo {
            if sourceTime >= cameraOffset {
                let cameraTime = CMTime(seconds: max(0, sourceTime - cameraOffset), preferredTimescale: 600)
                cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                cameraPlayer.pause()
                cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    /// Time the preview canvas should render right now.
    var displayTime: TimeInterval {
        if isPlaying {
            let time = screenPlayer.currentTime().seconds
            return time.isFinite ? time : currentTime
        }
        return hoverPreviewTime ?? currentTime
    }

    private func installObservers() {
        timeObserver = screenPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.02, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isPlaying {
                    let seconds = time.seconds
                    if seconds >= self.duration - 0.001 {
                        self.pause()
                        self.currentTime = self.duration
                        self.screenPlayer.seek(
                            to: CMTime(seconds: self.duration, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                        return
                    }
                    self.currentTime = seconds
                    self.updateActiveTranscriptWord()
                    self.correctCameraDriftIfNeeded()
                }
            }
        }

        installEndObserver()
    }

    private func installEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: screenPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.cameraPlayer.pause()
                self.currentTime = self.duration
            }
        }
    }

    // MARK: - Clips

    var canUndo: Bool {
        _ = undoRevision
        return editUndoManager.canUndo
    }

    var canRedo: Bool {
        _ = undoRevision
        return editUndoManager.canRedo
    }

    var selectedClip: RecordingClipSegment? {
        guard let selectedClipID else { return nil }
        return clipTimeline.segments.first { $0.id == selectedClipID }
    }

    var hasClipEdits: Bool {
        !clipTimeline.isUnedited(sourceDuration: sourceDuration)
    }

    var canDeleteSelectedClip: Bool {
        selectedClipID != nil && clipTimeline.segments.count > 1
    }

    func selectClip(id: UUID) {
        guard clipTimeline.segments.contains(where: { $0.id == id }) else { return }
        selectedClipID = id
        selectedCueID = nil
        selectedMotionCueID = nil
    }

    func selectZoomCue(id: UUID) {
        guard zoomCues.contains(where: { $0.id == id }) else { return }
        selectedCueID = id
        selectedClipID = nil
        selectedMotionCueID = nil
    }

    func selectMotionCue(id: UUID) {
        guard motion.cues.contains(where: { $0.id == id }) else { return }
        // While adjusting on the canvas, picking a motion moves the
        // adjustment to that motion's target, so the canvas shows the pose
        // the selection will play rather than the flat base.
        if let target = poseAdjustmentTarget, target != .cue(id) {
            commitPendingMotionEdit()
            poseAdjustmentTarget = .cue(id)
        }
        selectedMotionCueID = id
        selectedCueID = nil
        selectedClipID = nil
        selectedSubtitleCueID = nil
        selectedImageOverlayID = nil
    }

    func undo() {
        commitPendingMotionEdit()
        commitPendingImageOverlayEdit()
        guard editUndoManager.canUndo else { return }
        pause()
        editUndoManager.undo()
        undoRevision &+= 1
    }

    func redo() {
        commitPendingMotionEdit()
        commitPendingImageOverlayEdit()
        guard editUndoManager.canRedo else { return }
        pause()
        editUndoManager.redo()
        undoRevision &+= 1
    }

    func splitClip(at editorTime: TimeInterval) {
        guard let result = clipTimeline.split(at: editorTime) else { return }
        applyClipTimeline(
            result.timeline,
            selectedID: result.selectedID,
            playheadTime: min(max(editorTime, 0), duration),
            actionName: String(localized: "Split Clip")
        )
    }

    func splitClipAtHover() {
        guard let timelineHoverTime else { return }
        splitClip(at: timelineHoverTime)
    }

    func deleteSelectedClip() {
        guard let selectedClipID,
              let deletedRange = clipTimeline.editorRange(for: selectedClipID),
              let next = clipTimeline.deleting(segmentID: selectedClipID) else {
            return
        }
        let seekTime = min(deletedRange.lowerBound, next.duration)
        let nextSelection = next.location(at: seekTime)?.segmentID
            ?? next.segments.last?.id
        applyClipTimeline(
            next,
            selectedID: nextSelection,
            playheadTime: seekTime,
            actionName: String(localized: "Delete Clip")
        )
    }

    func trimClip(_ replacement: RecordingClipSegment) {
        let next = clipTimeline.replacing(replacement)
        guard next != clipTimeline else { return }
        let editorTime = next.editorRange(for: replacement.id)?.lowerBound ?? currentTime
        applyClipTimeline(
            next,
            selectedID: replacement.id,
            playheadTime: min(currentTime, next.duration),
            actionName: String(localized: "Trim Clip"),
            hoverTime: editorTime
        )
    }

    func setClipSpeed(_ speed: Double, forClipID id: UUID) {
        guard let segment = clipTimeline.segments.first(where: { $0.id == id }) else { return }
        let clamped = min(max(speed, RecordingClipSegment.minimumSpeed), RecordingClipSegment.maximumSpeed)
        guard abs(segment.speed - clamped) > 0.000_001 else { return }
        var replacement = segment
        replacement.speed = clamped
        let next = clipTimeline.replacing(replacement)
        applyClipTimeline(
            next,
            selectedID: id,
            playheadTime: min(currentTime, next.duration),
            actionName: String(localized: "Change Clip Speed")
        )
    }

    /// Plays an editor-time range at `speed`, splitting clips at its edges.
    func setSpeed(_ speed: Double, forEditorRange range: ClosedRange<TimeInterval>) {
        let next = clipTimeline.settingSpeed(speed, forEditorRange: range)
        applyClipTimeline(
            next,
            selectedID: selectedClipID,
            playheadTime: min(range.lowerBound, next.duration),
            actionName: String(localized: "Change Clip Speed")
        )
    }

    func resetClips() {
        let full = RecordingClipTimeline.full(sourceDuration: sourceDuration)
        guard full != clipTimeline else { return }
        applyClipTimeline(
            full,
            selectedID: full.segments.first?.id,
            playheadTime: 0,
            actionName: String(localized: "Reset Clips")
        )
    }

    private func applyClipTimeline(
        _ requestedTimeline: RecordingClipTimeline,
        selectedID: UUID?,
        playheadTime: TimeInterval,
        actionName: String,
        hoverTime: TimeInterval? = nil
    ) {
        let next = requestedTimeline.normalized(to: sourceDuration)
        guard !next.segments.isEmpty, next != clipTimeline else { return }

        let previousTimeline = clipTimeline
        let previousSelection = selectedClipID
        let previousTime = currentTime
        registerUndo(actionName) { target in
            target.applyClipTimeline(
                previousTimeline,
                selectedID: previousSelection,
                playheadTime: previousTime,
                actionName: actionName
            )
        }

        pause()
        hoverPreviewTime = nil
        timelineHoverTime = nil
        clipTimeline = next
        duration = next.duration
        selectedClipID = selectedID.flatMap { id in
            next.segments.contains(where: { $0.id == id }) ? id : nil
        } ?? next.segments.first?.id
        // Both motion timelines integrate along editor time, so a cut, trim,
        // or speed change invalidates them even when their source data did not
        // change.
        rebuildPointerTimeline()
        rebuildViewportTimeline()
        rebuildMotionTimeline()
        rebuildImageOverlayTimeline()

        do {
            try rebuildScreenPlayerItem(preserving: min(max(playheadTime, 0), duration))
            if let hoverTime {
                hoverPreviewTime = min(max(hoverTime, 0), duration)
            }
        } catch {
            loadError = String(localized: "Could not update the recording timeline: \(error.localizedDescription)")
        }
        updateActiveTranscriptWord()
        scheduleProjectSave()
    }

    private func rebuildScreenPlayerItem(preserving editorTime: TimeInterval) throws {
        guard let screenAsset else { return }
        let musicMix = loadedBackgroundMusic.flatMap { music in
            backgroundMusicPlan(for: music).map { (music: music, plan: $0) }
        }
        let playbackAsset: AVAsset
        if let replacementAudio, let screenVideoTrack {
            playbackAsset = try RecordingCompositionBuilder.makeAsset(
                videoTrack: screenVideoTrack,
                timeline: clipTimeline,
                sourceDuration: sourceDuration,
                replacementAudio: replacementAudio
            )
        } else {
            playbackAsset = try RecordingCompositionBuilder.makeAsset(
                from: screenAsset,
                timeline: clipTimeline,
                sourceDuration: sourceDuration,
                forcesComposition: musicMix != nil
            )
        }

        // Music that can't be laid in never costs the recording its
        // playback: the item plays without it and the inspector says why.
        playbackMusicTrackIDs = []
        if let musicMix, let composition = playbackAsset as? AVMutableComposition {
            do {
                playbackMusicTrackIDs = try BackgroundMusicMixer.addingMusic(
                    from: musicMix.music.track,
                    sourceRange: musicMix.music.timeRange,
                    plan: musicMix.plan,
                    to: composition
                ).map(\.trackID)
            } catch {
                backgroundMusicError = String(localized: "The music couldn't be added: \(error.localizedDescription)")
            }
        }

        screenPlayer.replaceCurrentItem(with: AVPlayerItem(asset: playbackAsset))
        refreshAudioNormalization()
        screenPlayer.actionAtItemEnd = .pause
        currentTime = min(max(editorTime, 0), duration)
        movePlayers(to: currentTime)
        if timeObserver != nil {
            installEndObserver()
        }
    }

    private func registerUndo(
        _ actionName: String,
        operation: @escaping @MainActor (RecordingStudioModel) -> Void
    ) {
        editUndoManager.registerUndo(withTarget: self) { target in
            operation(target)
        }
        editUndoManager.setActionName(actionName)
        undoRevision &+= 1
    }

    private func loadTimelineThumbnails() {
        timelineThumbnails.prepare(url: screenURL, duration: sourceDuration)
        loadAudioWaveform()
    }

    private func loadAudioWaveform() {
        guard hasRecordedAudio, audioWaveform == nil, audioWaveformTask == nil else { return }
        let url = screenURL
        audioWaveformTask = Task { [weak self] in
            let waveform = await RecordingAudioWaveform.load(url: url)
            guard let self, !Task.isCancelled, !self.isTornDown else { return }
            self.audioWaveform = waveform
            self.audioWaveformTask = nil
        }
    }

    /// Speed of whichever clip covers this editor time; 1 when nothing
    /// covers it (e.g. past the end of the timeline).
    private func speed(atEditorTime time: TimeInterval) -> Double {
        guard let location = clipTimeline.location(at: time) else { return 1 }
        return clipTimeline.segments[location.segmentIndex].speed
    }

    private func syncCameraPlayback() {
        guard hasCameraVideo else { return }
        let sourceTime = clipTimeline.sourceTime(at: currentTime)
        guard sourceTime >= cameraOffset else {
            cameraPlayer.pause()
            cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        // The camera master is a separate, unedited recording - it has no
        // composition to bake speed into, so a sped-up clip must also play
        // the camera bubble at that rate or the two drift apart immediately.
        let rate = Float(speed(atEditorTime: currentTime))
        let cameraTime = CMTime(seconds: max(0, sourceTime - cameraOffset), preferredTimescale: 600)
        cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.cameraPlayer.rate = rate
            }
        }
    }

    private func correctCameraDriftIfNeeded() {
        guard hasCameraVideo, isPlaying else { return }
        let sourceTime = clipTimeline.sourceTime(at: currentTime)
        guard sourceTime >= cameraOffset else {
            cameraPlayer.pause()
            return
        }
        if cameraPlayer.rate == 0 {
            syncCameraPlayback()
            return
        }
        let targetRate = Float(speed(atEditorTime: currentTime))
        if abs(cameraPlayer.rate - targetRate) > 0.01 {
            cameraPlayer.rate = targetRate
        }
        let expected = sourceTime - cameraOffset
        let actual = cameraPlayer.currentTime().seconds
        guard expected.isFinite, actual.isFinite else { return }
        if abs(expected - actual) > 0.12 {
            cameraPlayer.seek(
                to: CMTime(seconds: max(0, expected), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    // MARK: - Card motion

    private func rebuildMotionTimeline() {
        motionTimeline = RecordingMotionTimeline.build(settings: motion, clipTimeline: clipTimeline)
    }

    private func replaceMotion(_ settings: RecordingMotionSettings) {
        var next = settings
        next.basePose = next.basePose.clamped
        next.cues = next.cues.map { cue in
            var cue = cue
            cue.targetPose = cue.targetPose.clamped
            return cue
        }.sorted { $0.start < $1.start }
        guard next != motion else { return }
        motion = next
        if let selectedMotionCueID, !next.cues.contains(where: { $0.id == selectedMotionCueID }) {
            self.selectedMotionCueID = nil
        }
        rebuildMotionTimeline()
        scheduleProjectSave()
    }

    private func applyMotion(_ settings: RecordingMotionSettings, actionName: String) {
        let previous = motion
        replaceMotion(settings)
        guard motion != previous else { return }
        registerUndo(actionName) { target in
            target.applyMotion(previous, actionName: actionName)
        }
    }

    /// Groups a continuous edit (a timeline drag) into one undo step.
    func beginMotionEdit() {
        commitPendingMotionEdit()
        if motionEditSnapshot == nil {
            motionEditSnapshot = motion
        }
    }

    func endMotionEdit(actionName: String = String(localized: "Edit 3D Motion")) {
        guard let previous = motionEditSnapshot else { return }
        motionEditSnapshot = nil
        guard previous != motion else { return }
        registerUndo(actionName) { target in
            target.applyMotion(previous, actionName: actionName)
        }
    }

    /// Applies a change. Discrete edits are their own undo step; coalescing
    /// edits (inspector scrubbing and typing) group into one step that
    /// commits once the value has been still for a moment.
    private func editMotion(
        _ actionName: String = String(localized: "Edit 3D Motion"),
        coalesces: Bool = false,
        _ change: (inout RecordingMotionSettings) -> Void
    ) {
        var next = motion
        change(&next)
        // There is no on/off switch: motion is live as soon as there is a
        // pose or cue to play, and inert again once there isn't.
        next.isEnabled = true
        if coalesces {
            if motionEditSnapshot == nil {
                motionEditSnapshot = motion
            }
            replaceMotion(next)
            motionEditCommitTask?.cancel()
            motionEditCommitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.motionEditCommitTask = nil
                self?.endMotionEdit(actionName: actionName)
            }
        } else if motionEditSnapshot != nil, motionEditCommitTask == nil {
            // Inside an explicit begin/end pair, such as a timeline drag.
            replaceMotion(next)
        } else {
            commitPendingMotionEdit()
            applyMotion(next, actionName: actionName)
        }
    }

    /// Closes a coalescing edit now, so undo never splits it.
    private func commitPendingMotionEdit() {
        guard let task = motionEditCommitTask else { return }
        task.cancel()
        motionEditCommitTask = nil
        endMotionEdit()
    }

    /// Projects saved while 3D motion could still be switched off keep the
    /// video they exported: poses and cues hidden behind the old switch
    /// never played, so they are left out rather than suddenly appearing.
    private static func editableMotion(_ stored: RecordingMotionSettings?) -> RecordingMotionSettings {
        guard let stored, stored.isEnabled else { return .disabled }
        return stored
    }

    var motionBasePose: RecordingCardPose {
        get { motion.basePose }
        set { editMotion(String(localized: "Edit Pose"), coalesces: true) { $0.basePose = newValue } }
    }

    // MARK: Canvas pose adjustment

    /// The adjustment in progress, while its pose still exists and motion is
    /// on. The canvas shows this pose instead of the one under the playhead.
    var activePoseAdjustment: RecordingPoseAdjustmentTarget? {
        guard let target = poseAdjustmentTarget else { return nil }
        switch target {
        case .base:
            return target
        case .cue(let id):
            return motion.cues.contains(where: { $0.id == id }) ? target : nil
        }
    }

    var adjustedPose: RecordingCardPose? {
        switch activePoseAdjustment {
        case .base:
            motion.basePose
        case .cue(let id):
            motion.cues.first { $0.id == id }?.targetPose
        case nil:
            nil
        }
    }

    func beginPoseAdjustment(_ target: RecordingPoseAdjustmentTarget) {
        pause()
        if isCroppingVideo { cancelVideoCrop() }
        if case .cue(let id) = target {
            selectMotionCue(id: id)
        }
        poseAdjustmentTarget = target
    }

    func endPoseAdjustment() {
        guard poseAdjustmentTarget != nil else { return }
        commitPendingMotionEdit()
        poseAdjustmentTarget = nil
    }

    /// Applies a pose from a canvas drag. Callers bracket each drag with
    /// begin/endMotionEdit so it lands as one undo step.
    func setAdjustedPose(_ pose: RecordingCardPose) {
        applyAdjustedPose(pose, coalesces: false)
    }

    private func applyAdjustedPose(_ pose: RecordingCardPose, coalesces: Bool) {
        guard let target = activePoseAdjustment else { return }
        editMotion(String(localized: "Adjust Pose"), coalesces: coalesces) { settings in
            switch target {
            case .base:
                settings.basePose = pose
            case .cue(let id):
                guard let index = settings.cues.firstIndex(where: { $0.id == id }) else { return }
                settings.cues[index].targetPose = pose
                settings.cues[index].preset = nil
            }
        }
    }

    /// Keyboard scaling while adjusting on the canvas. Repeated presses
    /// coalesce into one undo step.
    func scaleAdjustedPose(by factor: Double) {
        guard let pose = adjustedPose else { return }
        var updated = pose
        updated.scale = pose.scale * factor
        applyAdjustedPose(updated, coalesces: true)
    }

    func resetAdjustedScale() {
        guard var pose = adjustedPose, abs(pose.scale - 1) > 0.0001 else { return }
        pose.scale = 1
        applyAdjustedPose(pose, coalesces: true)
    }

    func resetAdjustedPose() {
        guard let target = activePoseAdjustment else { return }
        editMotion(String(localized: "Reset Pose")) { settings in
            switch target {
            case .base:
                settings.basePose = .identity
            case .cue(let id):
                guard let index = settings.cues.firstIndex(where: { $0.id == id }) else { return }
                settings.cues[index].targetPose = .identity
                settings.cues[index].preset = nil
            }
        }
    }

    func resetMotionBasePose() {
        editMotion(String(localized: "Reset Pose")) { $0.basePose = .identity }
    }

    /// The card the motion projects, in preview canvas space.
    private var motionCardRect: CGRect {
        RecordingStudioLayout.make(
            canvasSize: basePreviewCanvasSize,
            style: style,
            includeBubble: false,
            usesUniformPadding: exportAspect == .original,
            contentAspect: previewContentAspect,
            contentMode: previewContentMode,
            contentCropRect: videoCropRect
        ).cardRect
    }

    /// True when the base pose or any cue target pushes the card past the
    /// canvas edge, so the inspector can warn before export crops it.
    var motionExceedsCanvas: Bool {
        guard motion.isEnabled else { return false }
        let canvas = basePreviewCanvasSize
        let card = motionCardRect
        let poses = [motion.basePose] + motion.cues.filter(\.isEnabled).map(\.targetPose)
        return poses.contains { pose in
            let bounds = RecordingCardProjection(cardRect: card, canvasSize: canvas, pose: pose).bounds(of: card)
            return bounds.minX < -0.5 || bounds.minY < -0.5
                || bounds.maxX > canvas.width + 0.5 || bounds.maxY > canvas.height + 0.5
        }
    }

    /// Scales the base pose and every cue target by one saved factor so the
    /// whole motion stays inside the canvas.
    func fitMotionToCanvas() {
        let poses = [motion.basePose] + motion.cues.filter(\.isEnabled).map(\.targetPose)
        let factor = RecordingCardProjection.fittingScaleFactor(
            cardRect: motionCardRect,
            canvasSize: basePreviewCanvasSize,
            poses: poses
        )
        guard factor.isFinite, abs(factor - 1) > 0.0005 else { return }
        editMotion(String(localized: "Fit to Canvas")) { settings in
            settings.basePose.scale *= factor
            for index in settings.cues.indices {
                settings.cues[index].targetPose.scale *= factor
            }
        }
    }

    var selectedMotionCue: RecordingMotionCue? {
        motion.cues.first { $0.id == selectedMotionCueID }
    }

    /// The selected cue as it actually plays after cuts and speed changes.
    var selectedMotionSegment: RecordingMotionTimeline.Segment? {
        guard let selectedMotionCueID else { return nil }
        return RecordingMotionTimeline.build(
            settings: RecordingMotionSettings(isEnabled: true, basePose: motion.basePose, cues: motion.cues),
            clipTimeline: clipTimeline
        ).segment(for: selectedMotionCueID)
    }

    func motionPose(at time: TimeInterval) -> RecordingCardPose {
        motionTimeline.pose(at: time)
    }

    /// Room a motion cue can use starting at a source time: pushed past any
    /// cue it lands in, trimmed to the next one.
    private func freeMotionSpan(
        from start: TimeInterval,
        length: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard sourceDuration > 0 else { return nil }
        var lower = min(max(start, 0), sourceDuration)
        while let covering = motion.cues.first(where: { $0.start <= lower && $0.end > lower }) {
            lower = covering.end
        }
        let upper = motion.cues
            .filter { $0.start > lower }
            .map(\.start)
            .min() ?? sourceDuration
        guard upper - lower >= RecordingMotionCue.minimumDuration else { return nil }
        return lower...min(lower + max(length, RecordingMotionCue.minimumDuration), upper)
    }

    /// Adds a cue at an editor time. Returns false when no gap is left.
    @discardableResult
    func addMotionCue(preset: RecordingMotionPreset, at editorTime: TimeInterval) -> Bool {
        let sourceStart = clipTimeline.sourceTime(at: editorTime)
        // Cover the default length in output time, whatever the clip speed.
        let sourceEnd = clipTimeline.sourceTime(
            at: min(editorTime + RecordingMotionCue.defaultDuration, duration)
        )
        let length = max(sourceEnd - sourceStart, RecordingMotionCue.defaultDuration)
        guard let span = freeMotionSpan(from: sourceStart, length: length) else { return false }
        let cue = RecordingMotionCue(
            start: span.lowerBound,
            end: span.upperBound,
            targetPose: preset.targetPose(from: motion.basePose),
            preset: preset
        )
        editMotion(String(localized: "Add Motion")) { settings in
            settings.cues.append(cue)
        }
        selectMotionCue(id: cue.id)
        return true
    }

    /// Adds a cue over a dragged editor range, the way a zoom is drawn on its
    /// lane. Returns false when no gap is left there.
    @discardableResult
    func addMotionCue(
        preset: RecordingMotionPreset,
        fromEditorTime editorStart: TimeInterval,
        toEditorTime editorEnd: TimeInterval
    ) -> Bool {
        let sourceStart = clipTimeline.sourceTime(at: min(editorStart, editorEnd))
        let sourceEnd = clipTimeline.sourceTime(at: max(editorStart, editorEnd))
        guard let span = freeMotionSpan(from: sourceStart, length: sourceEnd - sourceStart) else { return false }
        let cue = RecordingMotionCue(
            start: span.lowerBound,
            end: span.upperBound,
            targetPose: preset.targetPose(from: motion.basePose),
            preset: preset
        )
        editMotion(String(localized: "Add Motion")) { settings in
            settings.cues.append(cue)
        }
        selectMotionCue(id: cue.id)
        return true
    }

    func removeMotionCue(id: UUID) {
        editMotion(String(localized: "Remove Motion")) { settings in
            settings.cues.removeAll { $0.id == id }
        }
        if selectedMotionCueID == id {
            selectedMotionCueID = nil
        }
    }

    func duplicateMotionCue(id: UUID) {
        guard let original = motion.cues.first(where: { $0.id == id }),
              let span = freeMotionSpan(from: original.end, length: original.duration) else { return }
        var copy = original
        copy.id = UUID()
        copy.start = span.lowerBound
        copy.end = span.upperBound
        editMotion(String(localized: "Duplicate Motion")) { $0.cues.append(copy) }
        selectMotionCue(id: copy.id)
    }

    /// Points a cue at a preset's target, keeping its timing.
    func applyMotionPreset(_ preset: RecordingMotionPreset, toCueID id: UUID) {
        editMotion(String(localized: "Change Motion Preset")) { settings in
            guard let index = settings.cues.firstIndex(where: { $0.id == id }) else { return }
            settings.cues[index].targetPose = preset.targetPose(from: settings.basePose)
            settings.cues[index].preset = preset
        }
    }

    private func motionNeighborBounds(
        forCueAt index: Int,
        in cues: [RecordingMotionCue]
    ) -> (lower: TimeInterval, upper: TimeInterval) {
        (
            lower: index > 0 ? max(0, cues[index - 1].end) : 0,
            upper: index + 1 < cues.count
                ? min(cues[index + 1].start, sourceDuration)
                : sourceDuration
        )
    }

    private func sanitizedMotionCue(_ cue: RecordingMotionCue) -> RecordingMotionCue {
        var cue = cue
        let range = RecordingMotionCue.transitionRange
        cue.enterDuration = cue.enterDuration.isFinite
            ? min(max(cue.enterDuration, range.lowerBound), range.upperBound) : RecordingMotionCue.defaultTransition
        cue.exitDuration = cue.exitDuration.isFinite
            ? min(max(cue.exitDuration, range.lowerBound), range.upperBound) : RecordingMotionCue.defaultTransition
        cue.targetPose = cue.targetPose.clamped
        cue.chainsFromPrevious = false
        return cue
    }

    /// Applies an edited cue, stopping either edge at its neighbors.
    func updateMotionCue(_ cue: RecordingMotionCue, coalesces: Bool = false) {
        let cues = motion.cues.sorted { $0.start < $1.start }
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let bounds = motionNeighborBounds(forCueAt: index, in: cues)
        var updated = sanitizedMotionCue(cue)
        updated.start = min(
            max(updated.start, bounds.lower),
            max(bounds.lower, bounds.upper - RecordingMotionCue.minimumDuration)
        )
        updated.end = min(
            max(updated.end, updated.start + RecordingMotionCue.minimumDuration),
            bounds.upper
        )
        editMotion(String(localized: "Edit Motion"), coalesces: coalesces) { settings in
            guard let stored = settings.cues.firstIndex(where: { $0.id == cue.id }) else { return }
            settings.cues[stored] = updated
        }
    }

    /// Slides a cue without changing its length; it parks against neighbors.
    func moveMotionCue(_ cue: RecordingMotionCue) {
        let cues = motion.cues.sorted { $0.start < $1.start }
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let bounds = motionNeighborBounds(forCueAt: index, in: cues)
        let room = max(bounds.upper - bounds.lower, RecordingMotionCue.minimumDuration)
        let length = min(max(cue.duration, RecordingMotionCue.minimumDuration), room)
        var moved = sanitizedMotionCue(cue)
        moved.start = min(max(cue.start, bounds.lower), max(bounds.lower, bounds.upper - length))
        moved.end = min(moved.start + length, bounds.upper)
        editMotion(String(localized: "Move Motion")) { settings in
            guard let stored = settings.cues.firstIndex(where: { $0.id == cue.id }) else { return }
            settings.cues[stored] = moved
        }
    }

    /// One block per cue on the edited timeline, merged across cuts.
    var motionTimelineBlocks: [RecordingMotionTimelineBlock] {
        motion.cues.compactMap { cue in
            let slices = clipTimeline.slices(overlapping: cue.start, sourceEnd: cue.end)
            guard let first = slices.first, let last = slices.last else { return nil }
            return RecordingMotionTimelineBlock(
                cue: cue,
                editorStart: first.editorStart,
                editorEnd: last.editorEnd
            )
        }
    }

    // MARK: - Zoom cues

    private func replaceZoomCues(_ cues: [ZoomCue]) {
        zoomCues = cues.sorted { $0.start < $1.start }
        rebuildViewportTimeline()
        scheduleProjectSave()
    }

    private func applyZoomCues(_ cues: [ZoomCue], actionName: String) {
        let sorted = cues.sorted { $0.start < $1.start }
        guard sorted != zoomCues else { return }
        let previous = zoomCues
        registerUndo(actionName) { target in
            target.applyZoomCues(previous, actionName: actionName)
        }
        replaceZoomCues(sorted)
    }

    func beginZoomCueEdit() {
        if zoomEditSnapshot == nil {
            zoomEditSnapshot = zoomCues
        }
    }

    func endZoomCueEdit(actionName: String = String(localized: "Edit Zoom")) {
        guard let previous = zoomEditSnapshot else { return }
        zoomEditSnapshot = nil
        guard previous != zoomCues else { return }
        registerUndo(actionName) { target in
            target.applyZoomCues(previous, actionName: actionName)
        }
    }

    func resynthesizeZoomCues() {
        applyZoomCues(
            ZoomCueSynthesizer.cues(from: pointerCapture, duration: sourceDuration),
            actionName: String(localized: "Reset Zooms")
        )
    }

    func addZoomCue(at time: TimeInterval) {
        let sourceTime = clipTimeline.sourceTime(at: time)
        let start = min(max(0, sourceTime), max(0, sourceDuration - 1))
        insertZoomCue(start: start, end: min(sourceDuration, start + 3))
    }

    /// Room a cue has to grow or slide into before it would run into a
    /// neighbor. Cues are kept sorted and non-overlapping, so the only cues
    /// that can be in the way are the ones on either side.
    private func neighborBounds(
        forCueAt index: Int,
        in cues: [ZoomCue]
    ) -> (lower: TimeInterval, upper: TimeInterval) {
        (
            lower: index > 0 ? max(0, cues[index - 1].end) : 0,
            upper: index + 1 < cues.count
                ? min(cues[index + 1].start, sourceDuration)
                : sourceDuration
        )
    }

    /// Where a new cue can actually go. A request landing inside an existing
    /// zoom is pushed past it rather than dropped, and the span is trimmed to
    /// the next cue; nil when no gap from here on is long enough to use.
    private func freeSpan(
        from start: TimeInterval,
        preferredEnd: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard sourceDuration > 0 else { return nil }
        let length = max(preferredEnd - start, ZoomCue.minimumDuration)
        var lower = min(max(start, 0), sourceDuration)
        // Walks chains of touching cues, so "add at playhead" inside a run of
        // zooms lands in the first real gap after them.
        while let covering = zoomCues.first(where: { $0.start <= lower && $0.end > lower }) {
            lower = covering.end
        }
        let upper = zoomCues
            .filter { $0.start > lower }
            .map(\.start)
            .min() ?? sourceDuration
        guard upper - lower >= ZoomCue.minimumDuration else { return nil }
        return lower...min(lower + length, upper)
    }

    /// Creates a zoom cue spanning a dragged range in the zoom lane. Times
    /// are editor time and need not be ordered.
    @discardableResult
    func addZoomCue(fromEditorTime editorStart: TimeInterval, toEditorTime editorEnd: TimeInterval) -> UUID? {
        let lowSource = clipTimeline.sourceTime(at: min(editorStart, editorEnd))
        let highSource = clipTimeline.sourceTime(at: max(editorStart, editorEnd))
        let start = min(max(0, lowSource), max(0, sourceDuration - 0.5))
        let end = max(start + 0.5, min(sourceDuration, highSource))
        return insertZoomCue(start: start, end: end)
    }

    @discardableResult
    private func insertZoomCue(start: TimeInterval, end: TimeInterval) -> UUID? {
        guard let span = freeSpan(from: start, preferredEnd: end) else { return nil }
        let hasPointerTrack = !pointerCapture.travel.isEmpty || !pointerCapture.presses.isEmpty
        let editorTime = clipTimeline.editorTime(forSourceTime: span.lowerBound) ?? currentTime
        let target = pointerTimeline.location(at: editorTime) ?? CGPoint(x: 0.5, y: 0.5)
        let cue = ZoomCue(
            start: span.lowerBound,
            end: span.upperBound,
            zoom: 1.5,
            anchorMode: hasPointerTrack ? .pointerAnchor : .pinnedAnchor,
            pinnedPoint: target,
            boundsBias: hasPointerTrack ? 0.25 : 0
        )
        var cues = zoomCues
        cues.append(cue)
        applyZoomCues(cues, actionName: String(localized: "Add Zoom"))
        selectedCueID = cue.id
        selectedClipID = nil
        return cue.id
    }

    func removeZoomCue(id: UUID) {
        applyZoomCues(zoomCues.filter { $0.id != id }, actionName: String(localized: "Remove Zoom"))
        if selectedCueID == id {
            selectedCueID = nil
        }
    }

    /// Applies an edited cue, stopping either edge at the neighboring cues so
    /// blocks can be resized right up to each other but never through.
    func updateZoomCue(_ cue: ZoomCue) {
        var cues = zoomCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let bounds = neighborBounds(forCueAt: index, in: cues)
        var updated = sanitized(cue)
        updated.start = min(
            max(updated.start, bounds.lower),
            max(bounds.lower, bounds.upper - ZoomCue.minimumDuration)
        )
        updated.end = min(
            max(updated.end, updated.start + ZoomCue.minimumDuration),
            bounds.upper
        )
        cues[index] = updated
        replaceZoomCues(cues)
    }

    /// Slides a cue without changing its length. Unlike a resize, running into
    /// a neighbor parks the block against it rather than squashing it.
    func moveZoomCue(_ cue: ZoomCue) {
        var cues = zoomCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let bounds = neighborBounds(forCueAt: index, in: cues)
        let room = max(bounds.upper - bounds.lower, ZoomCue.minimumDuration)
        let length = min(max(cue.duration, ZoomCue.minimumDuration), room)
        var moved = sanitized(cue)
        moved.start = min(max(cue.start, bounds.lower), max(bounds.lower, bounds.upper - length))
        moved.end = min(moved.start + length, bounds.upper)
        cues[index] = moved
        replaceZoomCues(cues)
    }

    /// Everything about a cue except its placement, which the caller clamps
    /// against its neighbors.
    private func sanitized(_ cue: ZoomCue) -> ZoomCue {
        var cue = cue
        cue.start = min(max(0, cue.start), sourceDuration)
        cue.end = min(max(cue.start, cue.end), sourceDuration)
        cue.zoom = min(max(cue.zoom, 1), 4)
        cue.boundsBias = min(max(cue.boundsBias, 0), 1)
        cue.pinnedPoint = CGPoint(
            x: min(max(cue.pinnedPoint.x, 0), 1),
            y: min(max(cue.pinnedPoint.y, 0), 1)
        )
        return cue
    }

    var selectedCue: ZoomCue? {
        zoomCues.first { $0.id == selectedCueID }
    }

    var visibleRecordedPressTimes: [TimeInterval] {
        recordedPressTimes.compactMap { clipTimeline.editorTime(forSourceTime: $0) }
    }

    /// One visual block per cue on the edited timeline. A cue's per-segment
    /// slices are always contiguous in editor time (a cut removes the editor
    /// time between them), so they merge into a single block - cutting a clip
    /// inside a zoom never splits the zoom's lane representation.
    var zoomTimelineBlocks: [RecordingZoomTimelineBlock] {
        zoomCues
            .filter { !$0.isImplicit }
            .compactMap { cue in
                let slices = clipTimeline.slices(overlapping: cue.start, sourceEnd: cue.end)
                guard let first = slices.first, let last = slices.last else { return nil }
                return RecordingZoomTimelineBlock(
                    cue: cue,
                    editorStart: first.editorStart,
                    editorEnd: last.editorEnd
                )
            }
    }

    func sourceTime(atEditorTime time: TimeInterval) -> TimeInterval {
        clipTimeline.sourceTime(at: time)
    }

    func editorTime(forSourceTime time: TimeInterval) -> TimeInterval? {
        clipTimeline.editorTime(forSourceTime: time)
    }

    private func rebuildPointerTimeline() {
        reframeFocusTimeline = nil
        reframeFocusResolved = false
        guard pointerIsSynthesized, sourceDuration > 0 else {
            pointerTimeline = .empty
            return
        }
        pointerTimeline = PointerTimeline.build(
            capture: pointerCapture,
            duration: sourceDuration,
            recordingSizeInPoints: recordingPointSize,
            fallbackArtwork: PointerArtworkCapture.defaultArtwork(),
            clipTimeline: clipTimeline
        )
    }

    private func rebuildViewportTimeline() {
        guard sourceDuration > 0 else {
            viewportTimeline = .identity
            return
        }
        viewportTimeline = ViewportTimeline.build(
            cues: zoomCues,
            capture: pointerCapture,
            clipTimeline: clipTimeline
        )
        // The reframe camera derives from the viewport, so it follows
        // every rebuild (zoom edits, cuts, speed changes).
        rebuildPreviewReframe()
    }

    private func scheduleProjectSave() {
        guard isLoaded, !isApplyingDocument, session != nil else { return }
        hasUnsavedChanges = true
        projectSaveTask?.cancel()
        projectSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.writeDraftNow()
        }
    }

    /// Every edit in the editor, as a storable document.
    func currentDocument() -> RecordingEditDocument {
        RecordingEditDocument(
            style: style,
            zoomEnabled: zoomEnabled,
            zoomCues: zoomCues.filter { !$0.isImplicit },
            clipTimeline: clipTimeline,
            exportSettings: exportSettings,
            showsClickEffects: showsClickEffects,
            showsKeystrokes: showsKeystrokes,
            keystrokePlacement: keystrokePlacement,
            showsSubtitles: showsSubtitles,
            subtitleCues: subtitleCues.isEmpty ? nil : subtitleCues,
            subtitleWords: transcriptWords.isEmpty ? nil : transcriptWords,
            subtitleStyle: subtitleStyle,
            exportAspect: exportAspect,
            exportAspectMode: exportAspectMode,
            videoCropRect: isVideoCropped ? videoCropRect : nil,
            replacementAudioFileName: replacementAudio?.url.lastPathComponent,
            replacementAudioDisplayName: replacementAudio?.displayName,
            audioExportFormat: audioExportFormat,
            audioVolume: Double(audioVolume),
            normalizesAudioLoudness: normalizesAudioLoudness,
            motion: motion == .disabled ? nil : motion,
            backgroundMusic: backgroundMusic,
            imageOverlays: imageOverlays.isEmpty ? nil : imageOverlays
        )
    }

    /// True until the project has been saved at least once. Only these get
    /// offered "Delete and close" - throwing away a project the user already
    /// committed to would be unrecoverable.
    var hasNeverBeenSaved: Bool {
        guard let session else { return false }
        return !session.hasSavedProject
    }

    /// Persists the working copy. Cheap, debounced, and never touches the
    /// committed `edit.json`, so a crash costs nothing and Save still means
    /// something.
    private func writeDraftNow() {
        guard isLoaded, !isHeadless, let session else { return }
        let document = currentDocument()
        if document == lastSavedDocument {
            // Edited back to the saved state (undo, or a discard landing):
            // the draft is now noise and would reopen the project dirty.
            session.removeDraftDocument()
            hasUnsavedChanges = false
        } else {
            try? session.writeDraftDocument(document)
            hasUnsavedChanges = true
        }
        dropStaleRender(for: document, in: session)
    }

    /// A cached flatten that no longer matches the edits is worse than no
    /// cache: History previews it and Share would upload it.
    private func dropStaleRender(for document: RecordingEditDocument, in session: RecordingSession) {
        guard session.existingFinalURL != nil else { return }
        guard session.freshFinalURL(matching: document) == nil else { return }
        session.removeFinalVideos()
    }

    /// Writes the working copy immediately, bypassing the debounce. Used on
    /// teardown and on quit so no edit is left only in memory.
    func flushDraft() {
        projectSaveTask?.cancel()
        writeDraftNow()
    }

    /// ⌘S. Commits the working copy to `edit.json` and clears the draft.
    @discardableResult
    func saveProject() -> Bool {
        guard isLoaded, session != nil else { return false }
        do {
            try commitProject()
            return true
        } catch {
            FailureAlert.present(message: String(localized: "The recording project could not be saved"), error: error,
                                 detail: String(localized: "Your editor will stay open. Try saving again after resolving the problem."))
            return false
        }
    }

    /// The save itself, throwing instead of alerting so an agent's edit can
    /// report the failure to the agent.
    func commitProject() throws {
        guard isLoaded, let session else { return }
        projectSaveTask?.cancel()
        let document = currentDocument()
        try session.writeEditDocument(document)
        session.removeDraftDocument()
        lastSavedDocument = document
        hasUnsavedChanges = false
        session.updateProjectMetadata { $0.savedAt = Date() }
        dropStaleRender(for: document, in: session)
        RecordingProjectStore.shared.reload()
        flashSaveConfirmation()
    }

    /// Throws away everything since the last save and returns the editor to
    /// that state. Only offered for projects that have actually been saved.
    func discardChanges() async {
        guard isLoaded, let session else { return }
        projectSaveTask?.cancel()
        session.removeDraftDocument()
        guard let document = lastSavedDocument else { return }
        applyDocumentSettings(document)
        await applyDocumentTimeline(document)
        // Rebuilding the timeline touches published state; let the normal
        // draft path settle the dirty flag rather than assuming it landed.
        flushDraft()
    }

    /// Deletes the whole recording package - footage included - and its
    /// History entry. Reserved for a project that was never saved.
    func deleteProject() {
        guard let session else { return }
        teardown()
        RecordingProjectStore.shared.delete(session)
    }

    private func flashSaveConfirmation() {
        saveFlash = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            self?.saveFlash = false
        }
    }

    /// The parts of a stored project that need the timeline rebuilt around
    /// them: cuts, the imported soundtrack, and everything derived from both.
    private func applyDocumentTimeline(_ document: RecordingEditDocument) async {
        guard !isTornDown, !Task.isCancelled, let session else { return }
        isApplyingDocument = true
        defer { isApplyingDocument = false }

        clipTimeline = Self.clipTimeline(for: document, sourceDuration: sourceDuration)
        duration = clipTimeline.duration
        // Nothing is selected until the user picks a clip; an unsplit
        // recording would otherwise open wrapped in selection chrome.
        selectedClipID = nil

        if let fileName = document.replacementAudioFileName {
            let url = session.directoryURL.appendingPathComponent(fileName)
            if url != replacementAudio?.url, FileManager.default.fileExists(atPath: url.path) {
                let loadedAudio = await RecordingReplacementAudio.load(
                    url: url,
                    displayName: document.replacementAudioDisplayName ?? fileName
                )
                guard !isTornDown, !Task.isCancelled else { return }
                replacementAudio = loadedAudio
            }
        } else {
            replacementAudio = nil
        }
        await loadCachedBackgroundMusic()
        guard !isTornDown, !Task.isCancelled else { return }

        isApplyingDocument = false

        try? rebuildScreenPlayerItem(preserving: currentTime)
        resolveBackgroundMusic()
        rebuildPointerTimeline()
        rebuildViewportTimeline()
        rebuildMotionTimeline()
        rebuildImageOverlayTimeline()
        rebuildPreviewReframe()
        editUndoManager.removeAllActions()
        undoRevision += 1
    }

    /// Viewport frame to render at a given time, honoring the zoom toggle.
    func viewportFrame(at time: TimeInterval) -> ViewportFrame {
        guard zoomEnabled else { return .identity }
        return viewportTimeline.frame(at: time)
    }

    /// True when this session was captured without the OS cursor, so the
    /// preview and export draw the synthetic pointer.
    var pointerIsSynthesized: Bool {
        manifest?.pointerSynthesized == true
    }

    /// Smoothed normalized pointer location for the preview overlay; nil when
    /// the recording carries its cursor in the pixels.
    func pointerLocation(at time: TimeInterval) -> CGPoint? {
        guard pointerIsSynthesized else { return nil }
        return pointerTimeline.location(at: time)
    }

    func pointerFrame(at time: TimeInterval) -> PointerFrame? {
        guard !style.hidesCursor, pointerIsSynthesized else { return nil }
        return pointerTimeline.frame(at: time)
    }

    func artwork(id: String?) -> PointerArtwork? {
        pointerTimeline.artwork(id: id, style: style.cursorStyle)
    }

    /// What the cursor style picker shows for `cursorStyle`: for Original,
    /// up to two of the pointers recorded with this video.
    func previewArtwork(for cursorStyle: RecordingCursorStyle) -> [PointerArtwork] {
        if cursorStyle == .recorded {
            let recorded = Array(pointerTimeline.recordedArtwork.prefix(2))
            if !recorded.isEmpty { return recorded }
        }
        return pointerTimeline.artwork(id: nil, style: cursorStyle).map { [$0] } ?? []
    }

    /// Legacy sessions may already contain baked-in press feedback; only
    /// sidecar-reconstructed sessions can re-render it on demand.
    var canShowPressEffects: Bool {
        pointerIsSynthesized && manifest?.pressEffectsBaked == false
    }

    var showsPressEffects: Bool {
        canShowPressEffects && showsClickEffects
    }

    var hasKeystrokes: Bool {
        !keystrokeTimeline.isEmpty
    }

    // MARK: - Transcription

    /// Only narrated sessions can be transcribed; the mic requirement means
    /// legacy bare movies and silent captures never show the section.
    var canTranscribe: Bool {
        manifest?.includesMicrophone == true
    }

    var hasSubtitles: Bool {
        !subtitleTimeline.isEmpty
    }

    /// Subtitle text to draw over the card right now; nil when hidden or
    /// nobody is speaking.
    func subtitleText(at time: TimeInterval) -> String? {
        guard showsSubtitles, hasSubtitles else { return nil }
        return subtitleTimeline.text(at: clipTimeline.sourceTime(at: time))
    }

    /// Karaoke word state for the bar at this editor time; nil when the
    /// style doesn't highlight words or no timings exist, in which case
    /// the bar renders `subtitleText` plainly.
    func subtitleKaraokeLine(at time: TimeInterval) -> KaraokeTimeline.Line? {
        guard showsSubtitles, subtitleStyle.highlightsSpokenWord,
              !karaokeTimeline.isEmpty else {
            return nil
        }
        return karaokeTimeline.line(at: clipTimeline.sourceTime(at: time))
    }

    func transcribe() {
        guard !transcriptionState.isTranscribing, isLoaded else { return }
        transcriptionState = .transcribing
        let movieURL = screenURL
        transcriptionTask = Task { [weak self] in
            do {
                let transcript = try await RecordingTranscriptionService.transcribe(screenMovieURL: movieURL)
                guard !Task.isCancelled else { return }
                self?.applyTranscription(transcript)
            } catch {
                guard !Task.isCancelled else { return }
                self?.transcriptionState = .failed(error.localizedDescription)
            }
        }
    }

    private func applyTranscription(_ transcript: RecordingTranscript) {
        discardCaptionCleanup()
        selectedSubtitleCueID = nil
        subtitleCues = transcript.cues
        subtitleTimeline = SubtitleTimeline(cues: transcript.cues)
        transcriptWords = transcript.words
        karaokeTimeline = KaraokeTimeline(cues: transcript.cues, words: transcript.words)
        showsSubtitles = true
        transcriptionState = .idle
        updateActiveTranscriptWord()
        updatePlaybackVolume()
        scheduleProjectSave()
    }

    func removeTranscription() {
        discardCaptionCleanup()
        selectedSubtitleCueID = nil
        subtitleCues = []
        subtitleTimeline = .empty
        transcriptWords = []
        karaokeTimeline = .empty
        activeTranscriptWordIndex = nil
        transcriptionState = .idle
        updatePlaybackVolume()
        scheduleProjectSave()
    }

    func updateSubtitleText(id: UUID, text: String) {
        guard let index = subtitleCues.firstIndex(where: { $0.id == id }),
              subtitleCues[index].text != text else {
            return
        }
        subtitleCues[index].text = text
        subtitleTimeline = SubtitleTimeline(cues: subtitleCues)
        karaokeTimeline = KaraokeTimeline(cues: subtitleCues, words: transcriptWords)
        scheduleProjectSave()
    }

    /// Moves the paused playhead to a cue's first surviving frame; a cue
    /// whose audio was cut out entirely has no home on the edited timeline.
    func seekToSubtitle(_ cue: RecordingSubtitleCue) {
        let target = clipTimeline.editorTime(forSourceTime: cue.start)
            ?? clipTimeline.editorTime(forSourceTime: (cue.start + cue.end) / 2)
        guard let target else { return }
        pause()
        seek(to: target)
    }

    // MARK: - Caption timing

    /// Starts a timeline drag on a caption; `endSubtitleEdit` makes the
    /// whole drag one undo step.
    func beginSubtitleEdit() {
        if subtitleEditSnapshot == nil {
            subtitleEditSnapshot = subtitleCues
        }
    }

    func endSubtitleEdit(actionName: String) {
        guard let previous = subtitleEditSnapshot else { return }
        subtitleEditSnapshot = nil
        guard previous != subtitleCues else { return }
        registerUndo(actionName) { target in
            target.applySubtitleCues(previous, actionName: actionName)
        }
    }

    /// Slides a caption to a new source start, keeping its length; it stops
    /// at its neighbours.
    func moveSubtitle(id: UUID, toStart start: TimeInterval) {
        replaceSubtitleCues(SubtitleCueTiming.moving(
            subtitleCues, id: id, toStart: start, sourceDuration: sourceDuration
        ))
    }

    /// Drags one edge of a caption to a source time.
    func resizeSubtitle(id: UUID, edge: SubtitleCueTiming.Edge, to time: TimeInterval) {
        replaceSubtitleCues(SubtitleCueTiming.resizing(
            subtitleCues, id: id, edge: edge, to: time, sourceDuration: sourceDuration
        ))
    }

    /// Removes one caption. Its words stay in the transcript, so cutting by
    /// text still sees them; they just no longer show on screen.
    func deleteSubtitle(id: UUID) {
        guard subtitleCues.contains(where: { $0.id == id }) else { return }
        if selectedSubtitleCueID == id {
            selectedSubtitleCueID = nil
        }
        applySubtitleCues(subtitleCues.filter { $0.id != id }, actionName: String(localized: "Delete Caption"))
    }

    /// Folds a caption into the one before it. Returns the merged caption
    /// and where the joined text starts, for placing the caret; nil for the
    /// first caption.
    @discardableResult
    func mergeSubtitleIntoPrevious(id: UUID) -> (id: UUID, joinOffset: Int)? {
        guard let result = SubtitleCueMerging.mergingIntoPrevious(subtitleCues, id: id) else { return nil }
        if selectedSubtitleCueID == id {
            selectedSubtitleCueID = result.mergedID
        }
        applySubtitleCues(result.cues, actionName: String(localized: "Merge Captions"))
        return (result.mergedID, result.joinOffset)
    }

    /// A live edit mid-drag: no undo step of its own.
    private func replaceSubtitleCues(_ cues: [RecordingSubtitleCue]) {
        guard cues != subtitleCues else { return }
        subtitleCues = cues
        subtitleTimeline = SubtitleTimeline(cues: cues)
        karaokeTimeline = KaraokeTimeline(cues: cues, words: transcriptWords)
        scheduleProjectSave()
    }

    /// Cue under the playhead right now, for highlighting the list row.
    var activeSubtitleCue: RecordingSubtitleCue? {
        guard hasSubtitles else { return nil }
        return subtitleTimeline.cue(at: clipTimeline.sourceTime(at: currentTime))
    }

    // MARK: - Transcript editing

    /// Cues-only projects (transcribed before words were stored) can still
    /// show captions but need a fresh transcription to edit by text.
    var hasTranscriptWords: Bool {
        !transcriptWords.isEmpty
    }

    /// Whether this word's audio still exists on the edited timeline.
    func transcriptWordSurvives(_ index: Int) -> Bool {
        guard transcriptWords.indices.contains(index) else { return false }
        return clipTimeline.editorTime(forSourceTime: transcriptWords[index].midpoint) != nil
    }

    func isFillerWord(_ index: Int) -> Bool {
        guard transcriptWords.indices.contains(index) else { return false }
        return TranscriptEditPlanner.isFiller(transcriptWords[index])
    }

    /// Fillers that would actually be cut - ones already removed don't count.
    var removableFillerWordCount: Int {
        TranscriptEditPlanner.fillerIndices(in: transcriptWords)
            .count { transcriptWordSurvives($0) }
    }

    /// Narration pauses long enough to trim that still exist in the edit.
    var trimmableSilenceCount: Int {
        TranscriptEditPlanner.silenceCutRanges(in: transcriptWords, sourceDuration: sourceDuration)
            .count { !clipTimeline.slices(overlapping: $0.lowerBound, sourceEnd: $0.upperBound).isEmpty }
    }

    /// Moves the paused playhead to a word's first surviving frame.
    func seekToTranscriptWord(at index: Int) {
        guard transcriptWords.indices.contains(index) else { return }
        let word = transcriptWords[index]
        let target = clipTimeline.editorTime(forSourceTime: word.start)
            ?? clipTimeline.editorTime(forSourceTime: word.midpoint)
        guard let target else { return }
        pause()
        seek(to: target)
    }

    /// Cuts the selected words' footage out of the video.
    func cutTranscriptWords(in range: ClosedRange<Int>) {
        guard let cut = TranscriptEditPlanner.cutRange(
            forWordsAt: range,
            in: transcriptWords,
            sourceDuration: sourceDuration
        ) else { return }
        cutSourceRanges([cut], actionName: range.count == 1 ? String(localized: "Cut Word") : String(localized: "Cut Words"))
    }

    func removeFillerWords() {
        cutSourceRanges(
            TranscriptEditPlanner.fillerCutRanges(in: transcriptWords, sourceDuration: sourceDuration),
            actionName: String(localized: "Remove Filler Words")
        )
    }

    func trimNarrationSilences() {
        cutSourceRanges(
            TranscriptEditPlanner.silenceCutRanges(in: transcriptWords, sourceDuration: sourceDuration),
            actionName: String(localized: "Trim Silences")
        )
    }

    /// The shared transcript-cut path: removes source ranges from the clip
    /// timeline and drops the cut words from any overlapping captions. Both
    /// registrations land in one undo group, so a single ⌘Z restores the
    /// footage and the caption text together.
    func cutSourceRanges(_ ranges: [ClosedRange<TimeInterval>], actionName: String) {
        let merged = RecordingClipTimeline.mergedRanges(ranges)
        guard !merged.isEmpty,
              let next = clipTimeline.removingSourceRanges(merged)?.normalized(to: sourceDuration),
              next != clipTimeline else {
            return
        }

        let updatedCues = Self.rebuildingCueTexts(
            subtitleCues,
            words: transcriptWords,
            cutRanges: merged,
            previous: clipTimeline,
            surviving: next
        )
        if updatedCues != subtitleCues {
            applySubtitleCues(updatedCues, actionName: actionName)
        }

        // Park the playhead on the first splice so the result is audible
        // right where the cut happened.
        let playhead = next.editorTime(forSourceTime: merged[0].upperBound)
            ?? min(currentTime, next.duration)
        applyClipTimeline(
            next,
            selectedID: selectedClipID,
            playheadTime: playhead,
            actionName: actionName
        )
    }

    private func applySubtitleCues(_ cues: [RecordingSubtitleCue], actionName: String) {
        guard cues != subtitleCues else { return }
        let previous = subtitleCues
        registerUndo(actionName) { target in
            target.applySubtitleCues(previous, actionName: actionName)
        }
        subtitleCues = cues
        subtitleTimeline = SubtitleTimeline(cues: cues)
        karaokeTimeline = KaraokeTimeline(cues: cues, words: transcriptWords)
        scheduleProjectSave()
    }

    /// Rewrites the text of cues touched by a cut so captions stop showing
    /// words whose audio is gone. Only touched cues change, and a cue the
    /// user typed keeps their text minus the cut words (see
    /// TranscriptCaptionText.cutting). Words map to cues as
    /// TranscriptCaptionText.wordIndices maps them.
    private static func rebuildingCueTexts(
        _ cues: [RecordingSubtitleCue],
        words: [RecordingTranscriptWord],
        cutRanges: [ClosedRange<TimeInterval>],
        previous: RecordingClipTimeline,
        surviving timeline: RecordingClipTimeline
    ) -> [RecordingSubtitleCue] {
        guard !words.isEmpty, !cues.isEmpty else { return cues }
        var result = cues
        let groups = TranscriptCaptionText.wordIndices(for: cues, words: words)

        for (index, cue) in cues.enumerated() {
            let overlapsCut = cutRanges.contains {
                $0.lowerBound < cue.end && $0.upperBound > cue.start
            }
            guard overlapsCut else { continue }
            result[index].text = TranscriptCaptionText.cutting(
                cue,
                wordIndices: groups[index],
                words: words,
                wasShown: { previous.editorTime(forSourceTime: words[$0].midpoint) != nil },
                isShown: { timeline.editorTime(forSourceTime: words[$0].midpoint) != nil }
            )
        }
        return result
    }

    // MARK: - Caption revisions

    /// Finds fillers to hide from the captions: pure hesitation sounds by
    /// rule, words that are fillers only in context by the configured AI.
    /// Nothing changes until the suggestions are reviewed and applied.
    func suggestCaptionFillers() {
        guard hasTranscriptWords, !captionCleanupState.isRunning else { return }
        let words = transcriptWords
        let candidates = captionCleanupCandidates()
        let rules = CaptionCleanupPlanner.ruleSuggestions(in: words, candidates: candidates)

        runCaptionCleanup(
            .fillers,
            candidates: candidates,
            instructions: CaptionCleanupPlanner.fillerInstructions,
            read: { reply, chunk in
                guard let picked = CaptionCleanupPlanner.parseFillerResponse(reply) else {
                    throw CaptionCleanupError.unreadable(reply)
                }
                return CaptionCleanupPlanner.validatedModelFillers(picked, chunk: chunk, words: words)
            },
            // Without AI the rules still find the hesitation sounds.
            finish: { [weak self] modelIndices in
                self?.fillerSuggestions = CaptionCleanupPlanner.merged(rules: rules, modelIndices: modelIndices)
                return !rules.isEmpty || !modelIndices.isEmpty
            }
        )
    }

    /// Asks the configured AI to fix misheard words - homophones, names,
    /// technical terms, punctuation - as small reviewed edits.
    func suggestCaptionCorrections() {
        guard hasTranscriptWords, !captionCleanupState.isRunning else { return }
        let words = transcriptWords
        runCaptionCleanup(
            .corrections,
            candidates: captionCleanupCandidates(),
            instructions: CaptionCleanupPlanner.correctionInstructions,
            read: { reply, chunk in
                guard let fixes = CaptionCleanupPlanner.parseCorrectionResponse(reply) else {
                    throw CaptionCleanupError.unreadable(reply)
                }
                return CaptionCleanupPlanner.validatedCorrections(fixes, chunk: chunk, words: words)
            },
            finish: { [weak self] corrections in
                self?.correctionSuggestions = corrections
                return !corrections.isEmpty
            }
        )
    }

    /// Words worth sending: still shown, still in the video, and not in a
    /// caption the user retyped.
    private func captionCleanupCandidates() -> [Int] {
        let surviving = Set(transcriptWords.indices.filter(transcriptWordSurvives))
        let handEdited = CaptionCleanupPlanner.wordsInHandEditedCaptions(
            words: transcriptWords,
            cues: subtitleCues,
            isIncluded: surviving.contains
        )
        return CaptionCleanupPlanner.candidateIndices(in: transcriptWords) {
            surviving.contains($0) && !handEdited.contains($0)
        }
    }

    /// The shared cleanup loop: one model request per chunk, progress as it
    /// goes, then review. A failed request keeps what earlier chunks found
    /// and says why in the review. `finish` stores the results and reports
    /// whether there is anything to review.
    private func runCaptionCleanup<Result: Sendable>(
        _ kind: CaptionCleanupKind,
        candidates: [Int],
        instructions: String,
        read: @escaping (String, CaptionCleanupChunk) throws -> [Result],
        finish: @escaping ([Result]) -> Bool
    ) {
        discardCaptionCleanup()
        captionCleanupKind = kind
        let words = transcriptWords

        let engine: any CaptionCleanupEngine
        do {
            engine = try CaptionCleanupEngines.engine(for: CaptionAISettingsStore.shared.snapshot())
        } catch {
            captionCleanupNotice = error.localizedDescription
            presentCaptionCleanup(hasResults: finish([]))
            return
        }

        let chunks = CaptionCleanupPlanner.chunks(
            candidates: candidates,
            words: words,
            cues: subtitleCues,
            maximumWords: engine.maximumWordsPerRequest
        )
        captionCleanupState = .running(completed: 0, total: chunks.count)
        captionCleanupTask = Task { [weak self] in
            var results: [Result] = []
            for (position, chunk) in chunks.enumerated() {
                do {
                    let reply = try await engine.respond(
                        instructions: instructions,
                        prompt: CaptionCleanupPlanner.prompt(for: chunk, words: words)
                    )
                    results += try read(reply, chunk)
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                    self.captionCleanupNotice = error.localizedDescription
                    break
                }
                guard !Task.isCancelled, let self else { return }
                self.captionCleanupState = .running(completed: position + 1, total: chunks.count)
            }
            guard !Task.isCancelled, let self else { return }
            // The transcript may have been replaced while the AI worked.
            guard self.transcriptWords == words else {
                self.discardCaptionCleanup()
                return
            }
            self.presentCaptionCleanup(hasResults: finish(results))
        }
    }

    private func presentCaptionCleanup(hasResults: Bool) {
        captionCleanupTask = nil
        if !hasResults, let notice = captionCleanupNotice {
            captionCleanupState = .failed(notice)
        } else {
            captionCleanupState = .reviewing
        }
    }

    func toggleFillerSuggestion(wordIndex: Int) {
        guard let index = fillerSuggestions.firstIndex(where: { $0.wordIndex == wordIndex }) else { return }
        fillerSuggestions[index].isAccepted.toggle()
    }

    func toggleCorrectionSuggestion(id: Int) {
        guard let index = correctionSuggestions.firstIndex(where: { $0.id == id }) else { return }
        correctionSuggestions[index].isAccepted.toggle()
    }

    func setAllCaptionCleanupSuggestions(accepted: Bool) {
        for index in fillerSuggestions.indices {
            fillerSuggestions[index].isAccepted = accepted
        }
        for index in correctionSuggestions.indices {
            correctionSuggestions[index].isAccepted = accepted
        }
    }

    var captionCleanupSuggestionCount: Int {
        captionCleanupKind == .fillers ? fillerSuggestions.count : correctionSuggestions.count
    }

    var acceptedCaptionCleanupSuggestionCount: Int {
        captionCleanupKind == .fillers
            ? fillerSuggestions.count(where: \.isAccepted)
            : correctionSuggestions.count(where: \.isAccepted)
    }

    /// Applies the accepted suggestions to the captions in one undoable step.
    func applyCaptionCleanup() {
        let kind = captionCleanupKind
        let revisions = kind == .fillers
            ? CaptionCleanupPlanner.revisions(for: fillerSuggestions, words: transcriptWords)
            : CaptionCleanupPlanner.revisions(for: correctionSuggestions, words: transcriptWords)
        discardCaptionCleanup()
        applyCaptionRevisions(
            revisions,
            actionName: kind == .fillers
                ? String(localized: "Remove Fillers from Captions")
                : String(localized: "Correct Captions")
        )
    }

    /// Stops a running cleanup or drops its suggestions unapplied.
    func discardCaptionCleanup() {
        captionCleanupTask?.cancel()
        captionCleanupTask = nil
        fillerSuggestions = []
        correctionSuggestions = []
        captionCleanupNotice = nil
        captionCleanupState = .idle
    }

    /// The captions holding suggestions, each with its words, for review.
    var captionCleanupReviewCaptions: [(cue: RecordingSubtitleCue, wordIndices: [Int])] {
        let suggested: Set<Int> = captionCleanupKind == .fillers
            ? Set(fillerSuggestions.map(\.wordIndex))
            : Set(correctionSuggestions.flatMap(\.wordIndices))
        guard !suggested.isEmpty else { return [] }
        let groups = TranscriptCaptionText.wordIndices(for: subtitleCues, words: transcriptWords)
        return zip(subtitleCues, groups)
            .filter { $0.1.contains(where: suggested.contains) }
            .sorted { $0.0.start < $1.0.start }
            .map { (cue: $0.0, wordIndices: $0.1) }
    }

    /// Words corrected or hidden in captions, for "Restore Original".
    var hasCaptionRevisions: Bool {
        transcriptWords.contains(where: \.hasCaptionRevision)
    }

    /// Applies reviewed caption revisions - corrections and hidden fillers -
    /// as one undoable step. The words keep their audio and timing; only
    /// the captions they produce change.
    func applyCaptionRevisions(_ revisions: [Int: TranscriptWordRevision], actionName: String) {
        let revised = TranscriptCaptionText.applying(
            revisions,
            to: transcriptWords,
            cues: subtitleCues,
            isIncluded: transcriptWordSurvives
        )
        applyTranscript(words: revised.words, cues: revised.cues, actionName: actionName)
    }

    /// Clears every correction and hidden filler, back to what the
    /// recognizer heard. Captions edited by hand keep their text.
    func restoreOriginalCaptions() {
        let revisions = Dictionary(
            uniqueKeysWithValues: transcriptWords.indices
                .filter { transcriptWords[$0].hasCaptionRevision }
                .map { ($0, TranscriptWordRevision.original) }
        )
        applyCaptionRevisions(revisions, actionName: String(localized: "Restore Original Captions"))
    }

    private func applyTranscript(
        words: [RecordingTranscriptWord],
        cues: [RecordingSubtitleCue],
        actionName: String
    ) {
        guard words != transcriptWords || cues != subtitleCues else { return }
        let previousWords = transcriptWords
        let previousCues = subtitleCues
        registerUndo(actionName) { target in
            target.applyTranscript(words: previousWords, cues: previousCues, actionName: actionName)
        }
        transcriptWords = words
        subtitleCues = cues
        subtitleTimeline = SubtitleTimeline(cues: cues)
        karaokeTimeline = KaraokeTimeline(cues: cues, words: words)
        scheduleProjectSave()
    }

    /// Recomputes which word the playhead is on; assigns only on change so
    /// observation-driven views wake on word boundaries, not every tick.
    private func updateActiveTranscriptWord() {
        guard !transcriptWords.isEmpty else {
            if activeTranscriptWordIndex != nil {
                activeTranscriptWordIndex = nil
            }
            return
        }
        let index = Self.transcriptWordIndex(
            at: clipTimeline.sourceTime(at: currentTime),
            in: transcriptWords
        )
        if activeTranscriptWordIndex != index {
            activeTranscriptWordIndex = index
        }
    }

    /// Last word started at or before this source time, if the time is
    /// still within it (with a small bridge across inter-word gaps so the
    /// highlight doesn't flicker between words).
    private static func transcriptWordIndex(
        at sourceTime: TimeInterval,
        in words: [RecordingTranscriptWord]
    ) -> Int? {
        guard sourceTime.isFinite, !words.isEmpty else { return nil }
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].start <= sourceTime {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low - 1
        guard index >= 0 else { return nil }
        return sourceTime <= words[index].end + 0.25 ? index : nil
    }

    /// Caption to draw over the card right now; nil when hidden or silent.
    func keystrokeCaption(at time: TimeInterval) -> KeystrokeCaptionFrame? {
        guard showsKeystrokes, hasKeystrokes else { return nil }
        return keystrokeTimeline.frame(at: clipTimeline.sourceTime(at: time))
    }

    private var recordingPointSize: CGSize {
        let scale = max(CGFloat(manifest?.pixelScale ?? 1), 1)
        return CGSize(width: videoSize.width / scale, height: videoSize.height / scale)
    }

    // MARK: - Video crop

    var isVideoCropped: Bool {
        RecordingVideoCropGeometry.isCropped(videoCropRect)
    }

    var videoCropPixelSize: CGSize {
        let crop = isCroppingVideo ? workingVideoCropRect : videoCropRect
        return CGSize(
            width: (videoSize.width * crop.width).rounded(),
            height: (videoSize.height * crop.height).rounded()
        )
    }

    func beginVideoCrop() {
        guard !isCroppingVideo, videoSize.width > 0, videoSize.height > 0 else {
            return
        }
        pause()
        endPoseAdjustment()
        workingVideoCropRect = videoCropRect
        videoCropAspect = .freeform
        isCroppingVideo = true
    }

    func cancelVideoCrop() {
        guard isCroppingVideo else { return }
        workingVideoCropRect = videoCropRect
        videoCropAspect = .freeform
        isCroppingVideo = false
    }

    func resetVideoCrop() {
        guard isCroppingVideo else { return }
        if let ratio = videoCropAspect.normalizedRatio(imageSize: videoSize) {
            workingVideoCropRect = CropRectEditor.applyAspect(
                to: CropRectEditor.unit,
                aspect: ratio
            )
        } else {
            workingVideoCropRect = CropRectEditor.unit
        }
    }

    func setVideoCropAspect(_ aspect: CropAspectRatio) {
        videoCropAspect = aspect
        guard isCroppingVideo,
              let ratio = aspect.normalizedRatio(imageSize: videoSize) else {
            return
        }
        workingVideoCropRect = CropRectEditor.applyAspect(
            to: workingVideoCropRect,
            aspect: ratio
        )
    }

    func moveVideoCrop(from start: CGRect, byNormalized delta: CGSize) {
        guard isCroppingVideo else { return }
        workingVideoCropRect = CropRectEditor.move(start, by: delta)
    }

    func updateVideoCrop(handle: CropHandle, toNormalized point: CGPoint) {
        guard isCroppingVideo else { return }
        let aspect = handle.isCorner
            ? videoCropAspect.normalizedRatio(imageSize: videoSize)
            : nil
        workingVideoCropRect = CropRectEditor.resize(
            workingVideoCropRect,
            handle: handle,
            to: point,
            aspect: aspect,
            minWidth: min(1, 24 / max(videoSize.width, 1)),
            minHeight: min(1, 24 / max(videoSize.height, 1)),
            fromCenter: isVideoCropCenterResizeModifierPressed
        )
    }

    func applyVideoCrop() {
        guard isCroppingVideo else { return }
        let next = RecordingVideoCropGeometry.normalized(workingVideoCropRect)
        isCroppingVideo = false
        videoCropAspect = .freeform
        workingVideoCropRect = next
        applyVideoCrop(next, actionName: String(localized: "Crop Video"))
    }

    private func applyVideoCrop(_ requested: CGRect, actionName: String) {
        let next = RecordingVideoCropGeometry.normalized(requested)
        guard next != videoCropRect else { return }
        let previous = videoCropRect
        registerUndo(actionName) { target in
            target.applyVideoCrop(previous, actionName: actionName)
        }
        videoCropRect = next
    }

    private var isVideoCropCenterResizeModifierPressed: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.option) || (flags.contains(.command) && flags.contains(.shift))
    }

    func isCameraVisible(at time: TimeInterval) -> Bool {
        // No time gate: before cameraOffset the player is parked on the
        // camera's first frame, which beats the bubble popping in late.
        hasCameraVideo && style.camera.isVisible
    }

    // MARK: - Export

    private func makeExportConfiguration() -> RecordingStudioExporter.Configuration {
        let reframe = makeReframeTrack()
        let fitContentAspect: CGFloat? =
            (exportAspect == .original || exportAspectMode == .fit) && videoSize.height > 0
                ? videoSize.width / videoSize.height
                : nil
        return RecordingStudioExporter.Configuration(
            screenURL: screenURL,
            cameraURL: hasCameraVideo && style.camera.isVisible ? session?.cameraURL : nil,
            cameraOffset: cameraOffset,
            style: style,
            viewportTimeline: zoomEnabled ? viewportTimeline : .identity,
            pointerTimeline: pointerIsSynthesized ? pointerTimeline : nil,
            showsPressEffects: showsPressEffects,
            keystrokeTimeline: showsKeystrokes && hasKeystrokes ? keystrokeTimeline : nil,
            keystrokePlacement: keystrokePlacement,
            subtitleTimeline: showsSubtitles && hasSubtitles ? subtitleTimeline : nil,
            subtitleStyle: subtitleStyle,
            karaokeTimeline: showsSubtitles && hasSubtitles && !karaokeTimeline.isEmpty
                ? karaokeTimeline
                : nil,
            canvasSize: basePreviewCanvasSize,
            videoCropRect: videoCropRect,
            clipTimeline: clipTimeline,
            exportSettings: exportSettings,
            audioReplacementURL: replacementAudio?.url,
            audioVolume: Double(audioVolume),
            normalizesAudioLoudness: normalizesAudioLoudness,
            backgroundMusic: loadedBackgroundMusic.flatMap { music in
                backgroundMusicPlan(for: music).map { BackgroundMusicExport(url: music.url, plan: $0) }
            },
            reframe: reframe,
            fitContentAspect: fitContentAspect,
            usesUniformPadding: exportAspect == .original,
            motionTimeline: motionTimeline,
            imageOverlays: imageOverlays,
            assetsDirectory: session.map { RecordingStudioAssets.directory(in: $0.directoryURL) }
        )
    }

    /// The crop-and-follow camera for non-original aspect exports. Focus
    /// comes from the recorded pointer whenever the session captured one,
    /// whether or not the cursor is drawn synthetically.
    private func makeReframeTrack() -> ReframeTrack? {
        guard exportAspect != .original, exportAspectMode == .fill else { return nil }
        let focusTimeline = reframeFocusPointer()
        let effectiveViewport = zoomEnabled ? viewportTimeline : .identity
        return ReframeTrack.build(
            preset: exportAspect,
            sourceSize: videoSize,
            viewportTimeline: effectiveViewport,
            duration: duration
        ) { editorTime in
            focusTimeline?.location(at: editorTime)
        }
    }

    /// The focus source is immutable per session, so it resolves once.
    private func reframeFocusPointer() -> PointerTimeline? {
        if reframeFocusResolved { return reframeFocusTimeline }
        reframeFocusResolved = true
        if pointerIsSynthesized {
            reframeFocusTimeline = pointerTimeline
        } else if !pointerCapture.travel.isEmpty || !pointerCapture.presses.isEmpty {
            reframeFocusTimeline = PointerTimeline.build(
                capture: pointerCapture,
                duration: sourceDuration,
                recordingSizeInPoints: recordingPointSize,
                fallbackArtwork: PointerArtworkCapture.defaultArtwork(),
                clipTimeline: clipTimeline
            )
        }
        return reframeFocusTimeline
    }

    private func rebuildPreviewReframe() {
        guard isLoaded else { return }
        previewReframe = makeReframeTrack()
    }

    // MARK: - Preview canvas

    /// What the Studio canvas shows: the target-aspect canvas when a
    /// non-original aspect is selected, the visible source plus padding otherwise.
    var basePreviewCanvasSize: CGSize {
        exportAspect == .original
            ? RecordingStudioLayout.originalCanvasSize(
                sourceSize: videoSize, style: style, contentCropRect: videoCropRect
            )
            : exportAspect.canvasSize(for: videoSize)
    }

    var previewCanvasSize: CGSize {
        if exportAspect == .original, isCroppingVideo {
            RecordingStudioLayout.originalCanvasSize(
                sourceSize: videoSize, style: style, contentCropRect: CropRectEditor.unit
            )
        } else {
            basePreviewCanvasSize
        }
    }

    var sourceVideoAspect: CGFloat {
        videoSize.height > 0 ? videoSize.width / videoSize.height : 1
    }

    /// The source aspect remains independent of the padded canvas and video crop.
    var previewContentAspect: CGFloat? {
        guard videoSize.height > 0 else { return nil }
        return sourceVideoAspect
    }

    var previewVideoCropRect: CGRect {
        isCroppingVideo ? CropRectEditor.unit : videoCropRect
    }

    /// How the content occupies the card on a target-aspect canvas.
    var previewContentMode: RecordingStudioLayout.ContentMode {
        exportAspect == .original || exportAspectMode == .fit ? .fit : .fill
    }

    /// Virtual camera for the preview: the reframe crop when active, the
    /// zoom viewport otherwise (including Fit mode, where zooms play
    /// inside the fitted card).
    func previewViewportFrame(at time: TimeInterval) -> ViewportFrame {
        let base = previewReframe?.frame(at: time) ?? viewportFrame(at: time)
        return RecordingVideoCropGeometry.viewport(base, crop: previewVideoCropRect)
    }

    /// The flattened deliverable when it provably matches the current
    /// in-memory edits - the render is stamped with the document that
    /// produced it. Both Export and Share can then skip the render entirely.
    private var freshDeliverableURL: URL? {
        // Measure the actual renderer during development comparisons, even
        // when this exact document already has a flattened deliverable.
        guard ProcessInfo.processInfo.environment["FRAMECHO_EXPORT_BYPASS_CACHE"] != "1" else { return nil }
        guard let session else { return nil }
        return session.freshFinalURL(matching: currentDocument())
    }

    private var exportSuggestedFileName: String {
        let container = exportSettings.effectiveContainer
        return session.map {
            $0.directoryURL
                .deletingPathExtension()
                .lastPathComponent
                .appending(".\(container.fileExtension)")
        } ?? VideoFileActions.exportFileName(for: screenURL, container: container)
    }

    /// Entry point for the export options popover. Assigning settings marks
    /// the project dirty and drops the cached render, so an unchanged
    /// confirmation must not touch them.
    func export(settings: VideoCompressionSettings) {
        if settings != exportSettings {
            exportSettings = settings
        }
        export()
    }

    func export() {
        // One render at a time: the share pipeline uses the same exporter,
        // so a second encode would just fight it for the media engine.
        guard !exportState.isExporting, !shareState.isBusy, isLoaded else { return }
        pause()
        let previewURL = sessionURL

        // A fresh deliverable (e.g. right after a share) is byte-identical
        // to what this render would produce - same configuration builds
        // both - so exporting becomes a plain copy into the save folder.
        if let cached = freshDeliverableURL {
            let suggestedFileName = exportSuggestedFileName
            exportTask = Task { [weak self] in
                do {
                    let savedURL = try await VideoFileActions.saveToDefaultLocation(
                        from: cached,
                        suggestedFileName: suggestedFileName
                    )
                    RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                    RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                    ScreenshotPreviewStack.shared.dismissVideo(for: previewURL)
                    self?.exportState = .finished(savedURL)
                } catch {
                    self?.exportState = .failed(error.localizedDescription)
                }
            }
            return
        }

        exportState = .exporting(progress: 0)

        let configuration = makeExportConfiguration()
        let suggestedFileName = exportSuggestedFileName

        let dockProgressID = DockExportProgressCoordinator.shared.start()

        exportTask = Task { [weak self] in
            do {
                let exporter = RecordingStudioExporter()
                let temporaryURL = try await exporter.export(configuration) { progress in
                    Task { @MainActor [weak self] in
                        DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                        if self?.exportState.isExporting == true {
                            self?.exportState = .exporting(progress: progress)
                        }
                    }
                }
                let savedURL = try await VideoFileActions.saveToDefaultLocation(
                    from: temporaryURL,
                    suggestedFileName: suggestedFileName
                )
                try? FileManager.default.removeItem(at: temporaryURL)
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                ScreenshotPreviewStack.shared.dismissVideo(for: previewURL)
                self?.exportState = .finished(savedURL)
            } catch is CancellationError {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.exportState = .idle
            } catch RecordingStudioExporter.ExportError.cancelled {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.exportState = .idle
            } catch {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.exportState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        if exportState.isExporting {
            exportState = .idle
        }
    }

    // MARK: - Image overlays

    var selectedImageOverlay: RecordingImageOverlay? {
        imageOverlays.first { $0.id == selectedImageOverlayID }
    }

    /// Copies an image into the project and lays it over the video from
    /// `editorTime`, centered at the default size. Returns its id.
    @discardableResult
    func addImageOverlay(from url: URL, at editorTime: TimeInterval) throws -> UUID {
        guard let session else {
            throw RecordingStudioAssets.ImportError.unreadable(url.lastPathComponent)
        }
        let imported = try RecordingStudioAssets.importImage(from: url, into: session.directoryURL)
        let start = sourceTime(atEditorTime: min(max(editorTime, 0), duration))
        let end = min(sourceDuration, start + RecordingImageOverlay.defaultDuration)
        var overlay = RecordingImageOverlay(
            fileName: imported.fileName,
            displayName: imported.displayName,
            aspectRatio: imported.aspectRatio,
            start: max(0, min(start, end - RecordingImageOverlay.minimumDuration)),
            end: end
        )
        // A tall image would cover the picture at the default width; keep it
        // to half the canvas height.
        let canvas = basePreviewCanvasSize
        if canvas.width > 0 {
            let maximumWidth = 0.5 * canvas.height * imported.aspectRatio / canvas.width
            overlay.width = max(RecordingImageOverlay.widthRange.lowerBound, min(overlay.width, maximumWidth))
        }
        loadImageOverlayPreview(named: overlay.fileName)
        applyImageOverlays(imageOverlays + [overlay], actionName: String(localized: "Add Image"))
        selectedImageOverlayID = overlay.id
        return overlay.id
    }

    func removeImageOverlay(id: UUID) {
        applyImageOverlays(imageOverlays.filter { $0.id != id }, actionName: String(localized: "Remove Image"))
        if selectedImageOverlayID == id {
            selectedImageOverlayID = nil
        }
    }

    /// Changes an image's look, place or timing. `coalesces` folds a run of
    /// changes - a slider drag, a canvas drag - into one undo step.
    func updateImageOverlay(_ overlay: RecordingImageOverlay, coalesces: Bool = false) {
        guard let index = imageOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        var updated = overlay.sanitized
        updated.start = min(max(0, updated.start), max(0, sourceDuration - RecordingImageOverlay.minimumDuration))
        updated.end = min(sourceDuration, max(updated.end, updated.start + RecordingImageOverlay.minimumDuration))
        var next = imageOverlays
        next[index] = updated
        guard next != imageOverlays else { return }
        if coalesces {
            beginImageOverlayEdit()
            replaceImageOverlays(next)
            imageOverlayEditCommitTask?.cancel()
            imageOverlayEditCommitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.imageOverlayEditCommitTask = nil
                self?.endImageOverlayEdit()
            }
        } else if imageOverlayEditSnapshot != nil, imageOverlayEditCommitTask == nil {
            // Inside an explicit begin/end pair, such as a timeline drag.
            replaceImageOverlays(next)
        } else {
            commitPendingImageOverlayEdit()
            applyImageOverlays(next, actionName: String(localized: "Edit Image"))
        }
    }

    /// Slides an image along the timeline, keeping its length.
    func moveImageOverlay(id: UUID, toStart start: TimeInterval) {
        guard var overlay = imageOverlays.first(where: { $0.id == id }) else { return }
        let length = overlay.duration
        overlay.start = min(max(0, start), max(0, sourceDuration - length))
        overlay.end = overlay.start + length
        updateImageOverlay(overlay)
    }

    func beginImageOverlayEdit() {
        if imageOverlayEditSnapshot == nil {
            imageOverlayEditSnapshot = imageOverlays
        }
    }

    func endImageOverlayEdit(actionName: String = String(localized: "Edit Image")) {
        guard let previous = imageOverlayEditSnapshot else { return }
        imageOverlayEditSnapshot = nil
        guard previous != imageOverlays else { return }
        registerUndo(actionName) { target in
            target.applyImageOverlays(previous, actionName: actionName)
        }
    }

    private func commitPendingImageOverlayEdit() {
        guard let task = imageOverlayEditCommitTask else { return }
        task.cancel()
        imageOverlayEditCommitTask = nil
        endImageOverlayEdit()
    }

    private func applyImageOverlays(_ overlays: [RecordingImageOverlay], actionName: String) {
        guard overlays != imageOverlays else { return }
        let previous = imageOverlays
        registerUndo(actionName) { target in
            target.applyImageOverlays(previous, actionName: actionName)
        }
        replaceImageOverlays(overlays)
    }

    private func replaceImageOverlays(_ overlays: [RecordingImageOverlay]) {
        imageOverlays = overlays
        if let selectedImageOverlayID, !overlays.contains(where: { $0.id == selectedImageOverlayID }) {
            self.selectedImageOverlayID = nil
        }
        rebuildImageOverlayTimeline()
        scheduleProjectSave()
    }

    private func rebuildImageOverlayTimeline() {
        imageOverlayTimeline = RecordingImageOverlayTimeline(overlays: imageOverlays, clipTimeline: clipTimeline)
    }

    func imageOverlayFrames(at time: TimeInterval) -> [RecordingImageOverlayTimeline.Frame] {
        imageOverlayTimeline.frames(at: time)
    }

    /// The subtitle bar's band on a canvas of this size while subtitles
    /// show, which preset-placed images keep clear of. Matches the export.
    func imageOverlayCaptionBand(canvasSize: CGSize) -> ClosedRange<CGFloat>? {
        guard showsSubtitles, hasSubtitles else { return nil }
        return RecordingImageOverlayLayout.captionBand(
            canvasSize: canvasSize,
            verticalPosition: subtitleStyle.clampedVerticalPosition,
            fontSize: SubtitleBarMetrics(canvasSize: canvasSize, style: subtitleStyle).fontSize
        )
    }

    private func loadImageOverlayPreviews() {
        for overlay in imageOverlays {
            loadImageOverlayPreview(named: overlay.fileName)
        }
    }

    /// Decodes at a size that stays sharp on a Retina preview without
    /// holding full-resolution photos in memory.
    private func loadImageOverlayPreview(named fileName: String) {
        guard imageOverlayPreviews[fileName] == nil, let session else { return }
        if let image = RecordingStudioAssets.loadImage(named: fileName, in: session.directoryURL, maxPixelSize: 1600) {
            imageOverlayPreviews[fileName] = image
        }
    }

    // MARK: - Background music

    /// The music's level over the cut, for the timeline's music lane.
    var backgroundMusicTimelinePlan: BackgroundMusicGainPlan? {
        loadedBackgroundMusic.flatMap(backgroundMusicPlan(for:))
    }

    /// Ducking needs the narration's words; without a transcript the music
    /// simply plays at its level.
    var canDuckBackgroundMusic: Bool {
        hasTranscriptWords
    }

    func chooseBackgroundMusic(_ track: BackgroundMusicTrack) {
        var next = backgroundMusic ?? RecordingBackgroundMusic(trackID: track.id)
        next.trackID = track.id
        applyBackgroundMusic(next, actionName: String(localized: "Choose Music"))
    }

    func removeBackgroundMusic() {
        applyBackgroundMusic(nil, actionName: String(localized: "Remove Music"))
    }

    var backgroundMusicVolume: Double {
        get { backgroundMusic?.clampedVolume ?? RecordingBackgroundMusic.defaultVolume }
        set {
            guard var music = backgroundMusic, music.volume != newValue else { return }
            music.volume = newValue
            backgroundMusic = music
            updatePlaybackVolume()
            scheduleProjectSave()
        }
    }

    /// Looping changes how many passes the composition holds, so it
    /// rebuilds playback rather than just the mix.
    var backgroundMusicLoops: Bool {
        get { backgroundMusic?.loops ?? true }
        set {
            guard var music = backgroundMusic, music.loops != newValue else { return }
            music.loops = newValue
            backgroundMusic = music
            try? rebuildScreenPlayerItem(preserving: currentTime)
            scheduleProjectSave()
        }
    }

    var backgroundMusicDucksUnderSpeech: Bool {
        get { backgroundMusic?.ducksUnderSpeech ?? true }
        set {
            guard var music = backgroundMusic, music.ducksUnderSpeech != newValue else { return }
            music.ducksUnderSpeech = newValue
            backgroundMusic = music
            updatePlaybackVolume()
            scheduleProjectSave()
        }
    }

    /// Picking or removing a track is undoable; level and ducking are
    /// continuous settings, like the soundtrack's volume.
    private func applyBackgroundMusic(_ music: RecordingBackgroundMusic?, actionName: String) {
        guard music != backgroundMusic else { return }
        let previous = backgroundMusic
        registerUndo(actionName) { target in
            target.applyBackgroundMusic(previous, actionName: actionName)
        }
        backgroundMusic = music
        resolveBackgroundMusic()
        scheduleProjectSave()
    }

    /// How the loaded track sits under this cut: its level, fades, and dips
    /// under the narration's words.
    private func backgroundMusicPlan(for music: LoadedBackgroundMusic) -> BackgroundMusicGainPlan? {
        guard let settings = backgroundMusic, settings.trackID == music.trackID else { return nil }
        let timeline = clipTimeline
        let speech = settings.ducksUnderSpeech
            ? BackgroundMusicGainPlan.speechRanges(words: transcriptWords) { timeline.editorTime(forSourceTime: $0) }
            : []
        return BackgroundMusicGainPlan(
            musicDuration: music.duration,
            videoDuration: duration,
            volume: settings.clampedVolume,
            speech: speech,
            loops: settings.loops,
            isSeamlessLoop: settings.track?.isSeamlessLoop ?? false,
            loopRegion: music.loopRegion
        )
    }

    /// Loads the chosen track from the cache without downloading, so a
    /// project opens already playing its music when it can.
    private func loadCachedBackgroundMusic() async {
        guard let music = backgroundMusic else {
            loadedBackgroundMusic = nil
            return
        }
        guard loadedBackgroundMusic?.trackID != music.trackID,
              let track = music.track,
              let url = BackgroundMusicCatalog.cachedFileIfPresent(for: track) else {
            return
        }
        let loaded = await LoadedBackgroundMusic.load(trackID: music.trackID, url: url)
        guard !isTornDown, backgroundMusic?.trackID == music.trackID else { return }
        loadedBackgroundMusic = loaded
    }

    /// Brings playback in line with the chosen track: drops music that is
    /// no longer chosen, and downloads and loads a new choice before
    /// rebuilding the player item with it.
    private func resolveBackgroundMusic() {
        backgroundMusicTask?.cancel()
        backgroundMusicTask = nil
        isLoadingBackgroundMusic = false
        backgroundMusicError = nil

        if loadedBackgroundMusic != nil, loadedBackgroundMusic?.trackID != backgroundMusic?.trackID {
            loadedBackgroundMusic = nil
            try? rebuildScreenPlayerItem(preserving: currentTime)
        }
        guard let music = backgroundMusic else { return }
        if loadedBackgroundMusic != nil {
            if playbackMusicTrackIDs.isEmpty {
                try? rebuildScreenPlayerItem(preserving: currentTime)
            } else {
                updatePlaybackVolume()
            }
            return
        }
        guard let track = music.track else {
            backgroundMusicError = String(localized: "This track is no longer in the music library.")
            return
        }

        isLoadingBackgroundMusic = true
        backgroundMusicTask = Task { [weak self] in
            do {
                let url = try await BackgroundMusicStore.shared.localURL(for: track)
                let loaded = await LoadedBackgroundMusic.load(trackID: track.id, url: url)
                guard let self, !Task.isCancelled, !self.isTornDown,
                      self.backgroundMusic?.trackID == track.id else { return }
                self.isLoadingBackgroundMusic = false
                self.backgroundMusicTask = nil
                guard let loaded else {
                    self.backgroundMusicError = String(localized: "The music file couldn't be read.")
                    return
                }
                self.loadedBackgroundMusic = loaded
                try? self.rebuildScreenPlayerItem(preserving: self.currentTime)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.isLoadingBackgroundMusic = false
                self.backgroundMusicTask = nil
                self.backgroundMusicError = error.localizedDescription
            }
        }
    }

    // MARK: - Audio only

    /// True once there is a soundtrack to export or swap - the recording's
    /// own audio, or one already imported over it.
    var hasAudio: Bool {
        hasRecordedAudio || replacementAudio != nil
    }

    /// How far the imported soundtrack falls short of (or overruns) the
    /// edited timeline. Nil when there is nothing imported or the two
    /// agree closely enough to be the same take.
    var replacementAudioDrift: TimeInterval? {
        guard let replacementAudio else { return nil }
        let drift = replacementAudio.duration - duration
        return abs(drift) > 0.25 ? drift : nil
    }

    private var audioExportSuggestedFileName: String {
        let base = session.map {
            $0.directoryURL.deletingPathExtension().lastPathComponent
        } ?? screenURL.deletingPathExtension().lastPathComponent
        return "\(base).\(audioExportFormat.fileExtension)"
    }

    /// Writes the edited soundtrack on its own, for cleanup in a tool that
    /// has no API - the outbound half of the replace-audio round trip.
    func exportAudio() {
        guard !audioExportState.isExporting, isLoaded, hasAudio else { return }
        pause()

        audioExportState = .exporting(progress: 0)

        let configuration = RecordingAudioExporter.Configuration(
            screenURL: screenURL,
            clipTimeline: clipTimeline,
            replacementURL: replacementAudio?.url,
            format: audioExportFormat,
            volume: Double(audioVolume),
            normalizesAudioLoudness: normalizesAudioLoudness
        )
        let suggestedFileName = audioExportSuggestedFileName
        let dockProgressID = DockExportProgressCoordinator.shared.start()

        audioExportTask = Task { [weak self] in
            do {
                let temporaryURL = try await RecordingAudioExporter().export(configuration) { progress in
                    Task { @MainActor [weak self] in
                        DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                        if self?.audioExportState.isExporting == true {
                            self?.audioExportState = .exporting(progress: progress)
                        }
                    }
                }
                let savedURL = try await VideoFileActions.saveToDefaultLocation(
                    from: temporaryURL,
                    suggestedFileName: suggestedFileName
                )
                try? FileManager.default.removeItem(at: temporaryURL)
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                self?.audioExportState = .finished(savedURL)
            } catch is CancellationError {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.audioExportState = .idle
            } catch {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.audioExportState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelAudioExport() {
        audioExportTask?.cancel()
        audioExportTask = nil
        if audioExportState.isExporting {
            audioExportState = .idle
        }
    }

    /// The inbound half: adopts a cleaned-up soundtrack as the project's
    /// audio. The file is copied into the session so the project keeps
    /// playing after the original is moved, and playback switches to it
    /// immediately rather than only revealing itself at export.
    func replaceAudio(with pickedURL: URL) {
        guard isLoaded else { return }
        pause()
        replacementAudioTask?.cancel()

        replacementAudioError = nil
        let displayName = pickedURL.lastPathComponent
        let storedURL: URL
        if let session {
            let destination = session.directoryURL
                .appendingPathComponent(RecordingSession.replacementAudioBaseName)
                .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension)
            do {
                // Clear every previous import, whatever extension it had,
                // so the session never accumulates orphaned soundtracks.
                removeStoredReplacementAudio(in: session)
                try FileManager.default.copyItem(at: pickedURL, to: destination)
            } catch {
                replacementAudioError = String(localized: "Could not import that file: \(error.localizedDescription)")
                clearReplacementAudio()
                return
            }
            storedURL = destination
        } else {
            // Bare movies have no project folder to copy into; they
            // reference the picked file where it sits.
            storedURL = pickedURL
        }

        replacementAudioTask = Task { [weak self] in
            let resolved = await RecordingReplacementAudio.load(
                url: storedURL,
                displayName: displayName
            )
            guard let self, !Task.isCancelled else { return }
            guard let resolved else {
                if let session = self.session {
                    self.removeStoredReplacementAudio(in: session)
                }
                self.replacementAudioError = String(localized: "That file has no audio track.")
                self.clearReplacementAudio()
                return
            }
            self.replacementAudio = resolved
            self.applyReplacementAudioToPlayback()
        }
    }

    func removeReplacementAudio() {
        guard replacementAudio != nil else { return }
        replacementAudioTask?.cancel()
        replacementAudioTask = nil
        pause()
        if let session {
            removeStoredReplacementAudio(in: session)
        }
        replacementAudioError = nil
        clearReplacementAudio()
    }

    /// Drops back to the recorded audio, whether that follows a removal or
    /// a failed import that already deleted the copy.
    private func clearReplacementAudio() {
        guard replacementAudio != nil else { return }
        replacementAudio = nil
        applyReplacementAudioToPlayback()
    }

    private func applyReplacementAudioToPlayback() {
        do {
            try rebuildScreenPlayerItem(preserving: currentTime)
        } catch {
            loadError = String(localized: "Could not update the recording timeline: \(error.localizedDescription)")
        }
        scheduleProjectSave()
    }

    private func removeStoredReplacementAudio(in session: RecordingSession) {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: session.directoryURL.path
        )) ?? []
        for name in names
        where name.hasPrefix("\(RecordingSession.replacementAudioBaseName).") {
            try? FileManager.default.removeItem(
                at: session.directoryURL.appendingPathComponent(name)
            )
        }
    }

    // MARK: - Share to cloud

    var canShareToCloud: Bool {
        CloudUploader.shared.isConfigured
    }

    /// The Loom loop: render the current edits, cache the result as the
    /// session's flattened deliverable, upload it, and copy the share
    /// link - without leaving the Studio or touching a save panel.
    func shareToCloud(options: CloudUploadOptions) {
        guard !shareState.isBusy, !exportState.isExporting, isLoaded,
              canShareToCloud else {
            return
        }
        pause()
        // Flush the draft first so the deliverable-invalidation in the
        // debounced autosave can't race the file this render produces.
        projectSaveTask?.cancel()
        writeDraftNow()

        // A fresh deliverable (e.g. sharing again without edits) skips
        // the render and goes straight to upload.
        let cachedDeliverable = freshDeliverableURL
        let configuration = cachedDeliverable == nil ? makeExportConfiguration() : nil
        let session = session
        let renderedDocument = session == nil ? nil : currentDocument()
        shareState = cachedDeliverable == nil ? .rendering(progress: 0) : .uploading

        shareTask = Task { [weak self] in
            // Bare (session-less) videos upload straight from the render's
            // temp file; whatever happens, it must not outlive the share.
            var temporaryUploadURL: URL?
            defer {
                if let temporaryUploadURL {
                    try? FileManager.default.removeItem(at: temporaryUploadURL)
                }
            }
            do {
                let uploadURL: URL
                if let cachedDeliverable {
                    uploadURL = cachedDeliverable
                } else if let configuration {
                    // The render leg gets its own Dock entry; the upload
                    // leg's Dock progress is owned by CloudUploader, so
                    // the two never overlap.
                    let dockProgressID = DockExportProgressCoordinator.shared.start()
                    let temporaryURL: URL
                    do {
                        temporaryURL = try await RecordingStudioExporter().export(configuration) { progress in
                            Task { @MainActor [weak self] in
                                DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                                if case .rendering = self?.shareState {
                                    self?.shareState = .rendering(progress: progress)
                                }
                            }
                        }
                        DockExportProgressCoordinator.shared.finish(dockProgressID)
                    } catch {
                        DockExportProgressCoordinator.shared.finish(dockProgressID)
                        throw error
                    }
                    // From here the deferred cleanup owns the temp render;
                    // once it moves into the session the delete is a
                    // harmless no-op.
                    temporaryUploadURL = temporaryURL

                    // Session recordings keep the render as the flattened
                    // deliverable, so history, preview, and sidecar mapping
                    // all agree on what was shared.
                    if let session {
                        uploadURL = try session.installFinalVideo(
                            movingFrom: temporaryURL,
                            renderedFrom: renderedDocument
                        )
                    } else {
                        uploadURL = temporaryURL
                    }
                } else {
                    return
                }

                guard let self, !Task.isCancelled else { return }
                self.shareState = .uploading
                let itemID = self.historyItemID(for: session) ?? UUID()
                self.shareItemID = itemID
                let result = try await CloudUploader.shared.upload(
                    itemID: itemID,
                    fileURL: uploadURL,
                    title: options.trimmedTitleOrNil
                )

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                if session != nil {
                    ScreenshotHistoryStore.shared.setCloudURL(for: uploadURL, cloudURL: result.url)
                }
                ScreenshotPreviewStack.shared.dismissVideo(for: self.sessionURL)
                self.shareState = .finished(result.url)
            } catch is CancellationError {
                self?.shareState = .idle
            } catch RecordingStudioExporter.ExportError.cancelled {
                self?.shareState = .idle
            } catch {
                self?.shareState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelShare() {
        shareTask?.cancel()
        shareTask = nil
        if let shareItemID {
            CloudUploader.shared.cancelUpload(for: shareItemID)
        }
        if shareState.isBusy {
            shareState = .idle
        }
    }

    /// History item for this session, so the share upload's progress and
    /// resulting link also appear on the preview card.
    private func historyItemID(for session: RecordingSession?) -> UUID? {
        guard let session else { return nil }
        let standardizedPath = session.directoryURL.standardizedFileURL.path
        return ScreenshotHistoryStore.shared.items
            .first { $0.recordingSessionPath == standardizedPath }?
            .id
    }
}

/// A zoom cue's single merged footprint on the edited timeline.
struct RecordingZoomTimelineBlock: Identifiable, Equatable, Sendable {
    let cue: ZoomCue
    let editorStart: TimeInterval
    let editorEnd: TimeInterval

    var id: UUID {
        cue.id
    }
}

struct RecordingMotionTimelineBlock: Identifiable, Equatable, Sendable {
    let cue: RecordingMotionCue
    let editorStart: TimeInterval
    let editorEnd: TimeInterval

    var id: UUID {
        cue.id
    }
}

enum RecordingPoseAdjustmentTarget: Equatable {
    case base
    case cue(UUID)
}
