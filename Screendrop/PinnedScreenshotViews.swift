//
//  PinnedScreenshotViews.swift
//  Screendrop
//
//  A pin's image, and the toolbar that sits outside it while it's selected,
//  so nothing covers the picture just because the pointer passed over it.
//

import SwiftUI

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
                let isActive = pin.isSelected || pin.editor != nil
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
    }

    @ViewBuilder
    private var content: some View {
        if let editor = pin.editor, let image = editor.previewImage {
            AnnotationCanvas(model: editor, image: image, onEditorInteraction: {}, fitInsets: .zero)
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
                    onZoomIn: editor.zoomIn,
                    onZoomOut: editor.zoomOut,
                    onFitCanvas: editor.fitCanvas,
                    onActualSize: { editor.setZoomPercent(100) },
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
            if let editor = pin.editor {
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
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
            }
        } icon: {
            switch feedback {
            case .zoom: Image(systemName: "plus.magnifyingglass")
            case .opacity: Image(systemName: "circle.lefthalf.filled")
            }
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        switch feedback {
        case .zoom(let percent): Text("Zoom \(percent)%")
        case .opacity(let percent): Text("Opacity \(percent)%")
        }
    }
}

/// The editor's tool strip, with colour, history and the way out below it.
private struct PinnedAnnotationBar: View {
    @Bindable var editor: AnnotationEditorModel
    let controller: PinnedScreenshotController

    /// The colours worth a click on a small toolbar; the full editor has the rest.
    private static let swatches: [AnnotationSwatch] = [.red, .orange, .yellow, .green, .blue, .black, .white]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AnnotationToolStrip(selectedTool: editor.selectedTool, onSelect: editor.selectTool)

            HStack(spacing: 6) {
                swatchRow
                AnnotationHistoryControl(model: editor, onAction: {})

                PinnedTextButton(title: "Discard", isProminent: false, action: controller.discardAnnotating)
                    .help("Discard annotations")
                PinnedTextButton(title: "Done", isProminent: true, action: controller.finishAnnotating)
                    .help("Save annotations (Esc)")
            }
            .disabled(editor.isCommitting)
        }
    }

    private var swatchRow: some View {
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
        .glassEffect(.regular, in: .capsule)
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 28)
                .foregroundStyle(isActive ? Color.white : Color.primary)
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
                .glassEffect(.regular, in: .capsule)
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
