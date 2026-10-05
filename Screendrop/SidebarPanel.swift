//
//  SidebarPanel.swift
//  Screendrop
//

import AppKit
import SwiftUI

extension View {
    /// Draws a sidebar as a rounded panel inset from the window's edges, the
    /// floating look the design calls for. On macOS 27 the system sidebar
    /// otherwise runs edge to edge.
    func sidebarPanel() -> some View {
        modifier(SidebarPanel())
    }
}

private struct SidebarPanel: ViewModifier {
    static let inset: CGFloat = 8
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            // Keep rows and their selection inside the panel's edges.
            .contentMargins(.horizontal, Self.inset, for: .scrollContent)
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    shape
                        .fill(Color(nsColor: .underPageBackgroundColor))
                        .overlay { shape.strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
                        .padding(Self.inset)
                }
                .ignoresSafeArea()
            }
    }
}
