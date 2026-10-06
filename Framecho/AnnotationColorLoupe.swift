//
//  AnnotationColorLoupe.swift
//  Framecho
//
//  The magnifier the color tool shows in place of the pointer: the pixels
//  around it, enlarged on a grid, with the one a click would label outlined.
//

import SwiftUI

struct AnnotationColorLoupe: View {
    let neighborhood: AnnotationColorSampler.Neighborhood

    /// Pixels shown either side of the sampled one.
    static let pixelRadius = 5
    static let diameter: CGFloat = 120

    private static var pixelCount: Int { pixelRadius * 2 + 1 }
    private static var cellSize: CGFloat { diameter / CGFloat(pixelCount) }

    var body: some View {
        VStack(spacing: 6) {
            magnifiedPixels
            hexLabel
        }
        // Centre the magnifier, not the label under it, on the pointer.
        .offset(y: Self.hexLabelHeight / 2 + 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var magnifiedPixels: some View {
        ZStack {
            // Off the screenshot's edge, the loupe shows a neutral fill rather than the canvas.
            Color(nsColor: .windowBackgroundColor)
            Image(decorative: neighborhood.image, scale: 1)
                .resizable()
                .interpolation(.none)
            pixelGrid
            targetOutline
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.white, lineWidth: 2)
        }
        .overlay {
            Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private var pixelGrid: some View {
        Path { path in
            for index in 1..<Self.pixelCount {
                let offset = CGFloat(index) * Self.cellSize
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset, y: Self.diameter))
                path.move(to: CGPoint(x: 0, y: offset))
                path.addLine(to: CGPoint(x: Self.diameter, y: offset))
            }
        }
        .stroke(.black.opacity(0.1), lineWidth: 0.5)
    }

    /// A white square inside a dark one, so the target reads on any color.
    private var targetOutline: some View {
        ZStack {
            Rectangle().strokeBorder(.black.opacity(0.7), lineWidth: 1)
            Rectangle().strokeBorder(.white, lineWidth: 1).padding(1)
        }
        .frame(width: Self.cellSize + 2, height: Self.cellSize + 2)
    }

    private static let hexLabelHeight: CGFloat = 20

    private var hexLabel: some View {
        Text(neighborhood.center.hex)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: Self.hexLabelHeight)
            .background(Capsule().fill(Color(nsColor: ColorTagLayout.pillColor)))
    }
}
