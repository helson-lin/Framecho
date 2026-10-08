//
//  RecordingStudioTranscriptPanel.swift
//  Framecho
//
//  The studio's transcript panel: the narration as editable captions or as
//  words to cut the video by, plus AI caption cleanup and its review. It
//  sits on the leading edge so long reading and typing never compete with
//  the inspector, which keeps only the captions' properties.
//

import AppKit
import SwiftUI

/// What the transcript panel edits: the captions' text, or the video by
/// its words.
enum StudioTranscriptMode: String, CaseIterable, Identifiable {
    case captions
    case cut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captions: String(localized: "Captions")
        case .cut: String(localized: "Cut")
        }
    }
}

/// The leading panel: the whole narration, editable as captions or as
/// words to cut, with AI cleanup and its review. Full window height, so
/// long passages read comfortably beside the video.
struct StudioTranscriptPanel: View {
    static let isPresentedKey = "studioShowsTranscriptPanel"
    static let width: CGFloat = 320
    static let horizontalPadding: CGFloat = 12

    @Bindable var model: RecordingStudioModel

    @AppStorage(isPresentedKey) private var isPresented = false
    @AppStorage("studioTranscriptMode") private var mode = StudioTranscriptMode.captions
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if showsFooter {
                Divider()
                footer
            }
        }
        .frame(width: Self.width)
    }

    private var hasTranscript: Bool {
        guard case .idle = model.transcriptionState else { return false }
        return model.hasSubtitles
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

                if hasTranscript, model.hasTranscriptWords {
                    aiMenu
                }

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Hide Transcript")
                .accessibilityLabel("Hide Transcript")
            }

            if hasTranscript, model.hasTranscriptWords, model.captionCleanupState != .reviewing {
                Picker("Mode", selection: $mode) {
                    ForEach(StudioTranscriptMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if hasTranscript, effectiveMode == .captions, model.captionCleanupState != .reviewing {
                TextField("Search Transcript", text: $searchText, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            cleanupStatus
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 10)
    }

    private var aiMenu: some View {
        Menu {
            Button("Remove Fillers…", systemImage: "sparkles") {
                model.suggestCaptionFillers()
            }
            Button("Proofread…", systemImage: "text.badge.checkmark") {
                model.suggestCaptionCorrections()
            }
            Divider()
            Button("Restore Original", systemImage: "arrow.uturn.backward") {
                model.restoreOriginalCaptions()
            }
            .disabled(!model.hasCaptionRevisions)
            Button("AI Settings…", systemImage: "gearshape") {
                SettingsWindowController.show(tab: .ai)
            }
        } label: {
            Label("AI", systemImage: "sparkles")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(model.captionCleanupState.isRunning || model.captionCleanupState == .reviewing)
        .help("Clean up the captions with AI, then review every change")
    }

    /// Progress and failures of an AI cleanup, under the header so the
    /// transcript stays readable while it runs.
    @ViewBuilder
    private var cleanupStatus: some View {
        switch model.captionCleanupState {
        case .running(let completed, let total):
            HStack(spacing: 8) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .controlSize(.small)
                Group {
                    if model.captionCleanupKind == .fillers {
                        InspectorHint("Finding fillers… \(completed)/\(total)")
                    } else {
                        InspectorHint("Proofreading… \(completed)/\(total)")
                    }
                }
                .monospacedDigit()
                .fixedSize()
                InspectorClearButton(help: "Cancel") {
                    model.discardCaptionCleanup()
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                InspectorHint(message, tint: .orange)
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    InspectorActionButton("Try Again", systemImage: "sparkles") {
                        if model.captionCleanupKind == .fillers {
                            model.suggestCaptionFillers()
                        } else {
                            model.suggestCaptionCorrections()
                        }
                    }
                    InspectorActionButton("AI Settings…", systemImage: "gearshape") {
                        SettingsWindowController.show(tab: .ai)
                    }
                    InspectorClearButton(help: "Dismiss") {
                        model.discardCaptionCleanup()
                    }
                }
            }
        case .idle, .reviewing:
            EmptyView()
        }
    }

    // MARK: Content

    /// Projects transcribed before words were stored can only edit captions.
    private var effectiveMode: StudioTranscriptMode {
        model.hasTranscriptWords ? mode : .captions
    }

    @ViewBuilder
    private var content: some View {
        if !hasTranscript {
            emptyState
        } else if model.captionCleanupState == .reviewing {
            StudioCaptionCleanupReviewPanel(model: model)
        } else {
            switch effectiveMode {
            case .captions:
                captionList
            case .cut:
                cutEditor
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if model.canTranscribe {
                InspectorHint("Transcribe the narration to edit its captions and cut the video by its words.")
                    .multilineTextAlignment(.center)
                StudioTranscriptionStatus(model: model)
                    .fixedSize()
            } else {
                InspectorHint("Captions come from narration. Record with the microphone on to transcribe it.")
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredCues: [RecordingSubtitleCue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.subtitleCues }
        return model.subtitleCues.filter { $0.text.localizedStandardContains(query) }
    }

    private var captionList: some View {
        let cues = filteredCues
        let activeID = model.activeSubtitleCue?.id
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        StudioSubtitleRow(model: model, cue: cue, isActive: activeID == cue.id)
                            .id(cue.id)

                        if index < cues.count - 1 {
                            Divider()
                                .padding(.leading, Self.horizontalPadding)
                                .opacity(0.6)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if cues.isEmpty {
                    InspectorHint("No captions match “\(searchText)”.")
                }
            }
            .onChange(of: activeID) { _, activeID in
                // Follow playback through the list, but never yank the list
                // around while the user is scrubbing or editing.
                guard let activeID, model.isPlaying else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    private var cutEditor: some View {
        VStack(spacing: 0) {
            if model.removableFillerWordCount > 0 || model.trimmableSilenceCount > 0 {
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    if model.removableFillerWordCount > 0 {
                        InspectorActionButton(
                            "Fillers (\(model.removableFillerWordCount))",
                            systemImage: "scissors"
                        ) {
                            model.removeFillerWords()
                        }
                        .help("Cut every filler word, like “um” and “uh”")
                    }

                    if model.trimmableSilenceCount > 0 {
                        InspectorActionButton(
                            "Silences (\(model.trimmableSilenceCount))",
                            systemImage: "waveform.badge.minus"
                        ) {
                            model.trimNarrationSilences()
                        }
                        .help("Trim long pauses in the narration")
                    }
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 8)

                Divider()
            }

            StudioTranscriptEditPanel(model: model)
        }
    }

    // MARK: Footer

    private var showsFooter: Bool {
        hasTranscript && model.captionCleanupState != .reviewing
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if effectiveMode == .cut {
                InspectorHint("Click a word to jump there. Shift-click to select a passage, then cut it.")
            } else {
                InspectorHint("\(model.subtitleCues.count) captions")
                Spacer(minLength: 0)
                if model.hasCaptionRevisions {
                    Button("Restore Original") {
                        model.restoreOriginalCaptions()
                    }
                    .buttonStyle(.link)
                    .font(.inspectorLabel)
                    .help("Show every word as it was transcribed")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 8)
    }
}

/// Transcribing, failed, or not yet transcribed: shared by the transcript
/// panel and the inspector's Captions page.
struct StudioTranscriptionStatus: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        switch model.transcriptionState {
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                InspectorHint("Transcribing narration…")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorHint(message, tint: .orange)

                InspectorActionButton("Try Again", systemImage: "waveform") {
                    model.transcribe()
                }
            }
        case .idle:
            InspectorActionButton("Transcribe Narration", systemImage: "waveform") {
                model.transcribe()
            }
            .help("Turn your microphone narration into subtitles, transcribed on this Mac")
        }
    }
}

/// One editable subtitle line: a timestamp plus the cue text as a free-form
/// field. Hovering a row skims the preview to that cue, clicking or editing
/// commits the playhead there (paused), and the row under the playhead is
/// highlighted so the list follows the video.
private struct StudioSubtitleRow: View {
    @Bindable var model: RecordingStudioModel
    let cue: RecordingSubtitleCue
    let isActive: Bool

    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.seekToSubtitle(cue)
            } label: {
                Text(timestamp ?? "–:––")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(editorTime == nil)
            .help(editorTime == nil ? "This subtitle's audio was cut out" : "Jump to this subtitle")

            TextField(
                "Subtitle",
                text: Binding(
                    get: { cue.text },
                    set: { model.updateSubtitleText(id: cue.id, text: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.inspectorValue)
            .focused($isEditing)
            .onChange(of: isEditing) { _, editing in
                // Starting to edit parks the paused preview on this cue so
                // the correction is visible in context while typing.
                if editing {
                    model.seekToSubtitle(cue)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isActive ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .opacity(editorTime == nil ? 0.5 : 1)
        .onTapGesture {
            model.seekToSubtitle(cue)
        }
        .contextMenu {
            Button("Delete Caption", role: .destructive) {
                model.deleteSubtitle(id: cue.id)
            }
        }
        .onHover { hovering in
            // Hover skims the paused preview like the timeline strip does;
            // leaving hands the frame back to the real playhead.
            guard !model.isPlaying, let editorTime else { return }
            if hovering {
                model.hoverPreviewTime = editorTime
            } else if model.hoverPreviewTime == editorTime {
                model.hoverPreviewTime = nil
            }
        }
    }

    /// Where this cue lands on the edited timeline; nil when its audio was
    /// cut out entirely.
    private var editorTime: TimeInterval? {
        model.editorTime(forSourceTime: cue.start)
            ?? model.editorTime(forSourceTime: (cue.start + cue.end) / 2)
    }

    private var timestamp: String? {
        guard let editorTime else { return nil }
        let total = max(0, Int(editorTime.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Review of cleanup suggestions before they reach the captions: each
/// caption holding a suggestion, its words in reading order. Fillers are
/// struck through; fixes show the heard words struck through beside the
/// correction. Clicking a suggestion keeps or drops it.
private struct StudioCaptionCleanupReviewPanel: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        let total = model.captionCleanupSuggestionCount
        let accepted = model.acceptedCaptionCleanupSuggestionCount
        let isFillers = model.captionCleanupKind == .fillers
        VStack(spacing: 0) {
            if let notice = model.captionCleanupNotice {
                InspectorHint(notice, tint: .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, StudioTranscriptPanel.horizontalPadding)
                    .padding(.vertical, 8)
                Divider()
            }

            if total == 0 {
                VStack(spacing: InspectorMetrics.rowSpacing) {
                    if isFillers {
                        InspectorHint("No fillers found in the captions.")
                    } else {
                        InspectorHint("No misheard words found in the captions.")
                    }
                    InspectorActionButton("Done", systemImage: "checkmark") {
                        model.discardCaptionCleanup()
                    }
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                captionList
                    .frame(maxHeight: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    HStack {
                        if isFillers {
                            InspectorHint("\(total) fillers found")
                        } else {
                            InspectorHint("\(total) fixes suggested")
                        }
                        Spacer(minLength: 0)
                        Button(accepted == total ? "Skip All" : "Accept All") {
                            model.setAllCaptionCleanupSuggestions(accepted: accepted != total)
                        }
                        .buttonStyle(.link)
                        .font(.inspectorLabel)
                    }

                    if isFillers {
                        InspectorHint("Click a word to keep it. Fillers leave the captions only; the video isn't cut.")
                    } else {
                        InspectorHint("Click a fix to skip it. Fixes change the captions only, and Restore Original undoes them.")
                    }

                    HStack(spacing: InspectorMetrics.rowSpacing) {
                        InspectorActionButton("Discard", systemImage: "xmark") {
                            model.discardCaptionCleanup()
                        }

                        InspectorActionButton("Apply (\(accepted))", systemImage: "checkmark") {
                            model.applyCaptionCleanup()
                        }
                        .disabled(accepted == 0)
                    }
                }
                .padding(StudioTranscriptPanel.horizontalPadding)
            }
        }
    }

    private var captionList: some View {
        let captions = model.captionCleanupReviewCaptions
        let fillers = Dictionary(uniqueKeysWithValues: model.fillerSuggestions.map { ($0.wordIndex, $0) })
        let fixes = Dictionary(uniqueKeysWithValues: model.correctionSuggestions.map { ($0.firstWordIndex, $0) })
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(captions.enumerated()), id: \.element.cue.id) { position, caption in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button {
                            model.seekToSubtitle(caption.cue)
                        } label: {
                            Text(timestamp(for: caption.cue) ?? "–:––")
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Jump to this subtitle")

                        TranscriptFlowLayout {
                            ForEach(pieces(of: caption.wordIndices, fixes: fixes), id: \.self) { piece in
                                switch piece {
                                case .word(let index):
                                    StudioFillerReviewWordView(
                                        text: shownText(of: index),
                                        suggestion: fillers[index]
                                    ) {
                                        model.toggleFillerSuggestion(wordIndex: index)
                                    }
                                case .fix(let first):
                                    if let fix = fixes[first] {
                                        StudioCorrectionReviewChip(
                                            original: TranscriptCaptionText.text(
                                                of: fix.wordIndices.map { model.transcriptWords[$0] }
                                            ),
                                            correction: fix
                                        ) {
                                            model.toggleCorrectionSuggestion(id: fix.id)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, StudioTranscriptPanel.horizontalPadding)
                    .padding(.vertical, 8)

                    if position < captions.count - 1 {
                        Divider().padding(.leading, StudioTranscriptPanel.horizontalPadding)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private enum Piece: Hashable {
        case word(Int)
        /// A fix, keyed by its first word; it stands in for its whole span.
        case fix(Int)
    }

    /// A caption's words with each fix's span folded into one piece.
    /// Words hidden from the captions are left out.
    private func pieces(of indices: [Int], fixes: [Int: CaptionCorrectionSuggestion]) -> [Piece] {
        var result: [Piece] = []
        var skipThrough = -1
        for index in indices where index > skipThrough {
            if let fix = fixes[index] {
                result.append(.fix(index))
                skipThrough = fix.lastWordIndex
            } else if !shownText(of: index).isEmpty {
                result.append(.word(index))
            }
        }
        return result
    }

    private func shownText(of index: Int) -> String {
        model.transcriptWords[index].captionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timestamp(for cue: RecordingSubtitleCue) -> String? {
        guard let editorTime = model.editorTime(forSourceTime: cue.start)
            ?? model.editorTime(forSourceTime: (cue.start + cue.end) / 2) else {
            return nil
        }
        let total = max(0, Int(editorTime.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One suggested fix in the review: the heard text struck through, then
/// the correction. A skipped fix reads as the original with the correction
/// dimmed, so it stays findable.
private struct StudioCorrectionReviewChip: View {
    let original: String
    let correction: CaptionCorrectionSuggestion
    let action: () -> Void

    var body: some View {
        let isAccepted = correction.isAccepted
        HStack(spacing: 3) {
            Text(original)
                .foregroundStyle(isAccepted ? Color.secondary : Color.primary)
                .strikethrough(isAccepted, color: .secondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(correction.replacement)
                .foregroundStyle(isAccepted ? Color.primary : Color.secondary)
                .strikethrough(!isAccepted, color: .secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor.opacity(isAccepted ? 0.16 : 0.06))
        )
        .padding(.horizontal, 1.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(isAccepted ? "Click to keep the original" : "Click to use the fix")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(original) to \(correction.replacement)"))
        .accessibilityValue(isAccepted ? String(localized: "Will be fixed") : String(localized: "Skipped"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// One word in the filler review. Suggested fillers are struck through
/// while they will be removed and tinted either way, so a kept suggestion
/// stays findable; other words are plain, untappable context.
private struct StudioFillerReviewWordView: View {
    let text: String
    let suggestion: CaptionFillerSuggestion?
    let action: () -> Void

    var body: some View {
        let isRemoved = suggestion?.isAccepted ?? false
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(isRemoved ? Color.secondary : (suggestion == nil ? Color.secondary : Color.primary))
            .strikethrough(isRemoved, color: .orange)
            .padding(.horizontal, 1.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(suggestion == nil ? Color.clear : Color.orange.opacity(isRemoved ? 0.18 : 0.07))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if suggestion != nil { action() }
            }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityValue(suggestion == nil ? "" : (isRemoved ? String(localized: "Will be removed") : String(localized: "Kept")))
            .accessibilityAddTraits(suggestion == nil ? [] : .isButton)
    }

    private var help: String {
        guard let suggestion else { return "" }
        let source = suggestion.source == .rule
            ? String(localized: "Hesitation sound")
            : String(localized: "Filler in context (AI)")
        return suggestion.isAccepted
            ? String(localized: "\(source) - click to keep")
            : String(localized: "\(source) - click to remove")
    }
}

/// Descript-style transcript editing: the narration as flowing words.
/// Clicking a word jumps the playhead there, shift-clicking selects a
/// passage, and cutting the selection removes that stretch of the video.
/// Words whose footage is already cut render struck-through; filler words
/// carry a dotted underline so the bulk action's targets are visible.
private struct StudioTranscriptEditPanel: View {
    @Bindable var model: RecordingStudioModel

    @State private var selection: ClosedRange<Int>?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    transcriptFlow
                        .padding(StudioTranscriptPanel.horizontalPadding)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: model.activeTranscriptWordIndex) { _, activeIndex in
                    // Follow playback through the transcript, but never yank
                    // it around while the user is selecting a passage.
                    guard let activeIndex, model.isPlaying, selection == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }

            if let selection {
                Divider()
                cutSelectionRow(selection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(StudioTranscriptPanel.horizontalPadding)
            }
        }
        .onDeleteCommand(perform: cutSelection)
        .onExitCommand { selection = nil }
    }

    private var transcriptFlow: some View {
        let activeIndex = model.activeTranscriptWordIndex
        return TranscriptFlowLayout() {
            ForEach(model.transcriptWords.indices, id: \.self) { index in
                StudioTranscriptWordView(
                    text: model.transcriptWords[index].displayText,
                    isSelected: selection?.contains(index) ?? false,
                    isActive: index == activeIndex,
                    isCut: !model.transcriptWordSurvives(index),
                    isFiller: model.isFillerWord(index)
                ) {
                    handleTap(on: index)
                }
                .id(index)
            }
        }
    }

    private func cutSelectionRow(_ selection: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            InspectorActionButton(
                selection.count == 1 ? "Cut Word" : "Cut \(selection.count) Words",
                systemImage: "scissors",
                role: .destructive,
                action: cutSelection
            )

            InspectorClearButton(help: "Clear selection") {
                self.selection = nil
            }
        }
    }

    private func handleTap(on index: Int) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld, let selection {
            self.selection = min(selection.lowerBound, index)...max(selection.upperBound, index)
        } else {
            selection = index...index
            model.seekToTranscriptWord(at: index)
        }
    }

    private func cutSelection() {
        guard let selection else { return }
        model.cutTranscriptWords(in: selection)
        self.selection = nil
    }
}

/// One word in the transcript editor, drawn so the flow reads as a plain
/// paragraph: the chip's side padding doubles as the inter-word space
/// (layout spacing is zero), which also makes a multi-word selection's
/// highlight contiguous like real text selection. The font weight never
/// changes with state - a width change would reflow the whole paragraph
/// on every playback tick. Kept to plain stored values so ticks only
/// re-render the words whose state actually changed.
private struct StudioTranscriptWordView: View {
    let text: String
    let isSelected: Bool
    let isActive: Bool
    let isCut: Bool
    let isFiller: Bool
    let action: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(foreground)
            .strikethrough(isCut, color: .secondary.opacity(0.6))
            .padding(.horizontal, 1.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var foreground: Color {
        isCut ? Color.secondary.opacity(0.45) : Color.primary
    }

    private var background: Color {
        if isSelected {
            Color.accentColor.opacity(isCut ? 0.12 : 0.24)
        } else if isActive, !isCut {
            Color.accentColor.opacity(0.2)
        } else if isFiller, !isCut {
            Color.orange.opacity(0.16)
        } else {
            Color.clear
        }
    }
}

/// Minimal left-aligned wrapping layout for the transcript's word chips.
/// Horizontal spacing lives inside the chips (see StudioTranscriptWordView),
/// so the layout only separates lines.
private struct TranscriptFlowLayout: Layout {
    var spacingX: CGFloat = 0
    var spacingY: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacingY
                rowHeight = 0
            }
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacingY
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
    }
}

