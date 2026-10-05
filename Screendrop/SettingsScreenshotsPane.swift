//
//  SettingsScreenshotsPane.swift
//  Screendrop
//

import SwiftUI

struct ScreenshotsSettingsPane: View {
    @AppStorage(ScreendropPreferences.autoCompressKey) private var autoCompress = false
    @AppStorage(ScreendropPreferences.exportFormatKey) private var exportFormatRawValue = ""
    @AppStorage(ScreendropPreferences.compressionQualityKey) private var compressionQuality = 0.8
    @AppStorage(ScreendropPreferences.captureWindowShadowKey) private var captureWindowShadow = false
    @AppStorage(ScreendropPreferences.captureDelaySecondsKey) private var captureDelaySeconds = 0
    @AppStorage(ScreendropPreferences.timedCaptureDelaySecondsKey) private var timedCaptureDelaySeconds = 5
    @AppStorage(ScreendropPreferences.lowResolutionEditorPreviewKey) private var lowResolutionEditorPreview = true
    @AppStorage(ScreendropPreferences.trimFullscreenMenuBarKey) private var trimFullscreenMenuBar = true

    private let delayOptions: [Int] = [0, 3, 5, 10]
    private let timedCaptureDelayOptions: [Int] = [3, 5, 10]

    private var exportFormat: ScreenshotExportFormat {
        get {
            ScreenshotExportFormat(rawValue: exportFormatRawValue) ?? (autoCompress ? .jpeg : .png)
        }
        nonmutating set {
            exportFormatRawValue = newValue.rawValue
            autoCompress = newValue.usesLossyQuality
        }
    }

    var body: some View {
        Form {
            Section("Capture") {
                Picker(selection: $captureDelaySeconds) {
                    ForEach(delayOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    SettingsControlLabel(
                        "Countdown before every capture",
                        detail: "Every capture mode counts down first, which helps when you need to open a menu."
                    )
                }

                Picker(selection: $timedCaptureDelaySeconds) {
                    ForEach(timedCaptureDelayOptions, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    SettingsControlLabel(
                        "Capture on Timer delay",
                        detail: "Only for Capture on Timer, which captures the screen under the pointer. Other capture modes aren't affected."
                    )
                }

                Toggle(isOn: $captureWindowShadow) {
                    SettingsControlLabel(
                        "Capture window shadow",
                        detail: "Include the window's drop shadow when capturing a window."
                    )
                }

                Toggle(isOn: $trimFullscreenMenuBar) {
                    SettingsControlLabel(
                        "Trim menu bar from fullscreen captures",
                        detail: "On notched Macs, removes the empty black bar at the top of a fullscreen capture. A visible menu bar is kept."
                    )
                }
            }

            Section("Image") {
                Picker("Format", selection: Binding(
                    get: { exportFormat },
                    set: { exportFormat = $0 }
                )) {
                    ForEach(ScreenshotExportFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }

                if exportFormat.usesLossyQuality {
                    LabeledContent {
                        HStack(spacing: 12) {
                            Slider(value: $compressionQuality, in: 0.1...1, step: 0.05)
                                .frame(width: 160)
                                .accessibilityLabel("Compression quality")
                                .accessibilityValue(compressionQuality.formatted(.percent.precision(.fractionLength(0))))

                            Text(compressionQuality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    } label: {
                        SettingsControlLabel(
                            "Compression quality",
                            detail: "Lower values produce smaller files with reduced image quality."
                        )
                    }
                }

                Toggle(isOn: $lowResolutionEditorPreview) {
                    SettingsControlLabel(
                        "Preview at low resolution while editing",
                        detail: "Shows a downscaled image in the annotation editor to reduce memory use. Saved and exported screenshots are always full resolution."
                    )
                }
            }

            AfterCaptureActionsSection(type: .screenshot, title: "After Capture")
        }
        .settingsFormStyle()
    }
}
