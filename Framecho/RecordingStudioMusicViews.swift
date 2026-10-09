//
//  RecordingStudioMusicViews.swift
//  Framecho
//
//  Background music in the studio: the Audio page's section for the
//  chosen track and its level, and the library sheet tracks are picked
//  from - previewed by streaming, downloaded only once one is used.
//

import SwiftUI

struct StudioBackgroundMusicControls: View {
    @Bindable var model: RecordingStudioModel
    @State private var isLibraryPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if let music = model.backgroundMusic {
                chosenTrack(music)

                InspectorSlider(
                    "Music Level",
                    value: Binding(
                        get: { CGFloat(model.backgroundMusicVolume) },
                        set: { model.backgroundMusicVolume = Double($0) }
                    ),
                    range: 0...1,
                    format: .percent()
                )

                if let duckedLevel {
                    InspectorHint(duckedLevel)
                }

                InspectorToggleRow(
                    "Loop to fill the video",
                    isOn: Binding(
                        get: { model.backgroundMusicLoops },
                        set: { model.backgroundMusicLoops = $0 }
                    )
                )

                if let summary = lengthSummary {
                    InspectorHint(summary)
                }

                InspectorToggleRow(
                    "Lower under narration",
                    isOn: Binding(
                        get: { model.backgroundMusicDucksUnderSpeech },
                        set: { model.backgroundMusicDucksUnderSpeech = $0 }
                    )
                )
                .disabled(!model.canDuckBackgroundMusic)

                if !model.canDuckBackgroundMusic {
                    InspectorHint("Transcribe the narration to lower the music while you speak.")
                }
            } else {
                InspectorActionButton("Choose Music…", systemImage: "music.note") {
                    isLibraryPresented = true
                }
                .help("Lay a track from the music library under the video")
            }
        }
        .sheet(isPresented: $isLibraryPresented) {
            BackgroundMusicLibraryView(model: model)
        }
    }

    /// How the track covers the video: looping and how often, or where it
    /// runs out when it plays once.
    private var lengthSummary: String? {
        guard let music = model.loadedBackgroundMusic,
              let plan = model.backgroundMusicTimelinePlan,
              music.duration < model.duration else {
            return nil
        }
        let length = Self.durationText(music.duration)
        let passes = plan.passes.count
        if passes > 1 {
            return String(localized: "\(length) track, loops \(passes) times (crossfaded)")
        }
        return String(localized: "\(length) track, ends before the video does")
    }

    /// The level is the music's base; ducking dips below it while the
    /// narration speaks. Saying where it dips to keeps the slider from
    /// reading as a live meter.
    private var duckedLevel: String? {
        guard model.backgroundMusicDucksUnderSpeech, model.canDuckBackgroundMusic else { return nil }
        let level = (model.backgroundMusicVolume * BackgroundMusicGainPlan.duckRatio)
            .formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Drops to \(level) while you speak")
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func chosenTrack(_ music: RecordingBackgroundMusic) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(music.track?.title ?? music.trackID)
                    .font(.inspectorValue)
                    .lineLimit(1)
                if model.isLoadingBackgroundMusic {
                    InspectorHint("Downloading…")
                } else if let error = model.backgroundMusicError {
                    InspectorHint(error, tint: .orange)
                } else if let track = music.track {
                    InspectorHint(track.mood.title)
                }
            }

            Spacer(minLength: 0)

            if model.isLoadingBackgroundMusic {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Change…") {
                isLibraryPresented = true
            }
            .buttonStyle(.link)
            .font(.inspectorLabel)

            InspectorClearButton(help: "Remove the music") {
                model.removeBackgroundMusic()
            }
        }
    }
}

/// The music library: tracks by mood, each with a streamed preview. Using
/// one downloads it once into the shared cache.
struct BackgroundMusicLibraryView: View {
    @Bindable var model: RecordingStudioModel
    @State private var store = BackgroundMusicStore.shared
    @State private var mood: BackgroundMusicTrack.Mood?
    @Environment(\.dismiss) private var dismiss

    private var tracks: [BackgroundMusicTrack] {
        BackgroundMusicCatalog.tracks.filter { mood == nil || $0.mood == mood }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            List {
                ForEach(tracks) { track in
                    row(for: track)
                }
            }
            .listStyle(.inset)

            Divider()

            footer
        }
        .frame(width: 460, height: 540)
        .onDisappear {
            store.stopPreview()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Music Library")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("Mood", selection: $mood) {
                Text("All").tag(BackgroundMusicTrack.Mood?.none)
                ForEach(BackgroundMusicTrack.Mood.allCases) { mood in
                    Text(mood.title).tag(Optional(mood))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
    }

    private func row(for track: BackgroundMusicTrack) -> some View {
        let isPreviewing = store.previewingTrackID == track.id
        let isChosen = model.backgroundMusic?.trackID == track.id
        return HStack(spacing: 10) {
            Button {
                store.togglePreview(track)
            } label: {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isPreviewing ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isPreviewing ? "Stop Preview" : "Preview")
            .accessibilityLabel(isPreviewing ? "Stop Preview" : "Preview")

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle(for: track))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(Self.durationText(track.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            if store.downloading.contains(track.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 56)
            } else if isChosen {
                Label("In Use", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56)
                    .help("This project uses this track")
                    .accessibilityLabel("In Use")
            } else {
                Button("Use") {
                    store.stopPreview()
                    model.chooseBackgroundMusic(track)
                    dismiss()
                }
                .controlSize(.small)
                .frame(width: 56)
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(for track: BackgroundMusicTrack) -> String {
        var parts = [track.mood.title]
        if let artist = track.artist {
            parts.append(artist)
        }
        if !store.isCached(track) {
            parts.append(String(localized: "Downloads on first use"))
        }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            Text("Check each track's license before you publish.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
