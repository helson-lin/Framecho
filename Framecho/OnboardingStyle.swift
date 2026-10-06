//
//  OnboardingStyle.swift
//  Framecho
//
//  The setup guide's look: a warm near-black card (near-white in Light
//  mode) lit by the orange of the app icon, with every action labelled by
//  the key that triggers it.
//

import AppKit
import SwiftUI

struct OnboardingPalette {
    let background: Color
    let bar: Color
    let surface: Color
    let line: Color
    let text: Color
    let secondary: Color
    let keycap: Color
    let keycapBorder: Color
    let primaryFill: Color
    let primaryText: Color
    let ghostFill: Color
    let success: Color
    let tile: Color
    let frame: Color

    /// The orange of the app icon's corner marks.
    static let accent = Color(red: 0.941, green: 0.392, blue: 0.235)
    /// Dark text for the orange fill, which white text fails on.
    static let onAccent = Color(red: 0.10, green: 0.04, blue: 0.02)

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            background = Color(red: 0.086, green: 0.082, blue: 0.078)
            bar = Color(red: 0.106, green: 0.102, blue: 0.094)
            surface = Color(red: 0.125, green: 0.122, blue: 0.114)
            line = .white.opacity(0.08)
            text = Color(red: 0.949, green: 0.941, blue: 0.929)
            secondary = Color(red: 0.631, green: 0.616, blue: 0.592)
            keycap = .white.opacity(0.08)
            keycapBorder = .white.opacity(0.14)
            primaryFill = Color(red: 0.949, green: 0.941, blue: 0.929)
            primaryText = Color(red: 0.086, green: 0.082, blue: 0.078)
            ghostFill = .white.opacity(0.06)
            success = Color(red: 0.29, green: 0.87, blue: 0.50)
            tile = .white.opacity(0.06)
            frame = .white.opacity(0.10)
        } else {
            background = Color(red: 0.984, green: 0.980, blue: 0.973)
            bar = Color(red: 0.957, green: 0.949, blue: 0.933)
            surface = .white
            line = .black.opacity(0.08)
            text = Color(red: 0.110, green: 0.102, blue: 0.090)
            secondary = Color(red: 0.420, green: 0.400, blue: 0.376)
            keycap = .black.opacity(0.05)
            keycapBorder = .black.opacity(0.14)
            primaryFill = Color(red: 0.110, green: 0.102, blue: 0.090)
            primaryText = Color(red: 0.984, green: 0.980, blue: 0.973)
            ghostFill = .black.opacity(0.05)
            success = Color(red: 0.08, green: 0.50, blue: 0.24)
            tile = .black.opacity(0.05)
            frame = .black.opacity(0.12)
        }
    }
}

private struct OnboardingPaletteKey: EnvironmentKey {
    static let defaultValue = OnboardingPalette(.dark)
}

extension EnvironmentValues {
    var onboardingPalette: OnboardingPalette {
        get { self[OnboardingPaletteKey.self] }
        set { self[OnboardingPaletteKey.self] = newValue }
    }
}

enum OnboardingMotion {
    /// Fast out of the gate, long settle: the guide's one curve.
    static let ease = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.42)
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.62)
}

// MARK: - Keycaps

struct OnboardingKeycap: View {
    let label: String
    var isLarge = false

    @Environment(\.onboardingPalette) private var palette

    var body: some View {
        Text(label)
            .font(.system(size: isLarge ? 28 : 11, weight: .medium))
            .foregroundStyle(isLarge ? palette.text : palette.secondary)
            .padding(.horizontal, isLarge ? 16 : 5)
            .frame(minWidth: isLarge ? 64 : 20, minHeight: isLarge ? 64 : 20)
            .background(palette.keycap, in: .rect(cornerRadius: isLarge ? 14 : 5))
            .overlay {
                RoundedRectangle(cornerRadius: isLarge ? 14 : 5)
                    .strokeBorder(palette.keycapBorder)
            }
            .shadow(color: isLarge ? palette.keycapBorder : .clear, radius: 0, y: isLarge ? 3 : 0)
    }
}

// MARK: - Buttons

/// White on dark (dark on light), with the key that triggers it.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    let key: String

    @Environment(\.onboardingPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .frame(minWidth: 20, minHeight: 20)
                .padding(.horizontal, 2)
                .background(Color.gray.opacity(0.18), in: .rect(cornerRadius: 5))
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.primaryText)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(palette.primaryFill, in: .rect(cornerRadius: 8))
        .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet text, with its key when it has one.
struct OnboardingGhostButtonStyle: ButtonStyle {
    var key: String?

    @Environment(\.onboardingPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            if let key {
                OnboardingKeycap(label: key)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.secondary)
        .padding(.leading, 12)
        .padding(.trailing, key == nil ? 12 : 6)
        .frame(height: 32)
        .background(configuration.isPressed ? palette.ghostFill : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
    }
}

/// A row's action: orange for the one that matters most, outlined otherwise.
struct OnboardingRowButtonStyle: ButtonStyle {
    var isProminent = false

    @Environment(\.onboardingPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isProminent ? .semibold : .medium))
            .foregroundStyle(isProminent ? OnboardingPalette.onAccent : palette.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(isProminent ? OnboardingPalette.accent : palette.ghostFill, in: .rect(cornerRadius: 7))
            .overlay {
                if !isProminent {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(palette.keycapBorder)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Motion

extension View {
    /// Fades and lifts into place `delay` seconds after appearing.
    func onboardingRise(delay: Double, distance: CGFloat = 10) -> some View {
        modifier(OnboardingRise(delay: delay, distance: distance))
    }
}

private struct OnboardingRise: ViewModifier {
    let delay: Double
    let distance: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : distance)
            .onAppear {
                withAnimation(reduceMotion ? nil : OnboardingMotion.ease.delay(delay)) {
                    isShown = true
                }
            }
    }
}

/// A sweep of light across a placeholder while a status is being read.
struct OnboardingShimmer: View {
    @Environment(\.onboardingPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(palette.tile)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, palette.keycapBorder, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: phase * proxy.size.width)
                }
                .clipShape(.rect(cornerRadius: 6))
            }
            .frame(width: 64, height: 22)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
            .accessibilityLabel(Text("Checking…"))
    }
}

/// The orange glow behind the top of the card, breathing slowly once lit.
struct OnboardingGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLit = false
    @State private var isBreathing = false

    var body: some View {
        RadialGradient(
            colors: [OnboardingPalette.accent.opacity(0.26), OnboardingPalette.accent.opacity(0)],
            center: .center,
            startRadius: 0,
            endRadius: 260
        )
        // Drawn as a circle, then squashed: a frame shorter than the
        // gradient would cut it off in a hard line.
        .frame(width: 520, height: 520)
        .scaleEffect(x: 1, y: 0.65)
        .scaleEffect(isLit ? 1 : 0.5)
        .opacity(isLit ? (isBreathing ? 0.7 : 1) : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else {
                isLit = true
                return
            }
            withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 1).delay(0.28)) { isLit = true }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true).delay(1.3)) {
                isBreathing = true
            }
        }
    }
}

/// Live blur of whatever is behind the guide, so it needs no capture.
struct OnboardingBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
