//
//  AnnotationToolStrip.swift
//  Framecho
//
//  The annotation tools, floating in glass over the top of the canvas.
//  They used to live in the inspector, a long way from where you draw and
//  gone entirely once the inspector was hidden.
//

import SwiftUI

struct AnnotationToolStrip: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    /// Space the canvas keeps clear at the top so a fitted image never sits
    /// under the strip.
    static let reservedHeight: CGFloat = 36

    /// Select · shapes and lines · numbers and text · redaction.
    private static let groups: [[AnnotationTool]] = [
        [.select],
        [.rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand],
        [.numberedCircle, .text],
        [.highlight, .pixelate, .blur],
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 4)
                }
                ForEach(group) { tool in
                    AnnotationToolStripButton(
                        tool: tool,
                        isSelected: tool == selectedTool,
                        action: { onSelect(tool) }
                    )
                }
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation tools")
    }
}

private struct AnnotationToolStripButton: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.systemImage)
                .latinSymbolGlyphs()
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 28)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.accentColor : (isHovering ? Color.primary.opacity(0.08) : .clear))
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help(tool.tooltip)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.helpText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
