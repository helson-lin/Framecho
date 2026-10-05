import AppKit
import SwiftUI

struct VideoSettingsPane: View {
    @AppStorage(ScreendropPreferences.revealExportInFinderKey) private var revealExportInFinder = true

    var body: some View {
        Form {
            AfterCaptureActionsSection(type: .recording, title: "After Recording")

            Section("After Export") {
                Toggle(isOn: $revealExportInFinder) {
                    SettingsControlLabel(
                        "Reveal in Finder",
                        detail: "Select the exported file in Finder once the render finishes."
                    )
                }
            }

            Section("Projects") {
                LabeledContent {
                    Button("Open Recordings Library…") {
                        CaptureLibraryModel.shared.show(filter: .recordings)
                    }
                } label: {
                    SettingsControlLabel(
                        "Recording projects",
                        detail: "Reopen a past recording with every edit intact."
                    )
                }
            }
        }
        .settingsFormStyle()
    }
}

struct OverlaySettingsPane: View {
    @AppStorage(ScreendropPreferences.previewPositionKey) private var previewPositionRaw = PreviewOverlayPosition.right.rawValue
    @AppStorage(ScreendropPreferences.previewSizeKey) private var previewSizeRaw = PreviewOverlaySize.defaultSize.rawValue
    @AppStorage(ScreendropPreferences.previewAutoCloseSecondsKey) private var autoCloseSeconds = 0
    @AppStorage(ScreendropPreferences.previewCloseAfterDraggingKey) private var closeAfterDragging = true

    private let autoCloseOptions: [Int] = [0, 5, 10, 30, 60]

    private var previewSize: PreviewOverlaySize {
        PreviewOverlaySize(rawValue: previewSizeRaw) ?? .defaultSize
    }

    /// Bridges the stored raw value to the slider's discrete steps.
    private var previewSizeStep: Binding<Double> {
        let sizes = PreviewOverlaySize.allCases
        return Binding(
            get: { Double(sizes.firstIndex(of: previewSize) ?? 0) },
            set: { previewSizeRaw = sizes[Int($0.rounded())].rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Preview Overlay") {
                Picker(selection: $previewPositionRaw) {
                    ForEach(PreviewOverlayPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    SettingsControlLabel(
                        "Position on screen",
                        detail: "Where the floating preview cards appear after a capture."
                    )
                }

                LabeledContent {
                    HStack(spacing: 12) {
                        Slider(
                            value: previewSizeStep,
                            in: 0...Double(PreviewOverlaySize.allCases.count - 1),
                            step: 1
                        ) {
                            Text("Preview size")
                        } minimumValueLabel: {
                            Image(systemName: "rectangle.inset.filled")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        } maximumValueLabel: {
                            Image(systemName: "rectangle.inset.filled")
                                .imageScale(.large)
                                .accessibilityHidden(true)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityValue(Double(previewSize.cardScale).formatted(.percent))

                        Text(Double(previewSize.cardScale), format: .percent)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    SettingsControlLabel(
                        "Preview size",
                        detail: "How large the floating preview cards appear."
                    )
                }

                Picker(selection: $autoCloseSeconds) {
                    ForEach(autoCloseOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    SettingsControlLabel(
                        "Auto-close",
                        detail: "Automatically dismiss a preview after this delay, unless you're using it."
                    )
                }

                Toggle(isOn: $closeAfterDragging) {
                    SettingsControlLabel(
                        "Close after dragging",
                        detail: "Dismiss the preview once you drag it out to another app."
                    )
                }
            }

            Section("Card Actions") {
                OverlayCardEditor()
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .settingsFormStyle()
    }
}
