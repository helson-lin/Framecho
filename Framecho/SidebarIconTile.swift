//
//  SidebarIconTile.swift
//  Framecho
//

import SwiftUI

/// A filled neutral tile with a tinted glyph, so the sidebar reads by
/// shape and color without six saturated blocks competing for attention.
struct SidebarIconTile: View {
    let systemImage: String
    let tint: Color

    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        // The sidebar resizes label icons to its row metrics, so the glyph
        // gets an explicit size to keep padding inside the tile.
        Image(systemName: systemImage)
            .resizable()
            .scaledToFit()
            .fontWeight(.medium)
            .foregroundStyle(tint)
            .frame(width: 14, height: 14)
            .frame(width: 24, height: 24)
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}
