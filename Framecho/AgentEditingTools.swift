//
//  AgentEditingTools.swift
//  Framecho
//
//  The agent tools, implemented on the Studio model so an agent's edit goes
//  through exactly the code a click in Studio does: the same cut planning,
//  caption rebuilding, zoom clamping, undo registration and export. A
//  project open in a Studio window is edited live in that window; any other
//  project gets a windowless model for the length of the call.
//

import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum AgentEditingTools {
    static func call(
        _ tool: AgentTool,
        arguments args: MCPArguments,
        context: MCPRequestContext
    ) async throws -> MCPToolResult {
        switch tool {
        case .listRecordings:
            return .json(listRecordings(limit: try args.optionalInt("limit") ?? 20))
        case .getRecording:
            return try await read(args) { .json(snapshot(of: $0)) }
        case .getTranscript:
            let includeCut = try args.optionalBool("include_cut") ?? false
            return try await read(args) { .json(transcript(of: $0, includeCut: includeCut)) }
        case .getFrame:
            return try await frame(args)
        case .transcribe:
            return try await transcribe(args)
        case .cut:
            return try await cut(args)
        case .cutWords:
            return try await cutWords(args)
        case .tightenNarration:
            return try await tightenNarration(args)
        case .setSpeed:
            return try await setSpeed(args)
        case .resetCuts:
            return try await edit(args) { model in
                model.resetClips()
                return [:]
            }
        case .addZoom:
            return try await addZoom(args)
        case .updateZoom:
            return try await updateZoom(args)
        case .removeZoom:
            return try await removeZoom(args)
        case .updateSubtitle:
            return try await updateSubtitle(args)
        case .updateSettings:
            return try await updateSettings(args)
        case .setMusic:
            return try await setMusic(args)
        case .addOverlay:
            return try await addOverlay(args)
        case .updateOverlay:
            return try await updateOverlay(args)
        case .removeOverlay:
            return try await removeOverlay(args)
        case .export:
            return try await export(args, context: context)
        case .openInStudio:
            let session = try resolve(args)
            RecordingProjectOpener.shared.open(session)
            NSApp.activate()
            return .json(["opened": .string(session.directoryURL.path)])
        }
    }

    // MARK: - Reading

    private static func listRecordings(limit: Int) -> JSONValue {
        let recordings = RecordingSessionStore.allSessions()
            .map { session in (session: session, manifest: session.loadCaptureManifest()) }
            .map { ($0.session, $0.manifest, createdAt(of: $0.session, manifest: $0.manifest)) }
            .sorted { $0.2 > $1.2 }
            .prefix(max(1, limit))
        let formatter = ISO8601DateFormatter()
        return [
            "recordings": .array(recordings.map { session, manifest, createdAt in
                [
                    "id": .string(session.directoryURL.path),
                    "name": .string(session.displayName),
                    "created_at": .string(formatter.string(from: createdAt)),
                    "duration": .optional(manifest.map { .seconds($0.duration) }),
                    "has_microphone": .bool(manifest?.includesMicrophone == true),
                    "has_camera": .bool(session.hasCamera),
                    "has_transcript": .bool(session.effectiveEditDocument()?.subtitleWords?.isEmpty == false),
                    "open_in_studio": .bool(StudioProjectRegistry.shared.hasLoadedEditor(for: session.directoryURL)),
                ]
            }),
        ]
    }

    private static func snapshot(of model: RecordingStudioModel) -> JSONValue {
        let presets = RecordingStudioStylePresetStore.shared.presets
        let appliedPreset = presets.first { $0.id == model.appliedStylePresetID }
        return [
            "id": .string(model.sessionURL.path),
            "name": .string(model.projectDisplayName),
            "open_in_studio": .bool(!model.isHeadless),
            "source_duration": .seconds(model.sourceDuration),
            "edited_duration": .seconds(model.duration),
            "video": ["width": .int(Int(model.videoSize.width)), "height": .int(Int(model.videoSize.height))],
            "has_audio": .bool(model.hasRecordedAudio),
            "has_microphone": .bool(model.canTranscribe),
            "has_camera": .bool(model.hasCameraVideo),
            "clips": .array(clips(of: model)),
            "zoom": [
                "enabled": .bool(model.zoomEnabled),
                "zooms": .array(model.zoomCues.filter { !$0.isImplicit }.map { zoomJSON($0, in: model) }),
            ],
            "captions": [
                "shown": .bool(model.showsSubtitles),
                "captions": .array(model.subtitleCues.map { cue in
                    let slices = model.clipTimeline.slices(overlapping: cue.start, sourceEnd: cue.end)
                    return [
                        "id": .string(cue.id.uuidString),
                        "text": .string(cue.text),
                        "source_start": .seconds(cue.start),
                        "source_end": .seconds(cue.end),
                        // Where what survives of the caption plays; null once
                        // all of it has been cut.
                        "edited_start": .optional(slices.first.map { .seconds($0.editorStart) }),
                        "edited_end": .optional(slices.last.map { .seconds($0.editorEnd) }),
                    ]
                }),
            ],
            "music": musicJSON(model),
            "image_overlays": .array(model.imageOverlays.map { overlayJSON($0, in: model) }),
            "transcript": [
                "words": .int(model.transcriptWords.count),
                "removable_fillers": .int(model.removableFillerWordCount),
                "trimmable_silences": .int(model.trimmableSilenceCount),
            ],
            "settings": [
                "style_preset": .optional(appliedPreset.map { .string($0.name) }),
                "aspect": .string(model.exportAspect.rawValue),
                "aspect_mode": .string(model.exportAspectMode.rawValue),
                "show_click_effects": .bool(model.showsClickEffects),
                "show_keystrokes": .bool(model.showsKeystrokes),
                "hide_cursor": .bool(model.style.hidesCursor),
                "export_format": .string(model.exportSettings.effectiveContainer.fileExtension),
            ],
            "available": [
                "style_presets": .array(presets.filter { !$0.hasMissingWallpaper }.map { .string($0.name) }),
                "aspects": .array(ExportAspectPreset.allCases.map { .string($0.rawValue) }),
                "aspect_modes": .array(ExportAspectContentMode.allCases.map { .string($0.rawValue) }),
                "music": .array(BackgroundMusicCatalog.tracks.map { track in
                    [
                        "id": .string(track.id),
                        "title": .string(track.title),
                        "mood": .string(track.mood.rawValue),
                        "duration": .seconds(track.duration),
                    ]
                }),
            ],
        ]
    }

    private static func musicJSON(_ model: RecordingStudioModel) -> JSONValue {
        guard let music = model.backgroundMusic else { return .null }
        return [
            "track": .string(music.trackID),
            "title": .optional(music.track.map { .string($0.title) }),
            "volume": .double(music.clampedVolume),
            "loop": .bool(music.loops),
            "duck_under_speech": .bool(music.ducksUnderSpeech),
            // Ducking follows the transcript's words; without one the music
            // stays at its level.
            "ducking_active": .bool(music.ducksUnderSpeech && model.canDuckBackgroundMusic),
        ]
    }

    private static func overlayJSON(_ overlay: RecordingImageOverlay, in model: RecordingStudioModel) -> JSONValue {
        let placement = model.imageOverlayTimeline.placement(for: overlay.id)
        return [
            "id": .string(overlay.id.uuidString),
            "name": .string(overlay.displayName),
            "source_start": .seconds(overlay.start),
            "source_end": .seconds(overlay.end),
            // Null once every second it covered has been cut.
            "edited_start": .optional(placement.map { .seconds($0.editorStart) }),
            "edited_end": .optional(placement.map { .seconds($0.editorEnd) }),
            "position": overlay.anchor.map { .string($0.rawValue) }
                ?? ["x": .double(overlay.center.x), "y": .double(overlay.center.y)],
            "width": .double(overlay.width),
            "opacity": .double(overlay.opacity),
            "corner_radius": .double(overlay.cornerRadius),
            "shadow": .bool(overlay.hasShadow),
            "fade": .bool(overlay.fades),
        ]
    }

    private static func clips(of model: RecordingStudioModel) -> [JSONValue] {
        model.clipTimeline.segments.compactMap { segment in
            guard let range = model.clipTimeline.editorRange(for: segment.id) else { return nil }
            return [
                "source_start": .seconds(segment.sourceStart),
                "source_end": .seconds(segment.sourceEnd),
                "edited_start": .seconds(range.lowerBound),
                "edited_end": .seconds(range.upperBound),
                "speed": .double(segment.speed),
            ]
        }
    }

    private static func zoomJSON(_ cue: ZoomCue, in model: RecordingStudioModel) -> JSONValue {
        let slices = model.clipTimeline.slices(overlapping: cue.start, sourceEnd: cue.end)
        return [
            "id": .string(cue.id.uuidString),
            "source_start": .seconds(cue.start),
            "source_end": .seconds(cue.end),
            // Null when every second of the zoom has been cut.
            "edited_start": .optional(slices.first.map { .seconds($0.editorStart) }),
            "edited_end": .optional(slices.last.map { .seconds($0.editorEnd) }),
            "zoom": .double(cue.zoom),
            "follows_pointer": .bool(cue.anchorMode != .pinnedAnchor),
            "focus": ["x": .double(cue.pinnedPoint.x), "y": .double(cue.pinnedPoint.y)],
            "enabled": .bool(cue.isEnabled),
        ]
    }

    private static func transcript(of model: RecordingStudioModel, includeCut: Bool) -> JSONValue {
        let words = model.transcriptWords
        let entries: [JSONValue] = words.indices.compactMap { index in
            let word = words[index]
            let survives = model.transcriptWordSurvives(index)
            guard survives || includeCut else { return nil }
            var entry: [String: JSONValue] = [
                "i": .int(index),
                "text": .string(word.displayText),
                "start": .seconds(word.start),
                "end": .seconds(word.end),
                "edited": .optional(survives
                    ? (model.editorTime(forSourceTime: word.start) ?? model.editorTime(forSourceTime: word.midpoint))
                        .map(JSONValue.seconds)
                    : nil),
            ]
            if TranscriptEditPlanner.isFiller(word) {
                entry["filler"] = true
            }
            return .object(entry)
        }
        let spoken = TranscriptCaptionText.text(of: words.indices
            .filter { model.transcriptWordSurvives($0) }
            .map { words[$0] })
        return [
            "has_transcript": .bool(!words.isEmpty),
            "text": .string(spoken.trimmingCharacters(in: .whitespacesAndNewlines)),
            "words": .array(entries),
        ]
    }

    private static func frame(_ args: MCPArguments) async throws -> MCPToolResult {
        let time = try args.number("time")
        let isSource = try usesSourceTimeline(args)
        let maxSize = min(max(try args.optionalInt("max_size") ?? 1280, 256), 2048)
        let (url, sourceTime, editedTime) = try await AgentStudioModels.shared.withModel(for: try resolve(args)) { model in
            let sourceTime = isSource
                ? min(max(time, 0), model.sourceDuration)
                : model.sourceTime(atEditorTime: min(max(time, 0), model.duration))
            return (model.screenURL, sourceTime, model.editorTime(forSourceTime: sourceTime))
        }
        let (jpeg, size) = try await frameJPEG(movieURL: url, sourceTime: sourceTime, maxSize: maxSize)
        let info: JSONValue = [
            "source_time": .seconds(sourceTime),
            "edited_time": .optional(editedTime.map(JSONValue.seconds)),
            "width": .int(Int(size.width)),
            "height": .int(Int(size.height)),
        ]
        return MCPToolResult(content: [.image(jpeg, mimeType: "image/jpeg"), .text(JSONLine.encode(info) ?? "")])
    }

    nonisolated private static func frameJPEG(
        movieURL: URL,
        sourceTime: TimeInterval,
        maxSize: Int
    ) async throws -> (Data, CGSize) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let tolerance = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let image = try await generator.image(at: CMTime(seconds: sourceTime, preferredTimescale: 600)).image

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MCPToolError.failed("Couldn't encode the frame.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MCPToolError.failed("Couldn't encode the frame.")
        }
        return (data as Data, CGSize(width: image.width, height: image.height))
    }

    // MARK: - Editing

    private static func transcribe(_ args: MCPArguments) async throws -> MCPToolResult {
        let replace = try args.optionalBool("replace") ?? false
        return try await edit(args) { model in
            guard model.canTranscribe else {
                throw MCPToolError.failed("This recording was made without the microphone, so there is no narration to transcribe.")
            }
            if model.hasTranscriptWords, !replace {
                return [
                    "note": "Already transcribed. Pass replace: true to transcribe again, which discards caption edits.",
                    "words": .int(model.transcriptWords.count),
                ]
            }
            model.transcribe()
            while model.transcriptionState.isTranscribing {
                try await Task.sleep(for: .milliseconds(250))
            }
            if case .failed(let message) = model.transcriptionState {
                throw MCPToolError.failed("Transcription failed: \(message)")
            }
            return [
                "words": .int(model.transcriptWords.count),
                "captions": .int(model.subtitleCues.count),
            ]
        }
    }

    private static func cut(_ args: MCPArguments) async throws -> MCPToolResult {
        let ranges = try args.timeRanges("ranges")
        let isSource = try usesSourceTimeline(args)
        return try await edit(args) { model in
            let sourceRanges = isSource
                ? ranges
                : ranges.flatMap { model.clipTimeline.sourceRanges(forEditorRange: $0) }
            try cutSource(sourceRanges, in: model, actionName: String(localized: "Cut"))
            return [:]
        }
    }

    private static func cutWords(_ args: MCPArguments) async throws -> MCPToolResult {
        let requested = try args.array("ranges").enumerated().map { index, item -> ClosedRange<Int> in
            guard let from = item["from"]?.intValue, let to = item["to"]?.intValue, from <= to else {
                throw MCPToolError.invalidArguments("`ranges[\(index)]` needs integer `from` ≤ `to`")
            }
            return from...to
        }
        return try await edit(args) { model in
            let words = model.transcriptWords
            guard !words.isEmpty else {
                throw MCPToolError.failed("There is no transcript yet. Call transcribe first.")
            }
            let sourceRanges = try requested.map { range in
                guard range.lowerBound >= 0, range.upperBound < words.count else {
                    throw MCPToolError.invalidArguments("Word indices run from 0 to \(words.count - 1)")
                }
                guard let cut = TranscriptEditPlanner.cutRange(
                    forWordsAt: range,
                    in: words,
                    sourceDuration: model.sourceDuration
                ) else {
                    throw MCPToolError.failed("Words \(range.lowerBound)–\(range.upperBound) have no length to cut.")
                }
                return cut
            }
            try cutSource(sourceRanges, in: model, actionName: String(localized: "Cut Words"))
            return [:]
        }
    }

    private static func tightenNarration(_ args: MCPArguments) async throws -> MCPToolResult {
        let removesFillers = try args.optionalBool("remove_fillers") ?? true
        let trimsSilences = try args.optionalBool("trim_silences") ?? true
        return try await edit(args) { model in
            guard model.hasTranscriptWords else {
                throw MCPToolError.failed("There is no transcript yet. Call transcribe first.")
            }
            let fillers = removesFillers ? model.removableFillerWordCount : 0
            let silences = trimsSilences ? model.trimmableSilenceCount : 0
            var ranges: [ClosedRange<TimeInterval>] = []
            if removesFillers {
                ranges += TranscriptEditPlanner.fillerCutRanges(in: model.transcriptWords, sourceDuration: model.sourceDuration)
            }
            if trimsSilences {
                ranges += TranscriptEditPlanner.silenceCutRanges(in: model.transcriptWords, sourceDuration: model.sourceDuration)
            }
            if !ranges.isEmpty {
                try cutSource(ranges, in: model, actionName: String(localized: "Tighten Narration"))
            }
            return ["fillers_removed": .int(fillers), "silences_trimmed": .int(silences)]
        }
    }

    private static func cutSource(
        _ ranges: [ClosedRange<TimeInterval>],
        in model: RecordingStudioModel,
        actionName: String
    ) throws {
        let clamped = ranges.compactMap { range -> ClosedRange<TimeInterval>? in
            let lower = max(0, range.lowerBound)
            let upper = min(model.sourceDuration, range.upperBound)
            return upper > lower ? lower...upper : nil
        }
        guard !clamped.isEmpty else {
            throw MCPToolError.invalidArguments("The ranges fall outside the recording.")
        }
        guard model.clipTimeline.removingSourceRanges(clamped) != nil else {
            throw MCPToolError.failed("That would cut the whole recording.")
        }
        model.cutSourceRanges(clamped, actionName: actionName)
    }

    private static func setSpeed(_ args: MCPArguments) async throws -> MCPToolResult {
        let start = try args.number("start")
        let end = try args.number("end")
        let speed = try args.number("speed")
        let isSource = try usesSourceTimeline(args)
        guard end > start else { throw MCPToolError.invalidArguments("`end` must be after `start`") }
        guard (RecordingClipSegment.minimumSpeed...RecordingClipSegment.maximumSpeed).contains(speed) else {
            throw MCPToolError.invalidArguments("`speed` must be between 1 and 8")
        }
        return try await edit(args) { model in
            let range = try editorRange(start, end, isSource: isSource, in: model)
            model.setSpeed(speed, forEditorRange: range)
            return [:]
        }
    }

    private static func addZoom(_ args: MCPArguments) async throws -> MCPToolResult {
        let start = try args.number("start")
        let end = try args.number("end")
        let isSource = try usesSourceTimeline(args)
        let zoom = try args.optionalNumber("zoom")
        let focus = try point(args, "focus")
        guard end > start else { throw MCPToolError.invalidArguments("`end` must be after `start`") }
        return try await edit(args) { model in
            let range = try editorRange(start, end, isSource: isSource, in: model)
            guard let id = model.addZoomCue(fromEditorTime: range.lowerBound, toEditorTime: range.upperBound) else {
                throw MCPToolError.failed("No room for a zoom there: it is covered by existing zooms. Update or remove one first.")
            }
            if zoom != nil || focus != nil, var cue = model.zoomCues.first(where: { $0.id == id }) {
                if let zoom { cue.zoom = zoom }
                if let focus {
                    cue.pinnedPoint = focus
                    cue.anchorMode = .pinnedAnchor
                }
                applyZoomEdit(cue, to: model)
            }
            guard let cue = model.zoomCues.first(where: { $0.id == id }) else { return [:] }
            return ["zoom": zoomJSON(cue, in: model)]
        }
    }

    private static func updateZoom(_ args: MCPArguments) async throws -> MCPToolResult {
        let id = try uuid(args, "id")
        let start = try args.optionalNumber("start")
        let end = try args.optionalNumber("end")
        let isSource = try usesSourceTimeline(args)
        let zoom = try args.optionalNumber("zoom")
        let focus = try point(args, "focus")
        let followsPointer = try args.optionalBool("follow_pointer")
        let isEnabled = try args.optionalBool("enabled")
        return try await edit(args) { model in
            guard var cue = model.zoomCues.first(where: { $0.id == id && !$0.isImplicit }) else {
                throw MCPToolError.failed("No zoom with id \(id.uuidString). get_recording lists them.")
            }
            if let start {
                cue.start = try sourceTime(start, isSource: isSource, in: model)
            }
            if let end {
                cue.end = try sourceTime(end, isSource: isSource, in: model)
            }
            guard cue.end > cue.start else {
                throw MCPToolError.invalidArguments("The zoom would end before it starts")
            }
            if let zoom { cue.zoom = zoom }
            if let focus {
                cue.pinnedPoint = focus
                cue.anchorMode = .pinnedAnchor
            }
            if let followsPointer {
                cue.anchorMode = followsPointer ? .pointerAnchor : .pinnedAnchor
            }
            if let isEnabled { cue.isEnabled = isEnabled }
            applyZoomEdit(cue, to: model)
            guard let updated = model.zoomCues.first(where: { $0.id == id }) else { return [:] }
            return ["zoom": zoomJSON(updated, in: model)]
        }
    }

    /// One undo step, clamped against the neighboring zooms the way a drag is.
    private static func applyZoomEdit(_ cue: ZoomCue, to model: RecordingStudioModel) {
        model.beginZoomCueEdit()
        model.updateZoomCue(cue)
        model.endZoomCueEdit()
    }

    private static func removeZoom(_ args: MCPArguments) async throws -> MCPToolResult {
        let removesAll = try args.optionalBool("all") ?? false
        let id = removesAll ? nil : try uuid(args, "id")
        return try await edit(args) { model in
            let targets = model.zoomCues.filter { !$0.isImplicit && (removesAll || $0.id == id) }
            guard !targets.isEmpty || removesAll else {
                throw MCPToolError.failed("No zoom with id \(id?.uuidString ?? ""). get_recording lists them.")
            }
            for cue in targets {
                model.removeZoomCue(id: cue.id)
            }
            return ["removed": .int(targets.count)]
        }
    }

    private static func updateSubtitle(_ args: MCPArguments) async throws -> MCPToolResult {
        let id = try uuid(args, "id")
        guard let text = args.values["text"]?.stringValue else {
            throw MCPToolError.invalidArguments("`text` must be a string")
        }
        return try await edit(args) { model in
            guard model.subtitleCues.contains(where: { $0.id == id }) else {
                throw MCPToolError.failed("No caption with id \(id.uuidString). get_recording lists them.")
            }
            model.beginSubtitleEdit()
            model.updateSubtitleText(id: id, text: text)
            model.endSubtitleEdit(actionName: String(localized: "Edit Caption"))
            return [:]
        }
    }

    private static func updateSettings(_ args: MCPArguments) async throws -> MCPToolResult {
        let presetName = try args.optionalString("style_preset")
        let aspect = try args.optionalChoice("aspect", in: ExportAspectPreset.allCases.map(\.rawValue))
            .flatMap(ExportAspectPreset.init(rawValue:))
        let aspectMode = try args.optionalChoice("aspect_mode", in: ExportAspectContentMode.allCases.map(\.rawValue))
            .flatMap(ExportAspectContentMode.init(rawValue:))
        let zoomEnabled = try args.optionalBool("zoom_enabled")
        let showsSubtitles = try args.optionalBool("show_subtitles")
        let showsClickEffects = try args.optionalBool("show_click_effects")
        let showsKeystrokes = try args.optionalBool("show_keystrokes")
        let hidesCursor = try args.optionalBool("hide_cursor")

        return try await edit(args) { model in
            // The preset goes first: it sets the cursor too, and an explicit
            // hide_cursor in the same call should win.
            if let presetName {
                let presets = RecordingStudioStylePresetStore.shared.presets.filter { !$0.hasMissingWallpaper }
                guard let preset = presets.first(where: {
                    $0.name.compare(presetName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) else {
                    let names = presets.map(\.name).joined(separator: ", ")
                    throw MCPToolError.invalidArguments(
                        names.isEmpty
                            ? "There are no style presets. The user can save one in Studio."
                            : "No style preset named “\(presetName)”. Available: \(names)"
                    )
                }
                model.applyStylePreset(preset)
            }
            if let aspect { model.exportAspect = aspect }
            if let aspectMode { model.exportAspectMode = aspectMode }
            if let zoomEnabled { model.zoomEnabled = zoomEnabled }
            if let showsSubtitles { model.showsSubtitles = showsSubtitles }
            if let showsClickEffects { model.showsClickEffects = showsClickEffects }
            if let showsKeystrokes { model.showsKeystrokes = showsKeystrokes }
            if let hidesCursor { model.style.hidesCursor = hidesCursor }
            return [:]
        }
    }

    private static func setMusic(_ args: MCPArguments) async throws -> MCPToolResult {
        let reference = try args.optionalString("track")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let volume = try args.optionalNumber("volume")
        let loops = try args.optionalBool("loop")
        let ducks = try args.optionalBool("duck_under_speech")
        if let volume, !RecordingBackgroundMusic.volumeRange.contains(volume) {
            throw MCPToolError.invalidArguments("`volume` must be between 0 and 1")
        }
        return try await edit(args) { model in
            if reference?.lowercased() == "none" {
                model.removeBackgroundMusic()
                return ["music": .null]
            }
            if let reference {
                guard let track = BackgroundMusicCatalog.tracks.first(where: {
                    $0.id == reference || $0.title.compare(reference, options: [.caseInsensitive]) == .orderedSame
                }) else {
                    let ids = BackgroundMusicCatalog.tracks.map(\.id).joined(separator: ", ")
                    throw MCPToolError.invalidArguments("No track “\(reference)”. Available: \(ids)")
                }
                if model.backgroundMusic?.trackID != track.id {
                    model.chooseBackgroundMusic(track)
                }
            } else if model.backgroundMusic == nil {
                throw MCPToolError.invalidArguments("There is no music yet; pass `track` to choose one.")
            }
            if let volume { model.backgroundMusicVolume = volume }
            if let loops { model.backgroundMusicLoops = loops }
            if let ducks { model.backgroundMusicDucksUnderSpeech = ducks }
            try await waitForMusic(model)
            return ["music": musicJSON(model)]
        }
    }

    private static func addOverlay(_ args: MCPArguments) async throws -> MCPToolResult {
        let path = (try args.string("path") as NSString).expandingTildeInPath
        let start = try args.number("start")
        let end = try args.number("end")
        let isSource = try usesSourceTimeline(args)
        guard end > start else { throw MCPToolError.invalidArguments("`end` must be after `start`") }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw MCPToolError.invalidArguments("No readable file at \(path)")
        }
        let style = try OverlayStyleArguments(args)
        return try await edit(args) { model in
            let range = try editorRange(start, end, isSource: isSource, in: model)
            let id: UUID
            do {
                id = try model.addImageOverlay(from: URL(fileURLWithPath: path), at: range.lowerBound)
            } catch {
                throw MCPToolError.failed(error.localizedDescription)
            }
            guard var overlay = model.imageOverlays.first(where: { $0.id == id }) else { return [:] }
            overlay.start = model.sourceTime(atEditorTime: range.lowerBound)
            overlay.end = model.sourceTime(atEditorTime: range.upperBound)
            style.apply(to: &overlay)
            model.updateImageOverlay(overlay)
            guard let added = model.imageOverlays.first(where: { $0.id == id }) else { return [:] }
            return ["overlay": overlayJSON(added, in: model)]
        }
    }

    private static func updateOverlay(_ args: MCPArguments) async throws -> MCPToolResult {
        let id = try uuid(args, "id")
        let start = try args.optionalNumber("start")
        let end = try args.optionalNumber("end")
        let isSource = try usesSourceTimeline(args)
        let style = try OverlayStyleArguments(args)
        return try await edit(args) { model in
            guard var overlay = model.imageOverlays.first(where: { $0.id == id }) else {
                throw MCPToolError.failed("No image overlay with id \(id.uuidString). get_recording lists them.")
            }
            if let start { overlay.start = try sourceTime(start, isSource: isSource, in: model) }
            if let end { overlay.end = try sourceTime(end, isSource: isSource, in: model) }
            guard overlay.end > overlay.start else {
                throw MCPToolError.invalidArguments("The overlay would end before it starts")
            }
            style.apply(to: &overlay)
            model.updateImageOverlay(overlay)
            guard let updated = model.imageOverlays.first(where: { $0.id == id }) else { return [:] }
            return ["overlay": overlayJSON(updated, in: model)]
        }
    }

    private static func removeOverlay(_ args: MCPArguments) async throws -> MCPToolResult {
        let removesAll = try args.optionalBool("all") ?? false
        let id = removesAll ? nil : try uuid(args, "id")
        return try await edit(args) { model in
            let targets = model.imageOverlays.filter { removesAll || $0.id == id }
            guard !targets.isEmpty || removesAll else {
                throw MCPToolError.failed("No image overlay with id \(id?.uuidString ?? ""). get_recording lists them.")
            }
            for overlay in targets {
                model.removeImageOverlay(id: overlay.id)
            }
            return ["removed": .int(targets.count)]
        }
    }

    /// The look-and-place arguments add_overlay and update_overlay share.
    private struct OverlayStyleArguments {
        var anchor: RecordingImageOverlayAnchor?
        var center: CGPoint?
        var width: Double?
        var opacity: Double?
        var cornerRadius: Double?
        var hasShadow: Bool?
        var fades: Bool?

        init(_ args: MCPArguments) throws {
            if let position = args.values["position"], position != .null {
                if let name = position.stringValue {
                    guard let anchor = RecordingImageOverlayAnchor(rawValue: name) else {
                        let names = RecordingImageOverlayAnchor.allCases.map(\.rawValue).joined(separator: ", ")
                        throw MCPToolError.invalidArguments("`position` must be one of: \(names), or {x, y}")
                    }
                    self.anchor = anchor
                } else {
                    center = try point(args, "position")
                }
            }
            width = try args.optionalNumber("width")
            opacity = try args.optionalNumber("opacity")
            cornerRadius = try args.optionalNumber("corner_radius")
            hasShadow = try args.optionalBool("shadow")
            fades = try args.optionalBool("fade")
            if let width, !RecordingImageOverlay.widthRange.contains(width) {
                throw MCPToolError.invalidArguments("`width` must be between 0.04 and 1")
            }
            if let opacity, !(0...1).contains(opacity) {
                throw MCPToolError.invalidArguments("`opacity` must be between 0 and 1")
            }
            if let cornerRadius, !RecordingImageOverlay.cornerRadiusRange.contains(cornerRadius) {
                throw MCPToolError.invalidArguments("`corner_radius` must be between 0 and 0.5")
            }
        }

        func apply(to overlay: inout RecordingImageOverlay) {
            if let width { overlay.width = width }
            if let opacity { overlay.opacity = opacity }
            if let cornerRadius { overlay.cornerRadius = cornerRadius }
            if let hasShadow { overlay.hasShadow = hasShadow }
            if let fades { overlay.fades = fades }
            if let anchor {
                overlay.anchor = anchor
            } else if let center {
                overlay.anchor = nil
                overlay.center = center
            }
        }
    }

    /// A new track downloads before it can play or export. Waiting here
    /// means a reply of success is music that is really in the video.
    private static func waitForMusic(_ model: RecordingStudioModel) async throws {
        while model.isLoadingBackgroundMusic {
            try await Task.sleep(for: .milliseconds(200))
        }
        if model.backgroundMusic != nil, model.loadedBackgroundMusic == nil {
            throw MCPToolError.failed("The music couldn't be loaded: \(model.backgroundMusicError ?? "unknown error")")
        }
    }

    private static func export(_ args: MCPArguments, context: MCPRequestContext) async throws -> MCPToolResult {
        let session = try resolve(args)
        return try await AgentStudioModels.shared.withModel(for: session) { model in
            guard !model.exportState.isExporting, !model.shareState.isBusy else {
                throw MCPToolError.failed("This recording is already being rendered. Try again when it finishes.")
            }
            // A freshly loaded project may still be fetching its music; an
            // export started now would leave it out.
            try await waitForMusic(model)
            // Cleared first so a result left by an earlier export can't be
            // mistaken for this one's.
            model.exportState = .idle
            model.export()

            var sawProgress = false
            var reported = -1.0
            while true {
                switch model.exportState {
                case .finished(let url):
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return .json(["path": .string(url.path), "bytes": .int(size)])
                case .failed(let message):
                    throw MCPToolError.failed("Export failed: \(message)")
                case .exporting(let progress):
                    sawProgress = true
                    if progress - reported >= 0.01 {
                        reported = progress
                        context.reportProgress(progress, total: 1, message: "Rendering")
                    }
                case .idle:
                    // Idle after rendering started means it was cancelled in
                    // Studio; before that, a cached render is being copied.
                    if sawProgress { throw MCPToolError.failed("The export was cancelled.") }
                }
                if Task.isCancelled {
                    model.cancelExport()
                    throw CancellationError()
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - Helpers

    /// Runs a change on the project and saves it, replying with what the
    /// change returned plus the timeline it left.
    private static func edit(
        _ args: MCPArguments,
        _ change: (RecordingStudioModel) async throws -> [String: JSONValue]
    ) async throws -> MCPToolResult {
        let session = try resolve(args)
        return try await AgentStudioModels.shared.withModel(for: session) { model in
            let before = model.currentDocument()
            var reply = try await change(model)
            let changed = model.currentDocument() != before
            if changed {
                try model.commitProject()
            }
            reply["changed"] = .bool(changed)
            reply["edited_duration"] = .seconds(model.duration)
            reply["clips"] = .int(model.clipTimeline.segments.count)
            return .json(.object(reply))
        }
    }

    private static func read(
        _ args: MCPArguments,
        _ body: (RecordingStudioModel) throws -> MCPToolResult
    ) async throws -> MCPToolResult {
        try await AgentStudioModels.shared.withModel(for: try resolve(args)) { try body($0) }
    }

    /// Finds a recording by package path, folder name, display name, or
    /// "latest".
    static func resolve(_ args: MCPArguments) throws -> RecordingSession {
        let reference = try args.string("recording").trimmingCharacters(in: .whitespacesAndNewlines)

        if reference.hasPrefix("/") || reference.hasPrefix("~") {
            let url = URL(fileURLWithPath: (reference as NSString).expandingTildeInPath).standardizedFileURL
            guard RecordingSession.isSessionDirectory(url), FileManager.default.fileExists(atPath: url.path) else {
                throw MCPToolError.failed("No recording at \(url.path). Call list_recordings for valid ids.")
            }
            return RecordingSession(directoryURL: url)
        }

        let sessions = RecordingSessionStore.allSessions()
        if reference.lowercased() == "latest" {
            guard let latest = sessions.max(by: {
                createdAt(of: $0, manifest: $0.loadCaptureManifest()) < createdAt(of: $1, manifest: $1.loadCaptureManifest())
            }) else {
                throw MCPToolError.failed("There are no recordings yet.")
            }
            return latest
        }

        let matches = sessions.filter { session in
            let folder = session.directoryURL.lastPathComponent
            return [folder, session.directoryURL.deletingPathExtension().lastPathComponent, session.displayName]
                .contains { $0.compare(reference, options: [.caseInsensitive]) == .orderedSame }
        }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw MCPToolError.failed("No recording named “\(reference)”. Call list_recordings for valid ids.")
        default:
            let ids = matches.map(\.directoryURL.path).joined(separator: "\n")
            throw MCPToolError.failed("Several recordings are named “\(reference)”. Use one of these ids:\n\(ids)")
        }
    }

    private static func createdAt(of session: RecordingSession, manifest: CaptureManifest?) -> Date {
        manifest?.createdAt
            ?? (try? session.directoryURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? .distantPast
    }

    private static func usesSourceTimeline(_ args: MCPArguments) throws -> Bool {
        try args.optionalChoice("timeline", in: ["edited", "source"]) == "source"
    }

    /// An agent's range as editor time, refusing source times that were cut.
    private static func editorRange(
        _ start: TimeInterval,
        _ end: TimeInterval,
        isSource: Bool,
        in model: RecordingStudioModel
    ) throws -> ClosedRange<TimeInterval> {
        guard isSource else {
            let lower = min(max(start, 0), model.duration)
            let upper = min(max(end, 0), model.duration)
            guard upper > lower else {
                throw MCPToolError.invalidArguments("The range is outside the edited video (0–\(String(format: "%.2f", model.duration)) s)")
            }
            return lower...upper
        }
        guard let lower = model.editorTime(forSourceTime: start), let upper = model.editorTime(forSourceTime: end),
              upper > lower else {
            throw MCPToolError.invalidArguments("Source times \(start)–\(end) fall in a cut. Use edited times, or times that still play.")
        }
        return lower...upper
    }

    private static func sourceTime(_ time: TimeInterval, isSource: Bool, in model: RecordingStudioModel) throws -> TimeInterval {
        isSource
            ? min(max(time, 0), model.sourceDuration)
            : model.sourceTime(atEditorTime: min(max(time, 0), model.duration))
    }

    private static func uuid(_ args: MCPArguments, _ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try args.string(key)) else {
            throw MCPToolError.invalidArguments("`\(key)` must be an id from get_recording")
        }
        return id
    }

    private static func point(_ args: MCPArguments, _ key: String) throws -> CGPoint? {
        guard let object = try args.optionalObject(key) else { return nil }
        guard let x = object["x"]?.doubleValue, let y = object["y"]?.doubleValue,
              (0...1).contains(x), (0...1).contains(y) else {
            throw MCPToolError.invalidArguments("`\(key)` needs `x` and `y` between 0 and 1")
        }
        return CGPoint(x: x, y: y)
    }
}

/// Lends tools a loaded Studio model. A project open in a Studio window is
/// edited through that window's model; otherwise a windowless one is loaded
/// for the call and torn down after it, so it can never go stale behind a
/// window the user opens later. Concurrent calls on the same project share it.
@MainActor
final class AgentStudioModels {
    static let shared = AgentStudioModels()

    private struct Entry {
        let model: RecordingStudioModel
        let loading: Task<Void, Never>
        var users: Int
    }

    private var entries: [String: Entry] = [:]

    private init() {}

    func withModel<T>(
        for session: RecordingSession,
        _ body: (RecordingStudioModel) async throws -> T
    ) async throws -> T {
        if let open = StudioProjectRegistry.shared.loadedModel(for: session.directoryURL) {
            return try await body(open)
        }
        let key = session.directoryURL.standardizedFileURL.path
        let model = try await acquire(key, session: session)
        defer { release(key) }
        return try await body(model)
    }

    private func acquire(_ key: String, session: RecordingSession) async throws -> RecordingStudioModel {
        let entry: Entry
        if var existing = entries[key] {
            existing.users += 1
            entries[key] = existing
            entry = existing
        } else {
            let model = RecordingStudioModel(url: session.directoryURL, isHeadless: true)
            entry = Entry(model: model, loading: Task { await model.load() }, users: 1)
            entries[key] = entry
        }
        await entry.loading.value
        guard entry.model.isLoaded else {
            release(key)
            throw MCPToolError.failed(entry.model.loadError ?? "The recording could not be opened.")
        }
        return entry.model
    }

    private func release(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.users -= 1
        guard entry.users <= 0 else {
            entries[key] = entry
            return
        }
        entries[key] = nil
        entry.model.teardown()
    }
}
