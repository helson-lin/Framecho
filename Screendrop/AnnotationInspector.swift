//
//  AnnotationInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

// MARK: - Inspector

enum AnnotationEditorFocusedField: Hashable {
    case watermarkText
}

/// The inspector splits by scope: what you draw and select, and the canvas the
/// screenshot is presented on.
private enum AnnotationInspectorTab: Hashable, CaseIterable {
    case annotate
    case canvas

    var title: String {
        switch self {
        case .annotate: String(localized: "Annotate")
        case .canvas: String(localized: "Canvas")
        }
    }
}

private enum AnnotationInspectorEffectSection: String, Hashable, CaseIterable {
    case camera
    case progressiveBlur
    case watermark
}

private enum AnnotationInspectorSectionState {
    static let expandedSectionsKey = "annotationInspector.expandedAdvancedSections"

    static func loadExpandedSections() -> Set<AnnotationInspectorEffectSection> {
        let rawValues = UserDefaults.standard.stringArray(forKey: expandedSectionsKey) ?? []
        return Set(rawValues.compactMap(AnnotationInspectorEffectSection.init(rawValue:)))
    }

    static func saveExpandedSections(_ sections: Set<AnnotationInspectorEffectSection>) {
        UserDefaults.standard.set(sections.map(\.rawValue), forKey: expandedSectionsKey)
    }
}

struct AnnotationEditorInspector: View {
    @Bindable var model: AnnotationEditorModel
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    @Bindable var backgroundPresetStore: AnnotationBackgroundPresetStore
    let focusedField: FocusState<AnnotationEditorFocusedField?>.Binding
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var selectedTab: AnnotationInspectorTab = .annotate
    @State private var expandedEffectSections: Set<AnnotationInspectorEffectSection> = AnnotationInspectorSectionState.loadExpandedSections()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                switch selectedTab {
                case .annotate:
                    annotateTab
                case .canvas:
                    canvasTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Reserve clearance so the final inspector controls are never
            // hidden behind the floating preview peek pill.
            .padding(.bottom, PreviewPeekTab.pillHeight * 1.1)
        }
        // Each tab starts at its top instead of inheriting the other's offset.
        .id(selectedTab)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                tabPicker

                if selectedTab == .canvas {
                    AnnotationBackgroundPresetBar(
                        model: model,
                        presetStore: backgroundPresetStore,
                        onEditorAction: onEditorAction
                    )
                }

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 0.5)
            }
            .background(sidebarBackground)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .background(sidebarBackground)
        // Drawing or selecting on the canvas always lands on the controls for it.
        .onChange(of: model.selectedTool) { _, _ in
            selectedTab = .annotate
        }
        .onChange(of: model.selectionCount) { _, count in
            if count > 0 {
                selectedTab = .annotate
            }
        }
        .inspectorColumnWidth(
            min: InspectorMetrics.columnMinWidth,
            ideal: InspectorMetrics.columnIdealWidth,
            max: InspectorMetrics.columnMaxWidth
        )
        .frame(
            minWidth: InspectorMetrics.columnMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var tabPicker: some View {
        InspectorSegmented(
            options: AnnotationInspectorTab.allCases,
            isSelected: { $0 == selectedTab },
            onTap: { tab in
                onEditorAction()
                selectedTab = tab
            },
            label: { tab in
                Text(tab.title)
                    .font(.inspectorSegment)
                    .lineLimit(1)
            }
        )
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, selectedTab == .canvas ? 0 : 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    // MARK: Tabs

    @ViewBuilder
    private var annotateTab: some View {
        // The tools themselves live on the canvas; this says what the style
        // controls below will act on.
        InspectorSection("Current") {
            AnnotationInspectorContextRow(model: model)
        }

        InspectorSectionDivider()

        // Always present so selecting or deselecting annotations never
        // shifts the sections below.
        InspectorSection("Style") {
            styleControls
        }

        InspectorSectionDivider()

        InspectorSection("Auto Redact") {
            smartRedactionControls
        }
    }

    @ViewBuilder
    private var canvasTab: some View {
        InspectorSection(
            title: "Composition",
            accessory: {
                if !compositionIsDefault {
                    InspectorResetButton(help: "Reset composition") {
                        onEditorAction()
                        let defaults = AnnotationBackgroundSettings()
                        model.backgroundSettings.aspectRatio = defaults.aspectRatio
                        model.backgroundSettings.padding = defaults.padding
                        model.backgroundSettings.alignment = defaults.alignment
                    }
                }
            }
        ) {
            AnnotationCompositionInspector(
                settings: backgroundSettings,
                onEditorAction: onEditorAction
            )
        }

        InspectorSectionDivider()

        InspectorSection(
            title: "Background",
            accessory: {
                if model.backgroundSettings.style != .none {
                    InspectorClearButton(help: "Remove background") {
                        onEditorAction()
                        model.backgroundSettings.style = .none
                    }
                }
            }
        ) {
            InspectorBackgroundFillPicker(
                style: backgroundSettings.style,
                rememberedWallpaper: model.backgroundSettings.customWallpaper,
                wallpaperStore: wallpaperStore,
                onEditorAction: onEditorAction,
                onPickWallpaper: onPickWallpaper,
                onSelectWallpaper: { model.backgroundSettings.customWallpaper = $0 }
            )
        }

        InspectorSectionDivider()

        InspectorSection(
            title: "Screenshot",
            accessory: {
                if !screenshotAppearanceIsDefault {
                    InspectorResetButton(help: "Reset screenshot appearance") {
                        onEditorAction()
                        let defaults = AnnotationBackgroundSettings()
                        model.backgroundSettings.cornerRadius = defaults.cornerRadius
                        model.backgroundSettings.shadow = defaults.shadow
                        model.backgroundSettings.shadowStyle = defaults.shadowStyle
                        model.backgroundSettings.border = defaults.border
                    }
                }
            }
        ) {
            AnnotationScreenshotAppearanceInspector(
                settings: backgroundSettings,
                onEditorAction: onEditorAction
            )
        }

        InspectorSectionDivider()

        effectSections
    }

    @ViewBuilder
    private var effectSections: some View {
        InspectorDisclosureSection(
            title: "3D Perspective",
            summary: AnnotationInspectorSummary.camera(model.backgroundSettings.camera),
            isExpanded: expansionBinding(for: .camera),
            accessory: {
                if !model.backgroundSettings.camera.isDefault {
                    InspectorResetButton(help: "Reset 3D perspective") {
                        onEditorAction()
                        withAnimation(sectionAnimation) {
                            model.backgroundSettings.camera = AnnotationCameraSettings()
                        }
                    }
                }
            }
        ) {
            AnnotationCameraInspector(
                settings: Binding(
                    get: { model.backgroundSettings.camera },
                    set: { model.backgroundSettings.camera = $0 }
                ),
                onEditorAction: onEditorAction
            )
        }

        InspectorDisclosureSection(
            title: "Progressive Blur",
            summary: AnnotationInspectorSummary.progressiveBlur(model.backgroundSettings.progressiveBlur),
            isExpanded: expansionBinding(for: .progressiveBlur),
            accessory: {
                HStack(spacing: 5) {
                    if model.backgroundSettings.progressiveBlur != AnnotationProgressiveBlurSettings() {
                        sectionResetButton("Reset progressive blur", section: .progressiveBlur) {
                            model.backgroundSettings.progressiveBlur = AnnotationProgressiveBlurSettings()
                        }
                    }

                    sectionToggle(
                        "Enable progressive blur",
                        isOn: \.progressiveBlur.isEnabled,
                        section: .progressiveBlur
                    )
                }
            }
        ) {
            AnnotationProgressiveBlurInspector(
                settings: Binding(
                    get: { model.backgroundSettings.progressiveBlur },
                    set: { model.backgroundSettings.progressiveBlur = $0 }
                ),
                onEditorAction: onEditorAction
            )
            .disabled(!model.backgroundSettings.progressiveBlur.isEnabled)
            .opacity(model.backgroundSettings.progressiveBlur.isEnabled ? 1 : 0.48)
        }

        InspectorDisclosureSection(
            title: "Watermark",
            summary: AnnotationInspectorSummary.watermark(model.backgroundSettings.watermark),
            isExpanded: expansionBinding(for: .watermark),
            accessory: {
                HStack(spacing: 5) {
                    if model.backgroundSettings.watermark != AnnotationWatermarkSettings() {
                        sectionResetButton("Reset watermark", section: .watermark) {
                            model.backgroundSettings.watermark = AnnotationWatermarkSettings()
                        }
                    }

                    sectionToggle("Enable watermark", isOn: \.watermark.isEnabled, section: .watermark)
                }
            }
        ) {
            AnnotationWatermarkInspector(
                settings: Binding(
                    get: { model.backgroundSettings.watermark },
                    set: { model.backgroundSettings.watermark = $0 }
                ),
                focusedField: focusedField,
                onFocusCleared: onEditorAction
            )
        }
    }

    // MARK: Canvas helpers

    private var backgroundSettings: Binding<AnnotationBackgroundSettings> {
        Binding(
            get: { model.backgroundSettings },
            set: { model.backgroundSettings = $0 }
        )
    }

    private var compositionIsDefault: Bool {
        let settings = model.backgroundSettings
        let defaults = AnnotationBackgroundSettings()
        return settings.aspectRatio == defaults.aspectRatio
            && settings.padding == defaults.padding
            && settings.alignment == defaults.alignment
    }

    private var screenshotAppearanceIsDefault: Bool {
        let settings = model.backgroundSettings
        let defaults = AnnotationBackgroundSettings()
        return settings.cornerRadius == defaults.cornerRadius
            && settings.shadow == defaults.shadow
            && settings.shadowStyle == defaults.shadowStyle
            && settings.border == defaults.border
    }

    private var sidebarBackground: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }

    private var sectionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .snappy(duration: 0.18)
    }

    private func expansionBinding(
        for section: AnnotationInspectorEffectSection
    ) -> Binding<Bool> {
        Binding(
            get: { expandedEffectSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedEffectSections.insert(section)
                } else {
                    expandedEffectSections.remove(section)
                }
                AnnotationInspectorSectionState.saveExpandedSections(expandedEffectSections)
            }
        )
    }

    private func setExpanded(_ section: AnnotationInspectorEffectSection, _ isExpanded: Bool) {
        withAnimation(sectionAnimation) {
            if isExpanded {
                expandedEffectSections.insert(section)
            } else {
                expandedEffectSections.remove(section)
            }
        }
        AnnotationInspectorSectionState.saveExpandedSections(expandedEffectSections)
    }

    /// Header switch for sections with an on/off state. Turning one on opens
    /// its controls; turning it off folds them away.
    private func sectionToggle(
        _ title: LocalizedStringResource,
        isOn keyPath: WritableKeyPath<AnnotationBackgroundSettings, Bool>,
        section: AnnotationInspectorEffectSection
    ) -> some View {
        InspectorToggle(
            title,
            isOn: Binding(
                get: { model.backgroundSettings[keyPath: keyPath] },
                set: { value in
                    onEditorAction()
                    model.backgroundSettings[keyPath: keyPath] = value
                    setExpanded(section, value)
                }
            )
        )
    }

    private func sectionResetButton(
        _ help: String,
        section: AnnotationInspectorEffectSection,
        reset: @escaping () -> Void
    ) -> some View {
        InspectorResetButton(help: help) {
            onEditorAction()
            reset()
            if expandedEffectSections.contains(section) {
                setExpanded(section, false)
            }
        }
    }

    // MARK: Tools & style

    private var smartRedactionControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Text("Find sensitive content in the screenshot and cover it.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                InspectorActionButton(
                    "Pixelate",
                    systemImage: "app.background.dotted",
                    isBusy: model.isSmartRedacting
                ) {
                    onEditorAction()
                    model.smartRedact(using: .pixelate)
                }
                .help("Find sensitive content and pixelate it")

                InspectorActionButton(
                    "Blur",
                    systemImage: "drop.fill",
                    isBusy: model.isSmartRedacting
                ) {
                    onEditorAction()
                    model.smartRedact(using: .blur)
                }
                .help("Find sensitive content and blur it")
            }

            if model.isSmartRedacting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning screenshot…")
                        .font(.inspectorLabel)
                        .foregroundStyle(.secondary)
                }
            } else if let message = model.smartRedactionMessage {
                Text(message)
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var styleControls: some View {
        if !model.hasInspectorStyleControls {
            Text("Choose a drawing tool or select an annotation to change its style.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if model.isTextStyleAvailable {
                AnnotationTextStyleControls(model: model)
            } else {
                if model.isColorStyleAvailable {
                    InspectorRow("Color") {
                        AnnotationSwatchStrip(selectedSwatch: model.selectedSwatch) { swatch in
                            onEditorAction()
                            model.setSwatch(swatch)
                        }
                    }
                }

                if model.isStrokeStyleAvailable {
                    InspectorRow("Stroke") {
                        AnnotationStrokePicker(strokeWidth: model.strokeWidth) { strokeWidth in
                            onEditorAction()
                            model.setStrokeWidth(strokeWidth)
                        }
                    }
                }

                if model.isRedactionStyleAvailable {
                    InspectorSlider(
                        "Strength",
                        value: Binding(
                            get: { model.redactionDensity },
                            set: {
                                onEditorAction()
                                model.setRedactionDensity($0)
                            }
                        ),
                        range: 0.15...1,
                        format: .percent()
                    )
                }
            }
        }
    }
}

// MARK: - Section summaries

/// One-line readouts for collapsed section headers. `nil` means the section
/// has nothing active worth announcing.
private enum AnnotationInspectorSummary {
    static func camera(_ settings: AnnotationCameraSettings) -> String? {
        guard !settings.isDefault else { return nil }
        var parts: [String] = []
        let angles = [
            settings.tiltXDegrees, settings.tiltYDegrees, settings.rollDegrees,
            settings.rotationXDegrees, settings.rotationYDegrees
        ]
        if angles.contains(where: { abs($0) > 0.0001 }) {
            parts.append(String(localized: "Angled"))
        }
        if abs(settings.zoom - 1) > 0.0001 {
            parts.append(InspectorValueFormat.magnification(fractionDigits: 2).displayString(for: settings.zoom))
        }
        if abs(settings.panX) > 0.0001 || abs(settings.panY) > 0.0001 {
            parts.append(String(localized: "Panned"))
        }
        if parts.isEmpty {
            parts.append(String(localized: "FOV \(InspectorValueFormat.degrees().displayString(for: settings.fieldOfViewDegrees))"))
        }
        return parts.joined(separator: " · ")
    }

    static func progressiveBlur(_ settings: AnnotationProgressiveBlurSettings) -> String? {
        guard settings.isEnabled else { return nil }
        return "\(settings.mode.title) · \(Int(settings.strength.rounded()))"
    }

    static func watermark(_ settings: AnnotationWatermarkSettings) -> String? {
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isEnabled, !text.isEmpty else { return nil }
        return "“\(text)”"
    }
}

// MARK: - Tools

/// What the style controls act on: the active tool, or the current selection.
private struct AnnotationInspectorContextRow: View {
    @Bindable var model: AnnotationEditorModel

    var body: some View {
        // The engine isn't observable; reading `revision` refreshes the row
        // when the selection changes.
        let _ = model.revision
        HStack(spacing: 8) {
            Image(systemName: model.selectedTool.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(title)
                .font(.inspectorLabel)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.inspectorLabel)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let count = model.selectionCount
        if count > 1 { return String(localized: "\(count) annotations selected") }
        if count == 1 { return String(localized: "1 annotation selected") }
        return model.selectedTool.title
    }

    private var detail: String {
        model.selectionCount > 0 ? String(localized: "⌫ to delete") : model.selectedTool.shortcut.label
    }
}
