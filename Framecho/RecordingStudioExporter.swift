//
//  RecordingStudioExporter.swift
//  Framecho
//
//  Offline compositor for studio exports: decodes the screen (and camera)
//  recordings frame by frame, draws each frame through the same
//  RecordingStudioLayout / ViewportTimeline math the live preview
//  uses, and writes a new HEVC movie. Audio tracks (system + microphone)
//  are mixed and passed through on the unchanged timeline, unless the
//  project imported a soundtrack to replace them.
//
//  Everything static - the background fill and the card shadow - is
//  rendered once into a backdrop image. A Metal compute pass draws the
//  screen layer for every frame, blurred or settled; Core Graphics handles
//  rare fallback frames and the per-frame pointer, camera, and caption
//  overlays.
//

import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import OSLog
import SwiftUI
import VideoToolbox

nonisolated final class RecordingStudioExporter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jarinhe.Framecho", category: "StudioExport")

    struct Configuration: Sendable {
        let screenURL: URL
        let cameraURL: URL?
        let cameraOffset: TimeInterval
        let style: RecordingStudioStyle
        let viewportTimeline: ViewportTimeline
        /// Non-nil when the capture hid the OS cursor and the export must
        /// draw the synthetic pointer along this smoothed timeline.
        let pointerTimeline: PointerTimeline?
        let showsPressEffects: Bool
        /// Non-nil when recorded keystroke chords should be captioned.
        let keystrokeTimeline: KeystrokeCaptionTimeline?
        let keystrokePlacement: RecordingKeystrokePlacement
        /// Non-nil when transcribed narration should be subtitled.
        let subtitleTimeline: SubtitleTimeline?
        let subtitleStyle: SubtitleBarStyle
        /// Word timings behind the subtitles, for karaoke highlighting.
        let karaokeTimeline: KaraokeTimeline?
        let canvasSize: CGSize
        /// Normalized top-left crop of the screen-video source.
        let videoCropRect: CGRect
        let clipTimeline: RecordingClipTimeline
        var exportSettings: VideoCompressionSettings
        /// Non-nil when an imported soundtrack stands in for the recorded
        /// audio. It is already the finished cut's audio, so it plays flat
        /// from zero instead of being re-cut through the clip timeline.
        let audioReplacementURL: URL?
        let audioVolume: Double
        /// Non-nil when exporting into a different aspect ratio; drives the
        /// crop-and-follow virtual camera in place of the zoom viewport.
        let reframe: ReframeTrack?
        /// Non-nil for Original or a different aspect ratio in Fit
        /// mode: the recording shows in a content-aspect card and
        /// the background fills the rest. Mutually exclusive with
        /// `reframe`.
        let fitContentAspect: CGFloat?
        let usesUniformPadding: Bool
        /// 3D pose of the video card over the output timeline.
        let motionTimeline: RecordingMotionTimeline

        init(
            screenURL: URL,
            cameraURL: URL?,
            cameraOffset: TimeInterval,
            style: RecordingStudioStyle,
            viewportTimeline: ViewportTimeline,
            pointerTimeline: PointerTimeline?,
            showsPressEffects: Bool,
            keystrokeTimeline: KeystrokeCaptionTimeline?,
            keystrokePlacement: RecordingKeystrokePlacement,
            subtitleTimeline: SubtitleTimeline?,
            subtitleStyle: SubtitleBarStyle,
            karaokeTimeline: KaraokeTimeline? = nil,
            canvasSize: CGSize,
            videoCropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
            clipTimeline: RecordingClipTimeline,
            exportSettings: VideoCompressionSettings,
            audioReplacementURL: URL? = nil,
            audioVolume: Double = 1,
            reframe: ReframeTrack? = nil,
            fitContentAspect: CGFloat? = nil,
            usesUniformPadding: Bool = false,
            motionTimeline: RecordingMotionTimeline = .disabled
        ) {
            self.screenURL = screenURL
            self.cameraURL = cameraURL
            self.cameraOffset = cameraOffset
            self.style = style
            self.viewportTimeline = viewportTimeline
            self.pointerTimeline = style.hidesCursor ? nil : pointerTimeline
            self.showsPressEffects = showsPressEffects
            self.keystrokeTimeline = keystrokeTimeline
            self.keystrokePlacement = keystrokePlacement
            self.subtitleTimeline = subtitleTimeline
            self.subtitleStyle = subtitleStyle
            self.karaokeTimeline = karaokeTimeline
            self.canvasSize = canvasSize
            self.videoCropRect = videoCropRect
            self.clipTimeline = clipTimeline
            self.exportSettings = exportSettings
            self.audioReplacementURL = audioReplacementURL
            self.audioVolume = audioVolume
            self.reframe = reframe
            self.fitContentAspect = fitContentAspect
            self.usesUniformPadding = usesUniformPadding
            self.motionTimeline = motionTimeline
        }
    }

    enum ExportError: LocalizedError {
        case noVideoTrack
        case writerFailed(Error?)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                String(localized: "The recording has no video track.")
            case .writerFailed(let error):
                error?.localizedDescription ?? String(localized: "Writing the exported video failed.")
            case .cancelled:
                String(localized: "Export cancelled.")
            }
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }
    }

    /// `@concurrent` keeps the frame loop off the caller's actor. Callers
    /// are main-actor models, and approachable concurrency would otherwise
    /// run this nonisolated async work - blocking reader calls included -
    /// on the main thread alongside the UI.
    @concurrent
    func export(
        _ configuration: Configuration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let cancelFlag = CancelFlag()
        let started = CFAbsoluteTimeGetCurrent()
        return try await withTaskCancellationHandler {
            let result = try await run(configuration, cancelFlag: cancelFlag, progress: progress)
            Self.logger.info("Export completed totalSeconds=\(CFAbsoluteTimeGetCurrent() - started)")
            return result
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    private func run(
        _ configuration: Configuration,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let timing = RecordingExportTiming(settings: configuration.exportSettings)
        let sourceAsset = AVURLAsset(url: configuration.screenURL)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        let clipTimeline = configuration.clipTimeline.normalized(to: sourceDuration)
        guard clipTimeline.duration >= RecordingClipSegment.minimumDuration else {
            throw VideoTrimExportError.invalidRange
        }
        let screenAsset = try RecordingCompositionBuilder.makeAsset(
            from: sourceAsset,
            timeline: clipTimeline,
            sourceDuration: sourceDuration
        )
        guard let videoTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTracks = try await screenAsset.loadTracks(withMediaType: .audio)
        let exportStartTime = CMTime.zero
        let exportTimeRange = CMTimeRange(
            start: exportStartTime,
            duration: CMTime(seconds: clipTimeline.duration, preferredTimescale: 600)
        )

        let outputSize = Self.outputSize(
            source: configuration.canvasSize,
            resolution: configuration.exportSettings.resolution
        )
        let canvasWidth = max(2, Int(outputSize.width.rounded()) & ~1)
        let canvasHeight = max(2, Int(outputSize.height.rounded()) & ~1)
        let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

        // Readers
        let screenReader = try AVAssetReader(asset: screenAsset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        screenReader.add(videoOutput)
        screenReader.timeRange = exportTimeRange

        // An imported soundtrack replaces the recorded one wholesale, and it
        // needs its own reader: it is a different file, already carrying the
        // finished cut's timing, so it plays straight through from zero
        // while the screen reader stays on the composed video.
        var audioOutput: AVAssetReaderAudioMixOutput?
        var replacementReader: AVAssetReader?
        if !configuration.exportSettings.removeAudio {
            if let replacementURL = configuration.audioReplacementURL {
                let replacementAsset = AVURLAsset(url: replacementURL)
                let replacementTracks = try await replacementAsset.loadTracks(withMediaType: .audio)
                if !replacementTracks.isEmpty {
                    let reader = try AVAssetReader(asset: replacementAsset)
                    // Clamps a soundtrack that overruns the cut; a shorter
                    // one simply leaves the tail silent.
                    reader.timeRange = exportTimeRange
                    let output = AVAssetReaderAudioMixOutput(
                        audioTracks: replacementTracks,
                        audioSettings: nil
                    )
                    output.audioMix = RecordingAudioGain.makeMix(tracks: replacementTracks, volume: configuration.audioVolume)
                    output.alwaysCopiesSampleData = false
                    reader.add(output)
                    replacementReader = reader
                    audioOutput = output
                }
            } else if !audioTracks.isEmpty {
                let output = AVAssetReaderAudioMixOutput(
                    audioTracks: audioTracks,
                    audioSettings: nil
                )
                output.audioMix = RecordingAudioGain.makeMix(tracks: audioTracks, volume: configuration.audioVolume)
                output.alwaysCopiesSampleData = false
                screenReader.add(output)
                audioOutput = output
            }
        }

        let cameraFeed = try await CameraFrameFeed(
            url: configuration.cameraURL,
            offset: configuration.cameraOffset
        )

        // Writer
        let container = configuration.exportSettings.effectiveContainer
        let outputURL = Self.temporaryOutputURL(container: container)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: container.fileType)
        // Faststart puts the index ahead of the media so a shared link plays
        // before it finishes downloading. The writer pays for that with an
        // extra pass at the end, so only MP4 - the container people actually
        // stream - opts in.
        writer.shouldOptimizeForNetworkUse = container.supportsFastStart

        let codec: AVVideoCodecType = configuration.exportSettings.codec == .hevc ? .hevc : .h264
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Self.averageBitRate(
                width: canvasWidth,
                height: canvasHeight,
                quality: configuration.exportSettings.quality
            ),
            AVVideoExpectedSourceFrameRateKey: timing.framesPerSecond
        ]
        if codec == .hevc {
            // The hardware HEVC encoder is the export's ceiling at Retina
            // sizes; its speed mode runs ~1.75x faster (52 -> 91 fps at
            // 3760x2538 on M4 Pro) for ~1.5 dB PSNR, still above 40 dB.
            // H.264's encoder ignores this flag.
            compressionProperties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: canvasWidth,
            AVVideoHeightKey: canvasHeight,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: canvasWidth,
                kCVPixelBufferHeightKey as String: canvasHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard screenReader.startReading() else {
            throw screenReader.error ?? ExportError.writerFailed(nil)
        }
        if let replacementReader, !replacementReader.startReading() {
            screenReader.cancelReading()
            throw replacementReader.error ?? ExportError.writerFailed(nil)
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: exportStartTime)

        let compositor = StudioFrameCompositor(
            canvasSize: canvasSize,
            videoCropRect: configuration.videoCropRect,
            style: configuration.style,
            viewportTimeline: configuration.viewportTimeline,
            pointerTimeline: configuration.pointerTimeline,
            showsPressEffects: configuration.showsPressEffects,
            keystrokeTimeline: configuration.keystrokeTimeline,
            keystrokePlacement: configuration.keystrokePlacement,
            subtitleTimeline: configuration.subtitleTimeline,
            subtitleStyle: configuration.subtitleStyle,
            karaokeTimeline: configuration.karaokeTimeline,
            includeBubble: cameraFeed != nil,
            timing: timing,
            reframe: configuration.reframe,
            fitContentAspect: configuration.fitContentAspect,
            usesUniformPadding: configuration.usesUniformPadding,
            motionTimeline: configuration.motionTimeline
        )

        let screenAudioOutput = audioOutput
        let writerAudioInput = audioInput

        do {
            async let videoDone: Void = pumpVideo(
                output: videoOutput,
                input: videoInput,
                adaptor: adaptor,
                compositor: compositor,
                cameraFeed: cameraFeed,
                clipTimeline: clipTimeline,
                timing: timing,
                cancelFlag: cancelFlag,
                progress: progress
            )
            async let audioDone: Void = pumpAudio(
                output: screenAudioOutput,
                input: writerAudioInput,
                cancelFlag: cancelFlag
            )
            _ = try await (videoDone, audioDone)
        } catch {
            screenReader.cancelReading()
            replacementReader?.cancelReading()
            cameraFeed?.cancel()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        cameraFeed?.cancel()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.writerFailed(writer.error)
        }
        progress(1)
        return outputURL
    }

    private func pumpVideo(
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        compositor: StudioFrameCompositor,
        cameraFeed: CameraFrameFeed?,
        clipTimeline: RecordingClipTimeline,
        timing: RecordingExportTiming,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Render on a fixed output clock, not per source frame. Screen
        // captures only contain frames where pixels changed, so a static
        // screen has second-long gaps - but the virtual camera animates
        // through them (most zoom-outs happen exactly there, seconds after
        // the last click). Each tick re-renders the newest source frame at
        // or before it; only writing on source arrivals would hold the last
        // zoomed frame through the move and then visibly jump.
        let duration = clipTimeline.duration
        let frameCount = timing.frameCount(for: duration)

        var decodeSeconds = 0.0
        func nextSourceFrame() -> (buffer: CVPixelBuffer, time: TimeInterval)? {
            let decodeStart = CFAbsoluteTimeGetCurrent()
            defer { decodeSeconds += CFAbsoluteTimeGetCurrent() - decodeStart }
            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                return (buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            }
            return nil
        }

        var currentBuffer: CVPixelBuffer?
        var pending = nextSourceFrame()
        var previousClipID: UUID?
        var renderSeconds = 0.0
        var writerWaitSeconds = 0.0
        var renderedFrames = 0
        defer {
            Self.logger.info("Export frames=\(renderedFrames) fps=\(timing.framesPerSecond) motionBlur=\(timing.motionBlurEnabled) Metal blur frames=\(compositor.metalFrameCount) reusedScreenFrames=\(compositor.reusedScreenFrameCount) renderSeconds=\(renderSeconds) metalSeconds=\(compositor.metalSeconds) decodeSeconds=\(decodeSeconds) writerWaitSeconds=\(writerWaitSeconds)")
        }

        var inFlight: (frame: StudioFrameCompositor.PendingFrame, index: Int)?
        func finishAndAppend(_ begun: StudioFrameCompositor.PendingFrame, at index: Int) async throws {
            let renderStart = CFAbsoluteTimeGetCurrent()
            try autoreleasepool {
                try compositor.finish(begun)
            }
            renderSeconds += CFAbsoluteTimeGetCurrent() - renderStart
            renderedFrames += 1

            let waitStart = CFAbsoluteTimeGetCurrent()
            while !input.isReadyForMoreMediaData {
                if cancelFlag.isCancelled { throw ExportError.cancelled }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            writerWaitSeconds += CFAbsoluteTimeGetCurrent() - waitStart

            if !adaptor.append(begun.destination, withPresentationTime: timing.presentationTime(forFrame: index)) {
                throw ExportError.writerFailed(nil)
            }
            if index % 10 == 0 {
                progress(min(0.98, Double(index) / Double(frameCount)))
            }
        }

        for frame in 0..<frameCount {
            if cancelFlag.isCancelled { throw ExportError.cancelled }
            let editorTime = timing.time(forFrame: frame)
            guard let location = clipTimeline.location(at: editorTime) else { break }
            let sourceTime = location.sourceTime

            if previousClipID != location.segmentID {
                // Never carry a sparse screen-capture frame across a hard
                // edit boundary - the reader may not have caught up yet to
                // the new clip's starting source position.
                if previousClipID != nil {
                    currentBuffer = nil
                }
                previousClipID = location.segmentID
            }

            while let sample = pending, sample.time <= editorTime {
                currentBuffer = sample.buffer
                pending = nextSourceFrame()
            }
            // Ticks before the first source frame show it early rather than
            // emitting black; a capture with no frames at all has nothing to
            // render.
            guard let sourceBuffer = currentBuffer ?? pending?.buffer else { break }

            guard let pool = adaptor.pixelBufferPool else {
                throw ExportError.writerFailed(nil)
            }
            var destinationBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationBuffer)
            guard let destinationBuffer else {
                throw ExportError.writerFailed(nil)
            }

            let cameraBuffer = cameraFeed?.latestFrame(at: sourceTime)
            let nextTime = timing.time(forFrame: frame + 1)
            let sourceRepeats = (pending == nil || pending!.time > nextTime)
                && clipTimeline.location(at: nextTime)?.segmentID == location.segmentID
            let renderStart = CFAbsoluteTimeGetCurrent()
            let begun = compositor.begin(
                screenFrame: sourceBuffer,
                cameraFrame: cameraBuffer,
                editorTime: editorTime,
                sourceTime: sourceTime,
                sourceRepeatsOnNextFrame: sourceRepeats,
                into: destinationBuffer
            )
            renderSeconds += CFAbsoluteTimeGetCurrent() - renderStart

            // The GPU renders this frame while the previous one gets its
            // overlays and goes to the encoder.
            if let previous = inFlight {
                try await finishAndAppend(previous.frame, at: previous.index)
            }
            inFlight = (begun, frame)
        }
        if let previous = inFlight {
            try await finishAndAppend(previous.frame, at: previous.index)
        }
        input.markAsFinished()
    }

    private func pumpAudio(
        output: AVAssetReaderAudioMixOutput?,
        input: AVAssetWriterInput?,
        cancelFlag: CancelFlag
    ) async throws {
        guard let output, let input else { return }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if cancelFlag.isCancelled { throw ExportError.cancelled }
            while !input.isReadyForMoreMediaData {
                if cancelFlag.isCancelled { throw ExportError.cancelled }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if !input.append(sampleBuffer) {
                throw ExportError.writerFailed(nil)
            }
        }
        input.markAsFinished()
    }

    private static func temporaryOutputURL(container: VideoExportContainer) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Framecho", isDirectory: true)
            .appendingPathComponent("StudioExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).\(container.fileExtension)")
    }

    private static func outputSize(
        source: CGSize,
        resolution: VideoCompressionResolution
    ) -> CGSize {
        guard source.width > 0, source.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        let requestedHeight: CGFloat?
        switch resolution {
        case .original: requestedHeight = nil
        case .p1080: requestedHeight = 1080
        case .p720: requestedHeight = 720
        case .p480: requestedHeight = 480
        }
        guard let requestedHeight, source.height > requestedHeight else { return source }
        return CGSize(
            width: source.width * requestedHeight / source.height,
            height: requestedHeight
        )
    }

    private static func averageBitRate(
        width: Int,
        height: Int,
        quality: VideoCompressionQuality
    ) -> Int {
        let factor: Double
        switch quality {
        case .high: factor = 3.2
        case .medium: factor = 2.1
        case .low: factor = 1.25
        }
        return max(2_500_000, Int(Double(width * height) * factor))
    }
}

// MARK: - Camera frame feed

/// Sequential decoder for the camera movie that answers "latest camera frame
/// at screen-time t". Screen frames arrive in order, so a one-frame
/// look-ahead over the camera reader is all that's needed.
nonisolated private final class CameraFrameFeed: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let offset: TimeInterval
    private var currentFrame: CVPixelBuffer?
    private var pendingFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var isFinished = false

    init?(url: URL?, offset: TimeInterval) async throws {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                // IOSurface-backed so the bubble scaler can read it on the GPU.
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecordingStudioExporter.ExportError.noVideoTrack
        }

        self.reader = reader
        self.output = output
        self.offset = offset
    }

    func latestFrame(at screenTime: TimeInterval) -> CVPixelBuffer? {
        while !isFinished {
            if let pending = pendingFrame {
                // Promote the very first frame unconditionally: the camera
                // starts a beat after the screen (capture warmup), and holding
                // its first frame from t=0 beats the bubble popping in late.
                guard pending.time <= screenTime || currentFrame == nil else { break }
                currentFrame = pending.buffer
                pendingFrame = nil
            }
            guard let sample = output.copyNextSampleBuffer() else {
                isFinished = true
                break
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds + offset
            pendingFrame = (buffer: buffer, time: time)
        }
        return currentFrame
    }

    func cancel() {
        reader.cancelReading()
    }
}

// MARK: - Frame compositor

/// Draws one output frame: cached backdrop, then the zoom-transformed screen
/// frame clipped to the rounded card, then the camera bubble.
nonisolated private final class StudioFrameCompositor: @unchecked Sendable {
    private let canvasSize: CGSize
    private let videoCropRect: CGRect
    private let layout: RecordingStudioLayout
    private let viewportTimeline: ViewportTimeline
    private let pointerTimeline: PointerTimeline?
    private let showsPressEffects: Bool
    private let keystrokeTimeline: KeystrokeCaptionTimeline?
    private let keystrokePlacement: RecordingKeystrokePlacement
    private let subtitleTimeline: SubtitleTimeline?
    private let subtitleStyle: SubtitleBarStyle
    private let karaokeTimeline: KaraokeTimeline?
    private let reframe: ReframeTrack?
    private let motionTimeline: RecordingMotionTimeline
    /// True when any frame tilts or moves the card. Such exports draw the
    /// card into its own layer and project it; flat ones keep the 2D path.
    private let projectsCard: Bool
    private let cardShadowStrength: CGFloat
    private var artworkImageCache: [String: CGImage] = [:]
    private let pointerScale: CGFloat
    private let colorSpace: CGColorSpace
    private let backdrop: CGImage?
    private let timing: RecordingExportTiming
    private var metalRenderer: StudioMetalScreenRenderer?
    private var metalFailed = false
    /// The projected card's screen layer, over a transparent backdrop.
    private var projectedScreenRenderer: StudioMetalScreenRenderer?
    private(set) var metalFrameCount = 0
    /// Wall time submitting and waiting on Metal passes. With a frame in
    /// flight this is only the GPU time the CPU could not overlap.
    private(set) var metalSeconds = 0.0
    private let screenLayerCache = StudioScreenLayerCache()
    /// The layer the cache will hold once every begun frame finishes.
    private var plannedCacheKey: (source: CVPixelBuffer, rect: CGRect)?
    /// Retained so pixel-buffer pool reuse can't produce a false cache hit.
    private var bubbleContentSource: CVPixelBuffer?
    private var bubbleContentImage: CGImage?
    private(set) var reusedScreenFrameCount = 0
    private let bypassScreenCache = ProcessInfo.processInfo.environment["FRAMECHO_EXPORT_BYPASS_SCREEN_CACHE"] == "1"
    // Developer comparison switch; export settings and saved projects do not change.
    private let forceCoreGraphics = ProcessInfo.processInfo.environment["FRAMECHO_EXPORT_RENDERER"] == "cpu"

    init(
        canvasSize: CGSize,
        videoCropRect: CGRect,
        style: RecordingStudioStyle,
        viewportTimeline: ViewportTimeline,
        pointerTimeline: PointerTimeline?,
        showsPressEffects: Bool,
        keystrokeTimeline: KeystrokeCaptionTimeline?,
        keystrokePlacement: RecordingKeystrokePlacement,
        subtitleTimeline: SubtitleTimeline?,
        subtitleStyle: SubtitleBarStyle = SubtitleBarStyle(),
        karaokeTimeline: KaraokeTimeline? = nil,
        includeBubble: Bool,
        timing: RecordingExportTiming,
        reframe: ReframeTrack? = nil,
        fitContentAspect: CGFloat? = nil,
        usesUniformPadding: Bool = false,
        motionTimeline: RecordingMotionTimeline = .disabled
    ) {
        self.canvasSize = canvasSize
        self.videoCropRect = RecordingVideoCropGeometry.normalized(videoCropRect)
        self.layout = RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: style,
            includeBubble: includeBubble,
            usesUniformPadding: usesUniformPadding,
            contentAspect: reframe?.sourceAspect ?? fitContentAspect,
            contentMode: fitContentAspect != nil && reframe == nil ? .fit : .fill,
            contentCropRect: videoCropRect
        )
        self.viewportTimeline = viewportTimeline
        self.pointerTimeline = style.hidesCursor ? nil : pointerTimeline
        self.showsPressEffects = showsPressEffects
        self.keystrokeTimeline = keystrokeTimeline
        self.keystrokePlacement = keystrokePlacement
        self.subtitleTimeline = subtitleTimeline
        self.subtitleStyle = subtitleStyle
        self.karaokeTimeline = karaokeTimeline
        self.reframe = reframe
        self.motionTimeline = motionTimeline
        let projectsCard = !motionTimeline.isIdentity
        self.projectsCard = projectsCard
        self.cardShadowStrength = style.shadow > 0.01 && style.background != .none ? style.shadow : 0
        self.timing = timing
        self.pointerScale = style.cursorScale
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.backdrop = Self.renderBackdrop(
            canvasSize: canvasSize,
            layout: layout,
            style: style,
            colorSpace: colorSpace,
            includesCardShadow: !projectsCard
        )
    }

    /// The virtual camera for a frame: the reframe crop-and-follow track
    /// when exporting into a different aspect, the zoom viewport otherwise.
    private func viewportFrame(at editorTime: TimeInterval) -> ViewportFrame {
        let base = reframe?.frame(at: editorTime) ?? viewportTimeline.frame(at: editorTime)
        return RecordingVideoCropGeometry.viewport(base, crop: videoCropRect)
    }

    /// A frame whose screen layer may still be rendering on the GPU.
    struct PendingFrame {
        fileprivate let screenFrame: CVPixelBuffer
        fileprivate let cameraFrame: CVPixelBuffer?
        fileprivate let editorTime: TimeInterval
        fileprivate let sourceTime: TimeInterval
        fileprivate let sampleRects: [CGRect]
        fileprivate let shouldCacheScreen: Bool
        /// Set when the previous frame leaves this exact screen layer in the
        /// cache; the restore itself waits for finish, which runs in order.
        fileprivate let plansRestore: Bool
        fileprivate let submission: StudioMetalScreenRenderer.Submission?
        /// The projected card's flat layer this frame draws into.
        fileprivate var foreground: CVPixelBuffer?
        let destination: CVPixelBuffer
    }

    /// Starts a frame: resolves its shutter and submits the GPU screen pass
    /// without waiting, so the caller can finish the previous frame while
    /// this one renders. Frames must be finished in the order they began.
    func begin(
        screenFrame: CVPixelBuffer,
        cameraFrame: CVPixelBuffer?,
        editorTime: TimeInterval,
        sourceTime: TimeInterval,
        sourceRepeatsOnNextFrame: Bool,
        into destination: CVPixelBuffer
    ) -> PendingFrame {
        let sampleRects = timing.screenSampleRects(at: editorTime) { time in
            layout.frameRect(for: viewportFrame(at: time))
        }
        if projectsCard {
            // The projected path draws the flat card layer, then projects it
            // with Core Image; the flat screen cache doesn't apply. Its
            // screen pass starts now, so the GPU renders this frame while
            // the previous one is finished.
            plannedCacheKey = nil
            let foreground = nextCardForeground()
            return PendingFrame(
                screenFrame: screenFrame,
                cameraFrame: cameraFrame,
                editorTime: editorTime,
                sourceTime: sourceTime,
                sampleRects: sampleRects,
                shouldCacheScreen: false,
                plansRestore: false,
                submission: foreground.flatMap {
                    submitProjectedScreen(screenFrame: screenFrame, sampleRects: sampleRects, into: $0)
                },
                foreground: foreground,
                destination: destination
            )
        }
        let sampleCount = sampleRects.count
        let plansRestore = !bypassScreenCache && sampleCount == 1
            && plannedCacheKey.map { $0.source === screenFrame && $0.rect == sampleRects[0] } == true
        // Cache only a settled layer that can be reused on the next tick.
        // Moving frames and continuously changing video avoid the extra copy.
        let shouldCacheScreen = !bypassScreenCache && sourceRepeatsOnNextFrame && sampleCount == 1
            && sampleRects[0] == layout.frameRect(for: viewportFrame(at: editorTime + timing.frameInterval))
            && StudioScreenLayerCache.canCapture(width: Int(canvasSize.width), height: Int(canvasSize.height))
        // Mirrors the cache transitions finish(_:) applies in order: a
        // restored layer stays cached, a newly cached one replaces it, and
        // anything else clears it.
        if !shouldCacheScreen {
            plannedCacheKey = nil
        } else if !plansRestore {
            plannedCacheKey = (screenFrame, sampleRects[0])
        }

        let submission = plansRestore ? nil : submitMetal(
            screenFrame: screenFrame, sampleRects: sampleRects, into: destination
        )
        return PendingFrame(
            screenFrame: screenFrame,
            cameraFrame: cameraFrame,
            editorTime: editorTime,
            sourceTime: sourceTime,
            sampleRects: sampleRects,
            shouldCacheScreen: shouldCacheScreen,
            plansRestore: plansRestore,
            submission: submission,
            destination: destination
        )
    }

    /// Completes a frame begun earlier: waits for its screen pass, then draws
    /// the CPU overlays into its destination.
    func finish(_ frame: PendingFrame) throws {
        if projectsCard {
            try finishProjected(frame)
            return
        }
        let destination = frame.destination
        let screenFrame = frame.screenFrame
        let sampleRects = frame.sampleRects
        let reusedScreen = frame.plansRestore && screenLayerCache.restore(
            source: screenFrame, rect: sampleRects[0], into: destination
        )
        if reusedScreen { reusedScreenFrameCount += 1 }
        else { screenLayerCache.invalidate() }

        // Metal completes before the CPU locks this IOSurface for overlays.
        // A planned restore that failed renders its layer now instead.
        var renderedWithMetal = false
        if !reusedScreen,
           let submission = frame.submission ?? submitMetal(
               screenFrame: screenFrame, sampleRects: sampleRects, into: destination
           ) {
            let waitStart = CFAbsoluteTimeGetCurrent()
            renderedWithMetal = metalRenderer?.wait(for: submission) == true
            metalSeconds += CFAbsoluteTimeGetCurrent() - waitStart
            if renderedWithMetal { metalFrameCount += 1 }
            else { metalFailed = true }
        }
        let shouldCacheScreen = frame.shouldCacheScreen
        let editorTime = frame.editorTime
        let sourceTime = frame.sourceTime
        let cameraFrame = frame.cameraFrame
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard let base = CVPixelBufferGetBaseAddress(destination),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(destination),
                height: CVPixelBufferGetHeight(destination),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw RecordingStudioExporter.ExportError.writerFailed(nil)
        }
        context.interpolationQuality = .high

        if !reusedScreen, !renderedWithMetal, let backdrop {
            context.draw(backdrop, in: CGRect(origin: .zero, size: canvasSize))
        } else if !reusedScreen, !renderedWithMetal {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvasSize))
        }

        var renderedScreen = reusedScreen || renderedWithMetal
        if !reusedScreen, !renderedWithMetal, let screenImage = Self.makeImage(from: screenFrame, colorSpace: colorSpace) {
            drawScreenSamples(screenImage, sampleRects: sampleRects, in: context)
            renderedScreen = true
        }

        if shouldCacheScreen, !reusedScreen, renderedScreen {
            context.flush()
            screenLayerCache.capture(source: screenFrame, rect: sampleRects[0], fromLocked: destination)
        }
        if !shouldCacheScreen { screenLayerCache.invalidate() }

        // Pointer motion is resolved independently from viewport shutter
        // blur. Its interaction magnification and tilt stay anchored at the
        // recorded artwork anchor point, while the final point still passes
        // through the same viewport transform and rounded-card clip as the
        // source pixels.
        drawPointer(editorTime: editorTime, in: context)

        // The keystroke caption stays in card space - pinned to its edge and
        // unaffected by the zoom transform, like a broadcast lower third.
        drawKeystrokeCaption(at: sourceTime, in: context)

        if let cameraFrame, layout.bubbleRect.width > 0 {
            drawCameraBubble(cameraFrame, in: context)
        }

        // The subtitle bar lives in canvas space - over the background too,
        // not just the card - and above everything else, camera included.
        drawSubtitleBar(at: sourceTime, in: context)
    }

    /// Motion blur by temporal supersampling: while the virtual camera is
    /// moving, average several sub-frame camera states across the frame's
    /// shutter interval. Pans smear linearly, zooms radially, and settled
    /// frames pay for a single draw. The viewport timeline runs on the
    /// gapless output clock, so the shutter is always exactly one output
    /// frame - no per-call time tracking needed.
    private func drawScreenSamples(_ screenImage: CGImage, sampleRects: [CGRect], in context: CGContext) {
        context.saveGState()
        context.addPath(roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius))
        context.clip()
        for (sample, drawRect) in sampleRects.enumerated() {
            // Drawing sample i at alpha 1/(i+1) keeps the buffer equal to
            // the running average of all samples so far.
            context.setAlpha(1 / CGFloat(sample + 1))
            context.draw(screenImage, in: flipped(drawRect))
        }
        context.restoreGState()
    }

    // MARK: Projected card

    /// The card plane drawn and projected each frame: the card plus room for
    /// a keystroke caption wider than the card.
    private lazy var cardPlaneRect: CGRect = layout.cardRect
        .insetBy(dx: -layout.cardRect.width * 0.25, dy: -layout.cardRect.height * 0.25)
        .intersection(CGRect(origin: .zero, size: canvasSize))
        .integral

    /// Flat card content - video, pointer, keystroke caption - in canvas
    /// space before projection. Two alternate, so the GPU can draw one
    /// frame's layer while the previous frame's is still being projected;
    /// with one frame in flight, a buffer is free again when it comes round.
    private lazy var cardForegrounds: [CVPixelBuffer] = (0..<2).compactMap { _ in
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(canvasSize.width),
            Int(canvasSize.height),
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &buffer
        )
        return buffer
    }
    private var cardForegroundIndex = 0

    private func nextCardForeground() -> CVPixelBuffer? {
        guard !cardForegrounds.isEmpty else { return nil }
        defer { cardForegroundIndex = (cardForegroundIndex + 1) % cardForegrounds.count }
        return cardForegrounds[cardForegroundIndex]
    }

    /// No color management: values pass through exactly as Core Graphics
    /// drew them, so the projected card matches the flat path's colors.
    private lazy var ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false
    ])

    /// The card's shadow for one pose, as a layer covering only its reach.
    /// Static poses render it once; moving ones every frame.
    private var shadowLayerCache: (pose: RecordingCardPose, image: CGImage, rect: CGRect)?

    private func projection(at editorTime: TimeInterval) -> RecordingCardProjection {
        projection(for: motionTimeline.pose(at: editorTime))
    }

    /// Card poses across the frame's shutter. The subframe count follows
    /// how far the projected corners travel, so a settled card pays for
    /// one projection and a fast turn gets a smooth smear.
    private func shutterProjections(at editorTime: TimeInterval) -> [RecordingCardProjection] {
        guard timing.motionBlurEnabled, !motionTimeline.isStatic else {
            return [projection(at: editorTime)]
        }
        let shutter = timing.frameInterval
        let opening = projection(at: editorTime - shutter / 2).quad(for: layout.cardRect)
        let closing = projection(at: editorTime + shutter / 2).quad(for: layout.cardRect)
        let displacement = zip(opening, closing).reduce(CGFloat(0)) { travel, corners in
            max(travel, abs(corners.0.x - corners.1.x), abs(corners.0.y - corners.1.y))
        }
        return timing.subframeTimes(at: editorTime, displacement: displacement).map(projection(at:))
    }

    private func finishProjected(_ frame: PendingFrame) throws {
        let projection = projection(at: frame.editorTime)
        let shutterProjections = shutterProjections(at: frame.editorTime)
        guard let foreground = frame.foreground else {
            throw RecordingStudioExporter.ExportError.writerFailed(nil)
        }

        // The card content is drawn once; every shutter pose projects the
        // same video frame, so only the card's own motion smears. The screen
        // and its zoom blur take the same Metal pass as flat frames, over a
        // transparent backdrop; the pass writes every pixel of the layer.
        let screenOnGPU = finishProjectedScreen(frame)
        try withBitmapContext(foreground) { context in
            if !screenOnGPU {
                context.clear(CGRect(origin: .zero, size: canvasSize))
                if let screenImage = Self.makeImage(from: frame.screenFrame, colorSpace: colorSpace) {
                    drawScreenSamples(screenImage, sampleRects: frame.sampleRects, in: context)
                }
            }
            drawPointer(editorTime: frame.editorTime, in: context)
            drawKeystrokeCaption(at: frame.sourceTime, in: context)
        }

        try withBitmapContext(frame.destination) { context in
            drawProjectedBackdrop(for: projection.pose, into: context)
        }

        try renderProjectedCard(foreground, projections: shutterProjections, into: frame.destination)

        try withBitmapContext(frame.destination) { context in
            if let cameraFrame = frame.cameraFrame, layout.bubbleRect.width > 0 {
                drawCameraBubble(cameraFrame, in: context)
            }
            drawSubtitleBar(at: frame.sourceTime, in: context)
        }
    }

    /// A canvas-sized pixel copy, in the output buffers' format.
    private struct CanvasPixels {
        var bytes: [UInt8]
        let bytesPerRow: Int
    }

    /// Backdrop plus card shadow for the last settled pose. Both are drawn
    /// across the whole canvas - the shadow scaled up from a reduced layer -
    /// which costs more on the CPU than the rest of a frame, yet repeat
    /// exactly while the card holds still. A pose seen on two consecutive
    /// frames is kept; each later frame with that pose copies it back.
    private var settledBackdrop: (pose: RecordingCardPose, pixels: CanvasPixels)?
    private var previousBackdropPose: RecordingCardPose?

    private func drawProjectedBackdrop(for pose: RecordingCardPose, into context: CGContext) {
        defer { previousBackdropPose = pose }
        if let settledBackdrop, settledBackdrop.pose == pose,
           copy(settledBackdrop.pixels, into: context) {
            return
        }
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        if let backdrop {
            context.draw(backdrop, in: canvasRect)
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(canvasRect)
        }
        if let shadow = projectedShadow(for: projection(for: pose)) {
            context.draw(shadow.image, in: shadow.rect)
        }
        if pose == previousBackdropPose {
            context.flush()
            settledBackdrop = capture(context).map { (pose, $0) }
        }
    }

    private func projection(for pose: RecordingCardPose) -> RecordingCardProjection {
        RecordingCardProjection(
            cardRect: layout.cardRect,
            canvasSize: canvasSize,
            pose: pose,
            projectionVersion: motionTimeline.projectionVersion
        )
    }

    private func capture(_ context: CGContext) -> CanvasPixels? {
        guard let data = context.data, context.width == Int(canvasSize.width),
              context.height == Int(canvasSize.height) else { return nil }
        let count = context.bytesPerRow * context.height
        // Take the old copy's storage so it is overwritten, not duplicated.
        var bytes = settledBackdrop.take()?.pixels.bytes ?? []
        if bytes.count != count {
            bytes = [UInt8](repeating: 0, count: count)
        }
        bytes.withUnsafeMutableBytes { raw in
            raw.baseAddress?.copyMemory(from: data, byteCount: count)
        }
        return CanvasPixels(bytes: bytes, bytesPerRow: context.bytesPerRow)
    }

    /// False when the context doesn't match the copy's layout.
    private func copy(_ pixels: CanvasPixels, into context: CGContext) -> Bool {
        guard let destination = context.data,
              context.width == Int(canvasSize.width),
              context.height == Int(canvasSize.height) else { return false }
        let rowLength = context.width * 4
        guard pixels.bytesPerRow >= rowLength, context.bytesPerRow >= rowLength else { return false }
        pixels.bytes.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            if context.bytesPerRow == pixels.bytesPerRow {
                destination.copyMemory(from: sourceBase, byteCount: min(pixels.bytes.count, context.bytesPerRow * context.height))
            } else {
                for row in 0..<context.height {
                    (destination + row * context.bytesPerRow)
                        .copyMemory(from: sourceBase + row * pixels.bytesPerRow, byteCount: rowLength)
                }
            }
        }
        return true
    }

    /// Starts the Metal pass for the projected card's flat screen layer.
    /// Nil means Core Graphics draws it - for this frame, or for the rest of
    /// the export after a GPU failure, as on the flat path.
    private func submitProjectedScreen(
        screenFrame: CVPixelBuffer,
        sampleRects: [CGRect],
        into foreground: CVPixelBuffer
    ) -> StudioMetalScreenRenderer.Submission? {
        guard !forceCoreGraphics, !metalFailed,
              StudioMetalScreenRenderer.shouldAccelerate(screenFrame: screenFrame, sampleRects: sampleRects)
        else { return nil }
        if projectedScreenRenderer == nil {
            projectedScreenRenderer = StudioMetalScreenRenderer(
                canvasSize: canvasSize, backdrop: nil, clearsBackdrop: true,
                cardPath: roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius),
                colorSpace: colorSpace
            )
        }
        let start = CFAbsoluteTimeGetCurrent()
        defer { metalSeconds += CFAbsoluteTimeGetCurrent() - start }
        guard let submission = projectedScreenRenderer?.submit(
            screenFrame: screenFrame, sampleRects: sampleRects, into: foreground
        ) else {
            metalFailed = true
            return nil
        }
        return submission
    }

    /// Waits for a frame's screen pass; true when its layer is ready.
    private func finishProjectedScreen(_ frame: PendingFrame) -> Bool {
        guard let submission = frame.submission, let renderer = projectedScreenRenderer else {
            return false
        }
        let start = CFAbsoluteTimeGetCurrent()
        defer { metalSeconds += CFAbsoluteTimeGetCurrent() - start }
        guard renderer.wait(for: submission) else {
            metalFailed = true
            return false
        }
        metalFrameCount += 1
        return true
    }

    private func withBitmapContext(_ buffer: CVPixelBuffer, _ draw: (CGContext) -> Void) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw RecordingStudioExporter.ExportError.writerFailed(nil)
        }
        context.interpolationQuality = .high
        draw(context)
        context.flush()
    }

    /// Same shadow as the flat backdrop, cast by the projected card outline.
    /// A soft shadow carries no fine detail, so a wide blur renders at a
    /// fraction of the resolution and is scaled up when drawn; the layer
    /// covers only the shadow's reach rather than the whole canvas.
    private func projectedShadow(
        for projection: RecordingCardProjection
    ) -> (image: CGImage, rect: CGRect)? {
        guard cardShadowStrength > 0 else { return nil }
        if let cached = shadowLayerCache, cached.pose == projection.pose {
            return (cached.image, cached.rect)
        }
        let minDimension = min(canvasSize.width, canvasSize.height)
        let blur = minDimension * 0.045 * cardShadowStrength
        let offsetY = blur * 0.35
        let cardBounds = flipped(projection.bounds(of: layout.cardRect))
        let rect = cardBounds
            .insetBy(dx: -(blur * 2), dy: -(blur * 2 + offsetY))
            .intersection(CGRect(origin: .zero, size: canvasSize))
            .integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let scale: CGFloat = blur >= 24 ? 0.25 : (blur >= 10 ? 0.5 : 1)
        let width = max(1, Int((rect.width * scale).rounded(.up)))
        let height = max(1, Int((rect.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // The outline is drawn off-layer and only its shadow is offset back
        // in, so nothing paints under the card's antialiased edge. Shadow
        // offset and blur are in device space, hence the explicit scale.
        let away = rect.width * 2 + blur * 4
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX + away, y: -rect.minY)
        context.setShadow(
            offset: CGSize(width: -away * scale, height: -offsetY * scale),
            blur: blur * scale,
            color: CGColor(gray: 0, alpha: 0.55 * cardShadowStrength)
        )
        context.addPath(projectedCardPath(projection))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        shadowLayerCache = (projection.pose, image, rect)
        return (image, rect)
    }

    /// The rounded card outline through the projection, bottom-up.
    private func projectedCardPath(_ projection: RecordingCardProjection) -> CGPath {
        let rect = layout.cardRect
        let radius = min(layout.cardCornerRadius, min(rect.width, rect.height) / 2)
        var outline: [CGPoint] = []
        if radius > 0.5 {
            let steps = 8
            let corners: [(center: CGPoint, startAngle: CGFloat)] = [
                (CGPoint(x: rect.maxX - radius, y: rect.minY + radius), -.pi / 2),
                (CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), 0),
                (CGPoint(x: rect.minX + radius, y: rect.maxY - radius), .pi / 2),
                (CGPoint(x: rect.minX + radius, y: rect.minY + radius), .pi)
            ]
            for corner in corners {
                for step in 0...steps {
                    let angle = corner.startAngle + CGFloat(step) / CGFloat(steps) * .pi / 2
                    outline.append(CGPoint(
                        x: corner.center.x + cos(angle) * radius,
                        y: corner.center.y + sin(angle) * radius
                    ))
                }
            }
        } else {
            outline = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)
            ]
        }
        let path = CGMutablePath()
        path.addLines(between: outline.map { point in
            let projected = projection.project(point)
            return CGPoint(x: projected.x, y: canvasSize.height - projected.y)
        })
        path.closeSubpath()
        return path
    }

    private func renderProjectedCard(
        _ foreground: CVPixelBuffer,
        projections: [RecordingCardProjection],
        into destination: CVPixelBuffer
    ) throws {
        let plane = cardPlaneRect
        guard plane.width >= 1, plane.height >= 1, !projections.isEmpty else { return }
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        // Core Image is bottom-up: the crop is the flipped plane, and its
        // top-left corner is the plane's canvas top-left.
        let flat = CIImage(cvPixelBuffer: foreground).cropped(to: flipped(plane))
        func projected(_ projection: RecordingCardProjection) -> CIImage? {
            let corners = projection.quad(for: plane).map {
                CGPoint(x: $0.x, y: canvasSize.height - $0.y)
            }
            let filter = CIFilter.perspectiveTransform()
            filter.inputImage = flat
            filter.topLeft = corners[0]
            filter.topRight = corners[1]
            filter.bottomRight = corners[2]
            filter.bottomLeft = corners[3]
            return filter.outputImage?.cropped(to: canvasRect)
        }

        let image: CIImage?
        if projections.count == 1 {
            image = projected(projections[0])
        } else {
            // Average the shutter poses in premultiplied color so translucent
            // edges do not darken. CIColorMatrix works on unpremultiplied
            // color, so weighting alpha alone weights the premultiplied
            // pixel. Core Image accumulates in half float, so the sum does
            // not band.
            let weight = CGFloat(1) / CGFloat(projections.count)
            image = projections.reduce(nil as CIImage?) { sum, projection in
                guard let sample = projected(projection) else { return sum }
                let weighted = sample.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)
                ])
                guard let sum else { return weighted }
                return weighted.applyingFilter("CIAdditionCompositing", parameters: [
                    kCIInputBackgroundImageKey: sum
                ])
            }?.cropped(to: canvasRect)
        }
        guard let image else { return }

        let target = CIRenderDestination(pixelBuffer: destination)
        target.colorSpace = nil
        target.blendKernel = .sourceOver
        do {
            try ciContext.startTask(toRender: image, to: target).waitUntilCompleted()
        } catch {
            throw RecordingStudioExporter.ExportError.writerFailed(error)
        }
    }

    private func submitMetal(
        screenFrame: CVPixelBuffer,
        sampleRects: [CGRect],
        into destination: CVPixelBuffer
    ) -> StudioMetalScreenRenderer.Submission? {
        guard !forceCoreGraphics, !metalFailed,
              StudioMetalScreenRenderer.shouldAccelerate(screenFrame: screenFrame, sampleRects: sampleRects)
        else { return nil }
        if metalRenderer == nil {
            metalRenderer = StudioMetalScreenRenderer(
                canvasSize: canvasSize, backdrop: backdrop,
                cardPath: roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius), colorSpace: colorSpace
            )
        }
        let submitStart = CFAbsoluteTimeGetCurrent()
        defer { metalSeconds += CFAbsoluteTimeGetCurrent() - submitStart }
        guard let submission = metalRenderer?.submit(
            screenFrame: screenFrame, sampleRects: sampleRects, into: destination
        ) else {
            metalFailed = true
            return nil
        }
        return submission
    }

    /// Shadow + hairline border match the live preview's bubble styling.
    /// The bubble sits over moving video, so it composites every frame -
    /// but its geometry is fixed for the export: the blurred shadow renders
    /// once, the clipped camera layer once per camera frame, and each output
    /// frame only blits them 1:1.
    private func drawCameraBubble(_ cameraFrame: CVPixelBuffer, in context: CGContext) {
        if bubbleContentSource !== cameraFrame {
            bubbleContentImage = renderBubbleContent(cameraFrame)
            bubbleContentSource = bubbleContentImage == nil ? nil : cameraFrame
        }
        guard let content = bubbleContentImage else { return }
        if let shadow = bubbleShadow {
            context.draw(shadow.image, in: shadow.rect)
        }
        context.draw(content, in: bubbleContentRect)
    }

    /// The bubble in bottom-up canvas pixels, grown to whole pixels so its
    /// cached layer blits without resampling.
    private var bubbleContentRect: CGRect { flipped(layout.bubbleRect).integral }

    private lazy var bubbleShadow: (image: CGImage, rect: CGRect)? = {
        let minDimension = min(canvasSize.width, canvasSize.height)
        let blur = minDimension * 0.022
        let offset = minDimension * 0.009
        let rect = bubbleContentRect
            .insetBy(dx: -(blur * 2 + offset), dy: -(blur * 2 + offset))
            .intersection(CGRect(origin: .zero, size: canvasSize))
            .integral
        guard let image = renderLayer(covering: rect, draw: { context in
            context.setShadow(
                offset: CGSize(width: 0, height: -offset),
                blur: blur,
                color: CGColor(gray: 0, alpha: 0.35)
            )
            context.addPath(roundedPath(for: layout.bubbleRect, radius: layout.bubbleCornerRadius))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
        }) else { return nil }
        return (image, rect)
    }()

    private lazy var cameraScaler: StudioCameraBubbleScaler? = forceCoreGraphics
        ? nil
        : StudioCameraBubbleScaler(size: bubbleContentRect.size, colorSpace: colorSpace)

    private func renderBubbleContent(_ cameraFrame: CVPixelBuffer) -> CGImage? {
        let bubble = layout.bubbleRect
        let imageSize = CGSize(width: CVPixelBufferGetWidth(cameraFrame), height: CVPixelBufferGetHeight(cameraFrame))
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = max(bubble.width / imageSize.width, bubble.height / imageSize.height)
        let fillSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let fillRect = CGRect(
            x: bubble.midX - fillSize.width / 2,
            y: bubble.midY - fillSize.height / 2,
            width: fillSize.width,
            height: fillSize.height
        )
        let minDimension = min(canvasSize.width, canvasSize.height)
        let layerRect = bubbleContentRect
        // The GPU scales straight into the layer's pixel box, so the draw
        // below is 1:1; Core Graphics resamples the full frame otherwise.
        let scaledCamera = cameraScaler?.scale(
            cameraFrame,
            fillRect: fillRect.offsetBy(dx: -layerRect.minX, dy: -(canvasSize.height - layerRect.maxY))
        )
        let cameraImage = scaledCamera == nil ? Self.makeImage(from: cameraFrame, colorSpace: colorSpace) : nil
        guard scaledCamera != nil || cameraImage != nil else { return nil }
        return renderLayer(covering: layerRect) { context in
            context.saveGState()
            context.addPath(roundedPath(for: bubble, radius: layout.bubbleCornerRadius))
            context.clip()
            if let scaledCamera {
                context.draw(scaledCamera, in: layerRect)
            } else if let cameraImage {
                context.draw(cameraImage, in: flipped(fillRect))
            }
            context.restoreGState()

            context.addPath(roundedPath(for: bubble.insetBy(dx: 0.5, dy: 0.5), radius: layout.bubbleCornerRadius))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
            context.setLineWidth(max(1, minDimension * 0.0018))
            context.strokePath()
        }
    }

    /// Renders canvas-space (bottom-up) drawing into an image covering only
    /// `rect`, which must be in whole pixels.
    private func renderLayer(covering rect: CGRect, draw: (CGContext) -> Void) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              let context = CGContext(
                data: nil,
                width: Int(rect.width),
                height: Int(rect.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: -rect.minX, y: -rect.minY)
        draw(context)
        return context.makeImage()
    }

    private func drawPointer(editorTime: TimeInterval, in context: CGContext) {
        guard let pointerTimeline,
              let pointer = pointerTimeline.frame(at: editorTime) else {
            return
        }

        let drawRect = layout.frameRect(for: viewportFrame(at: editorTime))
        let tip = CGPoint(
            x: drawRect.minX + pointer.location.x * drawRect.width,
            y: canvasSize.height - (drawRect.minY + pointer.location.y * drawRect.height)
        )

        var pressGeometry: (tip: CGPoint, effect: PointerPressEffectGeometry)?
        if showsPressEffects, let press = pointer.press {
            pressGeometry = (
                CGPoint(
                    x: drawRect.minX + press.location.x * drawRect.width,
                    y: canvasSize.height - (drawRect.minY + press.location.y * drawRect.height)
                ),
                PointerPressEffectStyle.geometry(
                    progress: press.progress,
                    referenceHeight: layout.contentFillSize.height,
                    cursorScale: pointerScale
                )
            )
        }
        var artworkPlacement: (image: CGImage, rect: CGRect, transform: CGAffineTransform)?
        if let resolved = artwork(for: pointer, in: pointerTimeline) {
            let height = layout.contentFillSize.height
                * PointerArtworkMetrics.heightRatio
                * pointerScale
                * resolved.intrinsicScale
            let size = CGSize(width: height * resolved.aspectRatio, height: height)
            let interactionScale = CGFloat(max(pointer.magnification, 0.1))
            let transform = CGAffineTransform(translationX: tip.x, y: tip.y)
                .rotated(by: -CGFloat(pointer.tiltDegrees * .pi / 180))
                .scaledBy(x: interactionScale, y: interactionScale)
            artworkPlacement = (
                resolved.image,
                CGRect(
                    x: -resolved.anchor.x * size.width,
                    y: -(1 - resolved.anchor.y) * size.height,
                    width: size.width,
                    height: size.height
                ),
                transform
            )
        }

        // The pointer is clipped to the rounded card like the screen pixels
        // beneath it, but a full-canvas clip mask costs more than the whole
        // draw. When everything drawn sits inside the card's corner-free
        // interior the clip removes nothing, so skip it.
        var bounds = CGRect.null
        if let pressGeometry {
            let reach = max(pressGeometry.effect.impactRadius, pressGeometry.effect.rippleRadius)
                + pressGeometry.effect.rippleLineWidth
            bounds = bounds.union(CGRect(
                x: pressGeometry.tip.x - reach, y: pressGeometry.tip.y - reach,
                width: reach * 2, height: reach * 2
            ))
        }
        if let artworkPlacement {
            bounds = bounds.union(artworkPlacement.rect.applying(artworkPlacement.transform))
        }
        guard !bounds.isNull else { return }
        let card = flipped(layout.cardRect)
        let radius = min(layout.cardCornerRadius, min(card.width, card.height) / 2)
        let paddedBounds = bounds.insetBy(dx: -2, dy: -2)
        let needsClip = !card.insetBy(dx: radius, dy: 0).contains(paddedBounds)
            && !card.insetBy(dx: 0, dy: radius).contains(paddedBounds)

        context.saveGState()
        if needsClip {
            context.addPath(roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius))
            context.clip()
        }
        if let pressGeometry {
            let (pressTip, effect) = pressGeometry
            let accent = PointerPressEffectStyle.color
            context.saveGState()
            context.setFillColor(CGColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: effect.impactOpacity
            ))
            context.fillEllipse(in: CGRect(
                x: pressTip.x - effect.impactRadius,
                y: pressTip.y - effect.impactRadius,
                width: effect.impactRadius * 2,
                height: effect.impactRadius * 2
            ))
            context.setStrokeColor(CGColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: effect.rippleOpacity
            ))
            context.setLineWidth(effect.rippleLineWidth)
            context.strokeEllipse(in: CGRect(
                x: pressTip.x - effect.rippleRadius,
                y: pressTip.y - effect.rippleRadius,
                width: effect.rippleRadius * 2,
                height: effect.rippleRadius * 2
            ))
            context.restoreGState()
        }

        if let artworkPlacement {
            context.setAlpha(CGFloat(min(max(pointer.opacity, 0), 1)))
            context.concatenate(artworkPlacement.transform)
            context.draw(artworkPlacement.image, in: artworkPlacement.rect)
        }
        context.restoreGState()
    }

    private func drawKeystrokeCaption(at time: TimeInterval, in context: CGContext) {
        guard let keystrokeTimeline,
              let caption = keystrokeTimeline.frame(at: time) else {
            return
        }

        let metrics = KeystrokeCaptionMetrics(cardHeight: layout.cardRect.height)
        let font = Self.captionFont(size: metrics.fontSize)
        let (modifierText, keyText) = KeystrokeCaptionMetrics.text(for: caption)

        let text = NSMutableAttributedString()
        if !modifierText.isEmpty {
            text.append(NSAttributedString(string: modifierText, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 1, alpha: KeystrokeCaptionMetrics.modifierAlpha)
            ]))
        }
        text.append(NSAttributedString(string: keyText, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 1, alpha: 1)
        ]))

        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard textWidth > 0 else { return }

        let pillSize = CGSize(
            width: textWidth + metrics.paddingHorizontal * 2,
            height: ascent + descent + metrics.paddingVertical * 2
        )
        let origin = metrics.pillOrigin(
            pillSize: pillSize,
            cardRect: layout.cardRect,
            placement: keystrokePlacement
        )
        let pillRect = flipped(CGRect(origin: origin, size: pillSize))

        context.saveGState()
        context.setAlpha(CGFloat(caption.opacity))
        context.translateBy(x: pillRect.midX, y: pillRect.midY)
        context.scaleBy(x: CGFloat(caption.scale), y: CGFloat(caption.scale))
        context.translateBy(x: -pillRect.midX, y: -pillRect.midY)

        let radius = min(metrics.cornerRadius, pillRect.height / 2)
        context.addPath(CGPath(
            roundedRect: pillRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(CGColor(gray: 0, alpha: KeystrokeCaptionMetrics.backgroundAlpha))
        context.fillPath()

        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: pillRect.minX + metrics.paddingHorizontal,
            y: pillRect.midY - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawSubtitleBar(at time: TimeInterval, in context: CGContext) {
        guard let subtitleTimeline,
              let text = subtitleTimeline.text(at: time) else {
            return
        }

        let metrics = SubtitleBarMetrics(canvasSize: canvasSize, style: subtitleStyle)
        let maximumTextWidth = metrics.maximumTextWidth(canvasWidth: canvasSize.width)

        // On narrow canvases the text wraps into centered lines rather
        // than shrinking into a full-width sliver; the font only scales
        // down when even the maximum line count can't hold it.
        var fontSize = metrics.fontSize
        var wrappedLines: [CTLine] = []
        for _ in 0..<3 {
            let font = Self.captionFont(size: fontSize)
            let attributed = subtitleAttributedText(plainText: text, at: time, font: font)
            wrappedLines = Self.wrapLines(attributed, width: maximumTextWidth)
            if wrappedLines.count <= SubtitleBarMetrics.maximumLineCount || fontSize <= 11 {
                break
            }
            fontSize *= CGFloat(SubtitleBarMetrics.maximumLineCount) / CGFloat(wrappedLines.count)
        }
        guard !wrappedLines.isEmpty else { return }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidths = wrappedLines.map {
            CGFloat(CTLineGetTypographicBounds($0, &ascent, &descent, &leading))
        }
        guard let widestLine = lineWidths.max(), widestLine > 0 else { return }
        let lineAdvance = (ascent + descent) * SubtitleBarMetrics.lineSpacingFactor
        let textHeight = ascent + descent + lineAdvance * CGFloat(wrappedLines.count - 1)

        let barSize = CGSize(
            width: widestLine + metrics.paddingHorizontal * 2,
            height: textHeight + metrics.paddingVertical * 2
        )
        let barCenterY = canvasSize.height * CGFloat(subtitleStyle.clampedVerticalPosition)
        let origin = CGPoint(
            x: canvasSize.width / 2 - barSize.width / 2,
            y: barCenterY - barSize.height / 2
        )
        let barRect = flipped(CGRect(origin: origin, size: barSize))

        context.saveGState()
        let radius = min(metrics.cornerRadius, barRect.height / 2)
        context.addPath(CGPath(
            roundedRect: barRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(CGColor(gray: 0, alpha: SubtitleBarMetrics.backgroundAlpha))
        context.fillPath()

        context.textMatrix = .identity
        // The CG context is bottom-up, so the first wrapped line sits at
        // the top of the bar and subsequent lines step downward.
        let firstBaseline = barRect.maxY - metrics.paddingVertical - ascent
        for (index, wrappedLine) in wrappedLines.enumerated() {
            context.textPosition = CGPoint(
                x: barRect.midX - lineWidths[index] / 2,
                y: firstBaseline - lineAdvance * CGFloat(index)
            )
            CTLineDraw(wrappedLine, context)
        }
        context.restoreGState()
    }

    /// Word-wraps an attributed string into CTLines within a width.
    private static func wrapLines(
        _ attributed: NSAttributedString,
        width: CGFloat
    ) -> [CTLine] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: max(24, width), height: 100_000),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        return (CTFrameGetLines(frame) as? [CTLine]) ?? []
    }

    /// The bar's text: karaoke-colored words when word timings exist and
    /// the style asks for them, the plain cue text otherwise. Colors match
    /// StudioSubtitleBarView exactly.
    private func subtitleAttributedText(
        plainText: String,
        at time: TimeInterval,
        font: CTFont
    ) -> NSAttributedString {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        guard subtitleStyle.highlightsSpokenWord,
              let karaokeTimeline,
              let karaokeLine = karaokeTimeline.line(at: time),
              !karaokeLine.words.isEmpty else {
            return NSAttributedString(string: plainText, attributes: [
                fontKey: font,
                colorKey: CGColor(gray: 1, alpha: 1)
            ])
        }

        let text = NSMutableAttributedString()
        for (index, word) in karaokeLine.words.enumerated() {
            let color: CGColor
            if index == karaokeLine.activeIndex {
                color = SubtitleBarMetrics.karaokeAccent
            } else if index < karaokeLine.spokenCount {
                color = CGColor(gray: 1, alpha: 1)
            } else {
                color = CGColor(gray: 1, alpha: SubtitleBarMetrics.karaokeUpcomingAlpha)
            }
            text.append(NSAttributedString(
                string: index > 0 ? " \(word)" : word,
                attributes: [fontKey: font, colorKey: color]
            ))
        }
        return text
    }

    private static func captionFont(size: CGFloat) -> CTFont {
        let descriptor = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        let rounded = descriptor.withDesign(.rounded) ?? descriptor
        return CTFontCreateWithFontDescriptor(rounded as CTFontDescriptor, size, nil)
    }

    private func artwork(
        for pointer: PointerFrame,
        in timeline: PointerTimeline
    ) -> (image: CGImage, anchor: CGPoint, aspectRatio: CGFloat, intrinsicScale: CGFloat)? {
        if let resolved = timeline.artwork(id: pointer.artworkID),
           let image = artworkImage(for: resolved) {
            return (
                image,
                resolved.normalizedAnchor,
                resolved.aspectRatio,
                resolved.intrinsicScale
            )
        }
        return nil
    }

    private func artworkImage(for artwork: PointerArtwork) -> CGImage? {
        if let cached = artworkImageCache[artwork.artworkID] {
            return cached
        }
        guard let source = CGImageSourceCreateWithData(artwork.imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        artworkImageCache[artwork.artworkID] = image
        return image
    }

    /// Layout rects use a top-left origin; CoreGraphics draws bottom-up.
    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func roundedPath(for rect: CGRect, radius: CGFloat) -> CGPath {
        let flippedRect = flipped(rect)
        let boundedRadius = min(radius, min(flippedRect.width, flippedRect.height) / 2)
        guard boundedRadius > 0.5 else { return CGPath(rect: flippedRect, transform: nil) }
        return CGPath(
            roundedRect: flippedRect,
            cornerWidth: boundedRadius,
            cornerHeight: boundedRadius,
            transform: nil
        )
    }

    private static func makeImage(from pixelBuffer: CVPixelBuffer, colorSpace: CGColorSpace) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        return context.makeImage()
    }

    private static func renderBackdrop(
        canvasSize: CGSize,
        layout: RecordingStudioLayout,
        style: RecordingStudioStyle,
        colorSpace: CGColorSpace,
        includesCardShadow: Bool = true
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        switch style.background {
        case .none:
            context.setFillColor(CGColor(gray: 0.04, alpha: 1))
            context.fill(canvasRect)
        case .solid(let color):
            context.setFillColor(CGColor(
                colorSpace: colorSpace,
                components: [color.red, color.green, color.blue, color.alpha]
            ) ?? CGColor(gray: 0, alpha: 1))
            context.fill(canvasRect)
        case .gradient(let gradient):
            let cgColors = gradient.colors.map { color in
                CGColor(
                    colorSpace: colorSpace,
                    components: [color.red, color.green, color.blue, color.alpha]
                ) ?? CGColor(gray: 0, alpha: 1)
            }
            if let cgGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: cgColors as CFArray,
                locations: nil
            ) {
                // UnitPoint has a top-left origin; the context is bottom-up.
                let start = CGPoint(
                    x: gradient.startPoint.x * canvasSize.width,
                    y: canvasSize.height - gradient.startPoint.y * canvasSize.height
                )
                let end = CGPoint(
                    x: gradient.endPoint.x * canvasSize.width,
                    y: canvasSize.height - gradient.endPoint.y * canvasSize.height
                )
                context.drawLinearGradient(cgGradient, start: start, end: end, options: [
                    .drawsBeforeStartLocation,
                    .drawsAfterEndLocation
                ])
            }
        case .customWallpaper(let wallpaper):
            if let source = CGImageSourceCreateWithURL(wallpaper.url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, [
                   kCGImageSourceShouldCache: false
               ] as CFDictionary) {
                let imageSize = CGSize(width: image.width, height: image.height)
                let scale = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
                let fillSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let fillRect = CGRect(
                    x: (canvasSize.width - fillSize.width) / 2,
                    y: (canvasSize.height - fillSize.height) / 2,
                    width: fillSize.width,
                    height: fillSize.height
                )
                context.draw(image, in: fillRect)
            } else {
                context.setFillColor(CGColor(gray: 0.04, alpha: 1))
                context.fill(canvasRect)
            }
        }

        // Card shadow: static, so it lives in the backdrop. The filled shape
        // is fully covered by video pixels every frame.
        if includesCardShadow, style.shadow > 0.01, style.background != .none {
            let minDimension = min(canvasSize.width, canvasSize.height)
            let blur = minDimension * 0.045 * style.shadow
            let cardRect = CGRect(
                x: layout.cardRect.minX,
                y: canvasSize.height - layout.cardRect.maxY,
                width: layout.cardRect.width,
                height: layout.cardRect.height
            )
            let radius = min(layout.cardCornerRadius, min(cardRect.width, cardRect.height) / 2)
            let path = radius > 0.5
                ? CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: cardRect, transform: nil)

            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -blur * 0.35),
                blur: blur,
                color: CGColor(gray: 0, alpha: 0.55 * style.shadow)
            )
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        return context.makeImage()
    }
}
