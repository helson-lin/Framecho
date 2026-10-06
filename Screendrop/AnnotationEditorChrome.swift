//
//  AnnotationEditorChrome.swift
//  Framecho
//

import SwiftUI

struct AnnotationZoomControl: View {
    @Bindable var model: AnnotationEditorModel

    var body: some View {
        Menu {
            // The image and AppKit annotation layer must receive the same
            // camera immediately; implicit SwiftUI-only animation splits them.
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.canZoomIn)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.canZoomOut)

            Divider()

            Button("Fit Canvas") { model.fitCanvas() }
                .keyboardShortcut("1", modifiers: .command)

            Divider()

            Button("50%") { model.setZoomPercent(50) }
            Button("100%") { model.setZoomPercent(100) }
                .keyboardShortcut("0", modifiers: .command)
            Button("200%") { model.setZoomPercent(200) }
        } label: {
            Text("\(model.zoomPercent)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 38)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zoom")
    }
}

/// Undo and Redo in the canvas corner, beside zoom. They were reachable
/// only through Command-Z and Shift-Command-Z.
struct AnnotationHistoryControl: View {
    @Bindable var model: AnnotationEditorModel
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("Undo", systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) {
                model.undo()
            }
            button("Redo", systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) {
                model.redo()
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 30)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(
        _ title: LocalizedStringResource,
        systemImage: String,
        help: LocalizedStringResource,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onAction()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(Text(help))
        .accessibilityLabel(Text(title))
    }
}

/// A failed save, copy or upload, shown at the top of the canvas where it
/// can't cover the zoom control, with Retry when the action can be repeated
/// and a close button so it never lingers.
struct AnnotationErrorBanner: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

/// Live pixel dimensions of the current crop selection, shown in the bottom
/// trailing corner of the canvas while cropping. Styled to match the zoom
/// control capsule on the opposite side.
struct CropResolutionBadge: View {
    let size: CGSize

    var body: some View {
        Text("\(Int(size.width)) × \(Int(size.height)) px")
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .fixedSize()
            .glassEffect()
            .help("Crop size")
    }
}

/// A small badge shown beside the zoom control when the editing preview is
/// downscaled to save memory. Collapsed it's just an "i" button; tapping it
/// expands an explanation that the reduction is preview-only and points users
/// to Settings to disable it.
struct LowResolutionPreviewNotice: View {
    @State private var isExpanded = false

    private let diameter: CGFloat = 28

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: diameter, height: diameter)

                if isExpanded {
                    Text("Low-res preview to save memory - exports stay full quality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 12)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(height: diameter)
            .fixedSize()
            .glassEffect()
        }
        .buttonStyle(.plain)
        .help("Why is this preview low resolution?")
    }
}

struct AnnotationEditorWorkspaceBackground: View {
    private let dotSpacing: CGFloat = 18
    private let dotRadius: CGFloat = 1.15

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // A flat, fully desaturated gray rather than a system material -
            // vibrancy materials pick up a bluish cast from the accent color
            // and whatever's behind the window, which reads as tinted rather
            // than neutral.
            Rectangle()
                .fill(colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.93))

            Canvas { context, size in
                var path = Path()
                let offset = dotSpacing / 2

                stride(from: offset, through: size.width, by: dotSpacing).forEach { x in
                    stride(from: offset, through: size.height, by: dotSpacing).forEach { y in
                        path.addEllipse(in: CGRect(
                            x: x - dotRadius,
                            y: y - dotRadius,
                            width: dotRadius * 2,
                            height: dotRadius * 2
                        ))
                    }
                }

                context.fill(path, with: .color(Color.secondary.opacity(0.14)))
            }
            .allowsHitTesting(false)
        }
    }
}
