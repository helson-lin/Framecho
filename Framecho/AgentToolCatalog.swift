//
//  AgentToolCatalog.swift
//  Framecho
//
//  What agents see: the tool list, each tool's input schema, and the
//  server instructions. The implementations live in AgentEditingTools,
//  on the main actor beside the Studio model they drive.
//

import Foundation

nonisolated enum AgentTool: String, CaseIterable, Sendable {
    case listRecordings = "list_recordings"
    case getRecording = "get_recording"
    case getTranscript = "get_transcript"
    case getFrame = "get_frame"
    case transcribe
    case cut
    case cutWords = "cut_words"
    case tightenNarration = "tighten_narration"
    case setSpeed = "set_speed"
    case resetCuts = "reset_cuts"
    case addZoom = "add_zoom"
    case updateZoom = "update_zoom"
    case removeZoom = "remove_zoom"
    case updateSubtitle = "update_subtitle"
    case updateSettings = "update_settings"
    case setMusic = "set_music"
    case addOverlay = "add_overlay"
    case updateOverlay = "update_overlay"
    case removeOverlay = "remove_overlay"
    case setCard = "set_card"
    case removeCard = "remove_card"
    case export
    case openInStudio = "open_in_studio"
}

nonisolated enum AgentToolCatalog {
    static let instructions = """
    Framecho is a macOS screen recorder. These tools edit its recordings the way its Studio editor does: \
    cuts, speed changes, zooms, captions and styling are stored as a non-destructive project beside the \
    original footage, which is never modified. Every edit is saved as soon as it is made. If the \
    recording is open in a Studio window the edit appears there live and the user can undo it with ⌘Z; \
    reset_cuts restores the full recording.

    Times are seconds. Most tools take times on the edited timeline - what plays after cuts and speed \
    changes, starting at 0 - and accept `timeline: "source"` for times in the original recording. \
    Transcript words keep their source times, so their indices and times stay valid across cuts.

    A typical pass: list_recordings → get_recording → get_transcript (call transcribe first if there is \
    none) → cut_words / tighten_narration / cut → add_zoom where something small happens on screen \
    (get_frame shows what is on screen at a time) → add_overlay for a logo, QR code or screenshot \
    the user supplies → set_card for an intro or outro → set_music if the user wants a soundtrack → \
    get_recording to review → export. Make the edits the \
    user asked for; don't export unless they want a file.
    """

    static var tools: [MCPToolDefinition] {
        AgentTool.allCases.map(definition)
    }

    static func definition(for tool: AgentTool) -> MCPToolDefinition {
        switch tool {
        case .listRecordings:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "List recordings",
                description: "Lists screen recordings, newest first, with each one's id, name, length and whether it has a transcript.",
                inputSchema: AgentSchema.object([
                    "limit": AgentSchema.integer("Most recordings to return. Default 20."),
                ]),
                isReadOnly: true
            )
        case .getRecording:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Get recording",
                description: "The recording's full edit state: final_duration (with intro and outro cards), clips (what survives the cuts, with source and edited times and speed), zooms, captions, display settings, and the style presets and aspect ratios available.",
                inputSchema: AgentSchema.object(["recording": AgentSchema.recording], required: ["recording"]),
                isReadOnly: true
            )
        case .getTranscript:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Get transcript",
                description: "The narration transcript as timed words. Each word has an index `i` (used by cut_words), its source time, and its edited time (null once cut). English hesitations (um, uh, er) are flagged as fillers; in other languages, spot fillers yourself and pass them to cut_words. Empty until transcribe has run.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "include_cut": AgentSchema.boolean("Also list words that have already been cut. Default false."),
                ], required: ["recording"]),
                isReadOnly: true
            )
        case .getFrame:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Get frame",
                description: "A still of the raw screen recording at a time, as a JPEG image, to see what is on screen. Shows the captured screen only - no background, zoom or captions.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "time": AgentSchema.number("Seconds."),
                    "timeline": AgentSchema.timeline,
                    "max_size": AgentSchema.integer("Longest edge in pixels, 256–2048. Default 1280."),
                ], required: ["recording", "time"]),
                isReadOnly: true
            )
        case .transcribe:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Transcribe narration",
                description: "Transcribes the recorded microphone on this Mac and turns on captions. Takes about a tenth of the recording's length. Needs a recording made with the microphone on.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "replace": AgentSchema.boolean("Transcribe again even if there is already a transcript, replacing it and any caption edits. Default false."),
                ], required: ["recording"]),
                isReadOnly: false,
                isDestructive: true
            )
        case .cut:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Cut time ranges",
                description: "Removes time ranges from the video, with their audio. Captions over a cut lose the words that were cut. All ranges are read against the timeline as it was before this call.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "ranges": AgentSchema.ranges("Ranges to remove."),
                    "timeline": AgentSchema.timeline,
                ], required: ["recording", "ranges"]),
                isReadOnly: false,
                isDestructive: true
            )
        case .cutWords:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Cut transcript words",
                description: "Removes the video and audio under transcript words, by index from get_transcript. Each cut reaches a little into the pauses around the words so the splice lands in silence.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "ranges": .object([
                        "type": "array",
                        "minItems": 1,
                        "description": "Inclusive word index ranges, e.g. [{\"from\": 12, \"to\": 18}].",
                        "items": AgentSchema.object([
                            "from": AgentSchema.integer("First word index."),
                            "to": AgentSchema.integer("Last word index, inclusive."),
                        ], required: ["from", "to"]),
                    ]),
                ], required: ["recording", "ranges"]),
                isReadOnly: false,
                isDestructive: true
            )
        case .tightenNarration:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Tighten narration",
                description: "Cuts English hesitations (um, uh, er) and long pauses (over 1.1 s, keeping a natural beat on each side), the same as Studio's transcript tools. For fillers in other languages, use cut_words. Needs a transcript.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "remove_fillers": AgentSchema.boolean("Cut filler words. Default true."),
                    "trim_silences": AgentSchema.boolean("Shorten long pauses. Default true."),
                ], required: ["recording"]),
                isReadOnly: false,
                isDestructive: true
            )
        case .setSpeed:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Set speed",
                description: "Plays a range faster (1–8×), video and audio together - for typing, loading or other slow stretches. Use 1 to return a range to normal speed.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "start": AgentSchema.number("Range start, seconds."),
                    "end": AgentSchema.number("Range end, seconds."),
                    "speed": AgentSchema.number("Playback speed, 1 to 8."),
                    "timeline": AgentSchema.timeline,
                ], required: ["recording", "start", "end", "speed"]),
                isReadOnly: false
            )
        case .resetCuts:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Reset cuts",
                description: "Restores the full recording: removes every cut and speed change. Zooms, captions and style are kept.",
                inputSchema: AgentSchema.object(["recording": AgentSchema.recording], required: ["recording"]),
                isReadOnly: false,
                isDestructive: true
            )
        case .addZoom:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Add zoom",
                description: "Zooms the camera in over a range. By default the zoom follows the pointer; pass `focus` to hold on a fixed point instead. Zooms can't overlap: a range that runs into another zoom is shortened, and the reply gives the times actually used.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "start": AgentSchema.number("Zoom start, seconds."),
                    "end": AgentSchema.number("Zoom end, seconds."),
                    "timeline": AgentSchema.timeline,
                    "zoom": AgentSchema.number("Magnification, 1–4. Default 1.5."),
                    "focus": AgentSchema.point,
                ], required: ["recording", "start", "end"]),
                isReadOnly: false
            )
        case .updateZoom:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Update zoom",
                description: "Changes a zoom's range, magnification or focus. Omitted fields stay as they are.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "id": AgentSchema.string("Zoom id from get_recording."),
                    "start": AgentSchema.number("New start, seconds."),
                    "end": AgentSchema.number("New end, seconds."),
                    "timeline": AgentSchema.timeline,
                    "zoom": AgentSchema.number("Magnification, 1–4."),
                    "focus": AgentSchema.point,
                    "follow_pointer": AgentSchema.boolean("true to follow the pointer instead of a fixed focus."),
                    "enabled": AgentSchema.boolean("false to keep the zoom but skip it."),
                ], required: ["recording", "id"]),
                isReadOnly: false
            )
        case .removeZoom:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Remove zoom",
                description: "Removes one zoom by id, or every zoom with `all: true`.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "id": AgentSchema.string("Zoom id from get_recording."),
                    "all": AgentSchema.boolean("Remove every zoom."),
                ], required: ["recording"]),
                isReadOnly: false,
                isDestructive: true
            )
        case .updateSubtitle:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Update caption",
                description: "Replaces the text of one caption, e.g. to fix a misheard word. Timing is unchanged.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "id": AgentSchema.string("Caption id from get_recording."),
                    "text": AgentSchema.string("New caption text."),
                ], required: ["recording", "id", "text"]),
                isReadOnly: false
            )
        case .updateSettings:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Update settings",
                description: "Changes how the recording is presented. Only the fields passed change.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "style_preset": AgentSchema.string("Name of a saved Studio style preset (see get_recording) - background, padding, corners, shadow, cursor and camera."),
                    "aspect": AgentSchema.choice(ExportAspectPreset.allCases.map(\.rawValue), "Output aspect ratio."),
                    "aspect_mode": AgentSchema.choice(ExportAspectContentMode.allCases.map(\.rawValue), "fill crops and follows the pointer; fit shows the whole recording on the background."),
                    "zoom_enabled": AgentSchema.boolean("Turn every zoom on or off."),
                    "show_subtitles": AgentSchema.boolean("Show captions."),
                    "show_click_effects": AgentSchema.boolean("Show click ripples."),
                    "show_keystrokes": AgentSchema.boolean("Show typed shortcuts."),
                    "hide_cursor": AgentSchema.boolean("Hide the pointer."),
                ], required: ["recording"]),
                isReadOnly: false
            )
        case .setMusic:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Set background music",
                description: "Lays a track from Framecho's music library under the whole video (get_recording lists them under available.music, with mood and length). It fades in and out, loops to cover the video, and dips under the narration while someone speaks - which needs a transcript. Pass track \"none\" to remove the music; omit track to adjust the current music.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "track": AgentSchema.string("Track id or title from available.music, or \"none\"."),
                    "volume": AgentSchema.number("Music level, 0–1. Default 0.35; keep it low under narration."),
                    "loop": AgentSchema.boolean("Repeat the track to cover a video longer than it. Default true."),
                    "duck_under_speech": AgentSchema.boolean("Lower the music while the narration speaks. Default true."),
                ], required: ["recording"]),
                isReadOnly: false
            )
        case .addOverlay:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Add image overlay",
                description: "Lays an image file from this Mac (PNG, JPEG, HEIC…; transparency kept) over the video for a time range - a logo, QR code or screenshot. It sits on the canvas: it doesn't zoom with the camera and stays in frame in any aspect ratio, above the screen and below the camera bubble and captions. The file is copied into the project. Fades in and out by default.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "path": AgentSchema.string("Absolute path of the image file."),
                    "start": AgentSchema.number("When the image appears, seconds."),
                    "end": AgentSchema.number("When it disappears, seconds."),
                    "timeline": AgentSchema.timeline,
                    "position": AgentSchema.overlayPosition,
                    "width": AgentSchema.number("Width as a share of the video width, 0.04–1. Default 0.22."),
                    "opacity": AgentSchema.number("0–1. Default 1."),
                    "corner_radius": AgentSchema.number("Rounding as a share of the image's shorter side, 0–0.5. Default 0."),
                    "shadow": AgentSchema.boolean("Drop shadow. Default false."),
                    "fade": AgentSchema.boolean("Fade in and out. Default true."),
                ], required: ["recording", "path", "start", "end"]),
                isReadOnly: false
            )
        case .updateOverlay:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Update image overlay",
                description: "Changes an image overlay's timing, position, size or look. Omitted fields stay as they are.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "id": AgentSchema.string("Overlay id from get_recording."),
                    "start": AgentSchema.number("New start, seconds."),
                    "end": AgentSchema.number("New end, seconds."),
                    "timeline": AgentSchema.timeline,
                    "position": AgentSchema.overlayPosition,
                    "width": AgentSchema.number("Width as a share of the video width, 0.04–1."),
                    "opacity": AgentSchema.number("0–1."),
                    "corner_radius": AgentSchema.number("0–0.5."),
                    "shadow": AgentSchema.boolean("Drop shadow."),
                    "fade": AgentSchema.boolean("Fade in and out."),
                ], required: ["recording", "id"]),
                isReadOnly: false
            )
        case .removeOverlay:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Remove image overlay",
                description: "Removes one image overlay by id, or every one with `all: true`.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "id": AgentSchema.string("Overlay id from get_recording."),
                    "all": AgentSchema.boolean("Remove every image overlay."),
                ], required: ["recording"]),
                isReadOnly: false,
                isDestructive: true
            )
        case .setCard:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Set intro or outro card",
                description: "Adds or changes the card shown before (intro) or after (outro) the video: a title and subtitle on the project's background, or an image file from this Mac. Cards sit outside the edit - edited times, cuts, zooms and captions are unchanged - and crossfade with the video; the music plays under them. Omitted fields keep their current values.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "card": AgentSchema.choice(["intro", "outro"], "Which card."),
                    "type": AgentSchema.choice(["text", "image"], "Text card or image card. Default text for a new card."),
                    "title": AgentSchema.string("Title of a text card. Keep it short."),
                    "subtitle": AgentSchema.string("Smaller line under the title."),
                    "path": AgentSchema.string("Absolute path of the image file, for an image card."),
                    "fit": AgentSchema.choice(["fill", "fit"], "fill covers the frame, cropping; fit shows the whole image on the background. Default fit."),
                    "duration": AgentSchema.number("Seconds on screen, 1–10. Default 3."),
                    "font": AgentSchema.choice(RecordingTitleCard.FontStyle.allCases.map(\.rawValue), "Design of the system font, which covers every script. Default system."),
                    "weight": AgentSchema.choice(RecordingTitleCard.FontWeight.allCases.map(\.rawValue), "Title weight. Default bold."),
                    "title_size": AgentSchema.number("Title size as a multiple of the default, 0.5–2."),
                    "subtitle_size": AgentSchema.number("Subtitle size as a multiple of the default, 0.5–2."),
                    "text_color": AgentSchema.string("#RRGGBB, or \"auto\" for black or white to suit the background. Default auto."),
                    "position": AgentSchema.choice(RecordingImageOverlayAnchor.allCases.map(\.rawValue), "Where the text block sits; left and right positions align the text to that side. Default center."),
                    "text_shadow": AgentSchema.boolean("Soft shadow behind the text, for photo backgrounds."),
                    "background": AgentSchema.string("#RRGGBB for a plain color, or \"project\" for the project's background. Default project."),
                    "layout": AgentSchema.choice(
                        ["centered", "lower-third", "hero", "editorial"],
                        "A ready-made arrangement, applied before the other fields so they can adjust it: centered; lower-third (bottom left, bar, panel); hero (large heavy title at the left, line); editorial (serif, top left, line)."
                    ),
                    "accent": AgentSchema.choice(RecordingTitleCard.Accent.allCases.map(\.rawValue), "A rule in the text color: a line between title and subtitle, or a bar beside the text."),
                    "text_panel": AgentSchema.boolean("A translucent panel behind the text."),
                    "animate": AgentSchema.boolean("Ease the parts in - background push-in, title and subtitle rising in turn. Default true."),
                ], required: ["recording", "card"]),
                isReadOnly: false
            )
        case .removeCard:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Remove intro or outro card",
                description: "Removes the intro or outro card.",
                inputSchema: AgentSchema.object([
                    "recording": AgentSchema.recording,
                    "card": AgentSchema.choice(["intro", "outro"], "Which card."),
                ], required: ["recording", "card"]),
                isReadOnly: false,
                isDestructive: true
            )
        case .export:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Export video",
                description: "Renders the edited video with the project's export settings and saves it to the user's export folder, as Studio's Export button does. Can take minutes; reports progress. Returns the file path.",
                inputSchema: AgentSchema.object(["recording": AgentSchema.recording], required: ["recording"]),
                isReadOnly: false
            )
        case .openInStudio:
            MCPToolDefinition(
                name: tool.rawValue,
                title: "Open in Studio",
                description: "Opens the recording in a Studio window so the user can watch and adjust the edits.",
                inputSchema: AgentSchema.object(["recording": AgentSchema.recording], required: ["recording"]),
                isReadOnly: false
            )
        }
    }
}

/// JSON Schema fragments for the tool inputs.
nonisolated enum AgentSchema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static func choice(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
    }

    static let recording = string("Recording id from list_recordings (its package path), its name, or \"latest\".")

    static let timeline = choice(
        ["edited", "source"],
        "Which timeline the times are on: edited (after cuts and speed changes; the default) or source (the original recording)."
    )

    /// A preset name or a normalized center.
    static let overlayPosition: JSONValue = [
        "description": "Where the image sits: a preset (top-left, top, top-right, left, center, right, bottom-left, bottom, bottom-right) - kept a margin from the edge and clear of the captions, and kept in place when the size, aspect ratio or captions change - or {x, y} for its center, normalized 0–1 with a top-left origin. Prefer presets. Default center.",
        "oneOf": [
            ["type": "string", "enum": .array(RecordingImageOverlayAnchor.allCases.map { .string($0.rawValue) })],
            point,
        ],
    ]

    static let point: JSONValue = [
        "type": "object",
        "description": "Point to hold the zoom on, normalized to the screen recording: x and y from 0 to 1, top-left origin.",
        "properties": ["x": ["type": "number"], "y": ["type": "number"]],
        "required": ["x", "y"],
        "additionalProperties": false,
    ]

    static func ranges(_ description: String) -> JSONValue {
        [
            "type": "array",
            "minItems": 1,
            "description": .string(description),
            "items": object([
                "start": number("Start, seconds."),
                "end": number("End, seconds."),
            ], required: ["start", "end"]),
        ]
    }
}

/// Hands each call to the main actor, where the Studio models live.
nonisolated struct AgentToolProvider: MCPToolProvider {
    let tools = AgentToolCatalog.tools

    func callTool(
        _ name: String,
        arguments: [String: JSONValue],
        context: MCPRequestContext
    ) async throws -> MCPToolResult {
        guard let tool = AgentTool(rawValue: name) else { throw MCPToolError.unknownTool(name) }
        return try await AgentEditingTools.call(tool, arguments: MCPArguments(arguments), context: context)
    }
}
