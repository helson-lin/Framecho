//
//  SidebarPanel.swift
//  Framecho
//

import AppKit
import SwiftUI

extension View {
    /// Draws a sidebar as a rounded panel inset from the window's edges, the
    /// floating look the design calls for. On macOS 27 the system sidebar
    /// otherwise runs edge to edge. It also keeps the sidebar from being
    /// dragged narrower than its rows need.
    func sidebarPanel() -> some View {
        modifier(SidebarPanel())
    }
}

private struct SidebarPanel: ViewModifier {
    static let inset: CGFloat = 8
    /// The split view ignores `navigationSplitViewColumnWidth` here and opens
    /// the column at 144 pt, which clips the rows' titles and counts. A
    /// minimum frame on the content is what it honors, both when the window
    /// opens and while the divider is dragged.
    static let minWidth: CGFloat = 210
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            // The sidebar list ignores content margins for its selection, so
            // inset the list itself to keep rows clear of the panel's edges.
            .padding(.horizontal, Self.inset)
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
            .frame(minWidth: Self.minWidth)
    }
}
