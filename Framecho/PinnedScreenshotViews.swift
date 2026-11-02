//
//  PinnedScreenshotViews.swift
//  Framecho
//
//  A pin's image, and the toolbar that sits outside it while it's selected,
//  so nothing covers the picture just because the pointer passed over it.
//

import SwiftUI
import Translation

struct PinnedScreenshotView: View {
    let pin: PinnedScreenshot
    let controller: PinnedScreenshotController

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(shape)
            .overlay {
                // The accent ring marks the pin keys act on.
                let isActive = pin.isSelected || pin.editor != nil || pin.translationMode != nil
                shape
                    .strokeBorder(isActive ? Color.accentColor : .white.opacity(0.25), lineWidth: isActive ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if let feedback = pin.feedback {
                    PinnedFeedbackBadge(feedback: feedback)
                        .transition(.opacity)
                }
            }
            // One session for either kind of translation: annotating a
            // capture swaps its base image, a translating pin shows it.
            .translationTask(pin.translation?.configuration ?? pin.translationMode?.model.configuration) { session in
                if let translation = pin.translation {
                    await translation.run(session)
                    controller.finishTranslation()
                } else if let model = pin.translationMode?.model {
                    await model.run(session)
                }
            }
            .onChange(of: pin.translationMode?.model.phase) {
                controller.translationPhaseChanged()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let mode = pin.translationMode {
            PinnedTranslationImage(model: mode.model, isPeekingOriginal: pin.isPeekingOriginal)
        } else if let editor = pin.editor, let image = editor.previewImage {
            // Zooming resizes the pin, as it does outside annotating, so the
            // image always fills it.
            AnnotationCanvas(
                model: editor, image: image, onEditorInteraction: {}, fitInsets: .zero, leavesZoomToWindow: true
            )
                .background(AnnotationKeyCommandHandler(
                    isEnabled: { !editor.isCommitting },
                    onDelete: editor.deleteSelectedAnnotation,
                    onSave: controller.finishAnnotating,
                    onSaveAs: controller.save,
                    onCopy: controller.copyAnnotatedImage,
                    onUndo: editor.undo,
                    onRedo: editor.redo,
                    onSelectAll: editor.selectAllAnnotations,
                    onSelectTool: editor.selectTool,
                    onZoomIn: { controller.zoom(by: PinnedScreenshotController.zoomStep) },
                    onZoomOut: { controller.zoom(by: 1 / PinnedScreenshotController.zoomStep) },
                    onFitCanvas: editor.fitCanvas,
                    onActualSize: controller.zoomToActualSize,
                    // A pin has no crop: it would change the pin's shape.
                    onToggleCrop: {},
                    onApplyCrop: {},
                    onCancelCrop: {},
                    isCropping: { false }
                ))
        } else {
            LiveTextImageView(
                image: pin.image,
                url: pin.url,
                cornerRadius: 10,
                isLiveTextActive: pin.isLiveTextActive,
                menuEntries: controller.menuEntries,
                onAnalysisFinished: { pin.hasText = $0 }
            )
            .id(pin.imageRevision)
        }
    }
}

// MARK: - Toolbar

struct PinnedScreenshotToolbar: View {
    let pin: PinnedScreenshot
    let controller: PinnedScreenshotController

    var body: some View {
        Group {
            if let mode = pin.translationMode {
                PinnedTranslationBar(mode: mode, controller: controller)
            } else if let editor = pin.editor, pin.isEditingCapture {
                PinnedCaptureBar(editor: editor, controller: controller)
            } else if let editor = pin.editor {
                PinnedAnnotationBar(editor: editor, controller: controller)
            } else {
                viewingBar
            }
        }
        .fixedSize()
        // Framecho stays in the background while a pin is used, and AppKit
        // dims controls in inactive windows; the toolbar is always live.
        .environment(\.controlActiveState, .key)
    }

    private var viewingBar: some View {
        HStack(spacing: 2) {
            PinnedToolbarButton(
                title: "Annotate",
                systemImage: "pencil.tip.crop.circle",
                help: "Annotate (E)",
                action: { controller.beginAnnotating() }
            )
            if pin.hasText {
                PinnedToolbarButton(
                    title: "Live Text",
                    systemImage: "text.viewfinder",
                    help: pin.isLiveTextActive ? "Stop selecting text (Esc)" : "Select text in the image",
                    isActive: pin.isLiveTextActive,
                    action: controller.toggleLiveText
                )
            }
            PinnedToolbarButton(
                title: "Open in Editor",
                systemImage: "square.and.pencil",
                help: "Open in Editor",
                action: controller.openInEditor
            )

            PinnedOpacityMenu(opacity: pin.opacity, onSelect: controller.setOpacity)

            PinnedToolbarDivider()

            PinnedToolbarButton(
                title: "Copy",
                systemImage: pin.didCopy ? "checkmark" : "doc.on.doc",
                help: "Copy (⌘C)",
                action: controller.copyImage
            )
            PinnedToolbarButton(
                title: "Save…",
                systemImage: "square.and.arrow.down",
                help: "Save… (⌘S)",
                action: controller.save
            )

            PinnedToolbarDivider()

            PinnedToolbarButton(
                title: "Close Pin",
                systemImage: "xmark",
                help: "Close Pin (Esc)",
                action: controller.close
            )
        }
        .padding(4)
        .glassSurface(in: .rect(cornerRadius: 14))
    }
}

/// Picks one of a few fixed opacities; scrolling or [ and ] fine-tune it.
private struct PinnedOpacityMenu: View {
    let opacity: CGFloat
    let onSelect: (CGFloat) -> Void

    private static let levels = [100, 80, 60, 40, 20]

    var body: some View {
        Menu {
            ForEach(Self.levels, id: \.self) { level in
                Toggle(isOn: Binding(
                    get: { Int((opacity * 100).rounded()) == level },
                    set: { _ in onSelect(CGFloat(level) / 100) }
                )) {
                    Text("\(level)%")
                }
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Opacity: scroll over the pin, or press [ and ]")
        .accessibilityLabel("Opacity")
        .accessibilityValue(Text("\(Int((opacity * 100).rounded()))%"))
    }
}

private struct PinnedFeedbackBadge: View {
    let feedback: PinnedScreenshotFeedback

    var body: some View {
        Label {
            switch feedback {
            case .zoom(let percent): Text("\(percent)%")
            case .opacity(let percent): Text("\(percent)%")
            case .recognizing: Text("Recognizing text…")
            case .translating: Text("Translating…")
            case .note(let note): Text(note)
            case .message(let message): Text(message)
            }
        } icon: {
            switch feedback {
            case .zoom: Image(systemName: "plus.magnifyingglass")
            case .opacity: Image(systemName: "circle.lefthalf.filled")
            case .recognizing, .translating: ProgressView().controlSize(.small)
            case .note: Image(systemName: "checkmark.circle")
            case .message: Image(systemName: "exclamationmark.circle")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassSurface(in: .capsule)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        switch feedback {
        case .zoom(let percent): Text("Zoom \(percent)%")
        case .opacity(let percent): Text("Opacity \(percent)%")
        case .recognizing: Text("Recognizing text…")
        case .translating: Text("Translating…")
        case .note(let note): Text(note)
        case .message(let message): Text(message)
        }
    }
}

// MARK: - Translating

/// The original under the translation, so the translation fades in over
/// it and the toggle and a Space peek just reveal what's beneath.
private struct PinnedTranslationImage: View {
    let model: ScreenshotTranslation
    let isPeekingOriginal: Bool

    var body: some View {
        ZStack {
            Image(nsImage: model.originalImage)
                .resizable()
                .interpolation(.high)
            if let translated = model.translatedImage {
                Image(nsImage: translated)
                    .resizable()
                    .interpolation(.high)
                    .opacity(model.showsOriginal || isPeekingOriginal ? 0 : 1)
                    .transition(.opacity)
            }
        }
        .animation(PinnedScreenshotController.translationFade, value: model.translatedImage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.showsOriginal || isPeekingOriginal ? Text("Original Text") : Text("Translation"))
    }
}

/// Translation, language, what to take away, and the ways out, in the
/// order and sizes of the capture toolbar, so the two read as one tool.
private struct PinnedTranslationBar: View {
    let mode: PinnedTranslationMode
    let controller: PinnedScreenshotController

    private var model: ScreenshotTranslation { mode.model }

    var body: some View {
        HStack(spacing: 2) {
            PinnedTranslationToggle(
                showsOriginal: model.showsOriginal,
                onSelect: controller.setShowsOriginal
            )
            .disabled(model.phase != .translated)
            .help("Translation or original. Hold Space to glance at the original.")

            PinnedToolbarDivider()

            PinnedLanguageMenu(
                target: model.target,
                targets: model.targets,
                onSelect: controller.translate(to:)
            )
            .disabled(model.phase == .recognizing)

            PinnedToolbarDivider()

            PinnedToolbarButton(
                title: "Copy Text",
                systemImage: "text.quote",
                help: "Copy Translated Text (⇧⌘C)",
                action: controller.copyTranslatedText
            )
            .disabled(model.phase != .translated)
            PinnedToolbarButton(
                title: "Save…",
                systemImage: "square.and.arrow.down",
                help: "Save… (⌘S)",
                action: controller.saveTranslation
            )

            PinnedToolbarDivider()

            if mode.isStandalone {
                PinnedToolbarButton(
                    title: "Keep Pinned",
                    systemImage: "pin",
                    help: "Keep Pinned",
                    action: controller.keepTranslation
                )
                PinnedToolbarButton(
                    title: "Cancel",
                    systemImage: "xmark",
                    help: "Close without copying (Esc)",
                    tint: .red,
                    action: controller.discardTranslation
                )
                PinnedToolbarButton(
                    title: "Copy and Close",
                    systemImage: "checkmark",
                    help: "Copy and close (Return)",
                    tint: .green,
                    action: controller.copyTranslationAndClose
                )
            } else {
                PinnedToolbarButton(
                    title: "Show Original",
                    systemImage: "xmark",
                    help: "Back to the original (Esc)",
                    tint: .red,
                    action: controller.discardTranslation
                )
                PinnedToolbarButton(
                    title: "Keep Translation",
                    systemImage: "pin",
                    help: "Pin the translation in place of the original (Return)",
                    action: controller.keepTranslation
                )
            }
        }
        .padding(4)
        .glassSurface(in: .rect(cornerRadius: 14))
    }
}

/// Drawn by hand like the toolbar's buttons: a system segmented control
/// draws as disabled in the toolbar's window, which never becomes key.
private struct PinnedTranslationToggle: View {
    let showsOriginal: Bool
    let onSelect: (Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            PinnedSegment(title: "Translation", isSelected: !showsOriginal) { onSelect(false) }
            PinnedSegment(title: "Original Text", isSelected: showsOriginal) { onSelect(true) }
        }
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityElement(children: .contain)
    }
}

private struct PinnedSegment: View {
    let title: LocalizedStringResource
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.accentColor : (isHovering ? Color.primary.opacity(0.08) : .clear))
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The target language, named, with the others a click away.
private struct PinnedLanguageMenu: View {
    let target: String
    let targets: [String]
    let onSelect: (String) -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            ForEach(targets, id: \.self) { language in
                Toggle(isOn: Binding(
                    get: { language == target },
                    set: { _ in onSelect(language) }
                )) {
                    Text(ScreenshotTranslation.displayName(for: language))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "translate")
                    .font(.system(size: 14, weight: .medium))
                Text(ScreenshotTranslation.displayName(for: target))
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Translate to \(ScreenshotTranslation.displayName(for: target))")
    }
}

/// The editor's tool strip, with colour, history and the way out below it.
private struct PinnedAnnotationBar: View {
    @Bindable var editor: AnnotationEditorModel
    let controller: PinnedScreenshotController

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AnnotationToolStrip(selectedTool: editor.selectedTool, onSelect: editor.selectTool)

            HStack(spacing: 6) {
                PinnedSwatchRow(editor: editor)
                    .glassSurface(in: .capsule)
                AnnotationHistoryControl(model: editor, onAction: {})

                PinnedTextButton(title: "Discard", isProminent: false, action: controller.discardAnnotating)
                    .help("Discard annotations")
                PinnedTextButton(title: "Done", isProminent: true, action: controller.finishAnnotating)
                    .help("Save annotations (Esc)")
            }
            .disabled(editor.isCommitting)
        }
    }

}

/// A capture being marked up straight after Capture Area and Pin: the
/// editor's tool strip, and below it colour and every way out, nothing
/// behind a menu, so a capture can be marked up and copied with ✓ in one go.
/// Laid out like `PinnedAnnotationBar`, so the two read as one family.
private struct PinnedCaptureBar: View {
    @Bindable var editor: AnnotationEditorModel
    let controller: PinnedScreenshotController

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AnnotationToolStrip(selectedTool: editor.selectedTool, onSelect: editor.selectTool)

            HStack(spacing: 6) {
                PinnedSwatchRow(editor: editor)
                    .glassSurface(in: .capsule)
                actions
            }
        }
        .disabled(editor.isCommitting)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            PinnedToolbarButton(
                title: "Translate Image",
                systemImage: "translate",
                help: "Translate the text where it is",
                action: controller.translateInPlace
            )
            .disabled(controller.pin.translation != nil)
            PinnedToolbarButton(
                title: "Copy Text from Image",
                systemImage: "text.viewfinder",
                help: "Copy Text from Image",
                action: controller.copyText
            )

            PinnedToolbarDivider()
            PinnedToolbarButton(
                title: "Undo",
                systemImage: "arrow.uturn.backward",
                help: "Undo (⌘Z)",
                action: editor.undo
            )
            .disabled(!editor.canUndo)

            PinnedToolbarDivider()
            PinnedToolbarButton(
                title: "Save…",
                systemImage: "square.and.arrow.down",
                help: "Save… (⌘S)",
                action: controller.saveAnnotatedImage
            )
            PinnedToolbarButton(
                title: "Keep Pinned",
                systemImage: "pin",
                help: "Keep pinned with these annotations",
                action: controller.keepCapturePinned
            )

            PinnedToolbarDivider()
            PinnedToolbarButton(
                title: "Cancel",
                systemImage: "xmark",
                help: "Close without copying (Esc)",
                tint: .red,
                action: controller.cancelEditingCapture
            )
            PinnedToolbarButton(
                title: "Copy and Close",
                systemImage: "checkmark",
                help: "Copy and close (Return)",
                tint: .green,
                action: controller.copyCaptureAndClose
            )
        }
        .padding(4)
        .glassSurface(in: .rect(cornerRadius: 14))
    }
}

/// The colours worth a click on a small toolbar; the full editor has the rest.
private struct PinnedSwatchRow: View {
    @Bindable var editor: AnnotationEditorModel

    private static let swatches: [AnnotationSwatch] = [.red, .orange, .yellow, .green, .blue, .black, .white]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.swatches) { swatch in
                let isSelected = editor.selectedSwatch == swatch
                Button {
                    editor.setSwatch(swatch)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1) }
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay {
                            if isSelected {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(swatch.title)
                .accessibilityLabel(swatch.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .disabled(!editor.isColorStyleAvailable)
        .opacity(editor.isColorStyleAvailable ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color")
    }
}

/// Sized and highlighted like the editor's tool strip buttons, so the two
/// toolbars read as one family.
private struct PinnedToolbarButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let help: LocalizedStringResource
    var isActive = false
    /// Colours the symbol, as ✕ and ✓ are.
    var tint: Color?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: tint == nil ? .medium : .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 28)
                .foregroundStyle(isActive ? Color.white : (tint ?? Color.primary))
                .opacity(isEnabled ? 1 : 0.35)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isActive ? Color.accentColor : (isHovering ? Color.primary.opacity(0.08) : .clear))
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help(Text(help))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Drawn by hand: the toolbar's window never becomes key, and system
/// prominent buttons drew there as if disabled.
private struct PinnedTextButton: View {
    let title: LocalizedStringResource
    let isProminent: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isProminent ? .semibold : .regular))
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background {
                    if isProminent {
                        Capsule().fill(Color.accentColor.opacity(isHovering ? 0.85 : 1))
                    } else {
                        Capsule().fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                    }
                }
                .glassSurface(in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
    }
}

private struct PinnedToolbarDivider: View {
    var body: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 4)
    }
}
