//
//  OnboardingView.swift
//  Framecho
//
//  The setup guide: a card over a dimmed, blurred screen that walks through
//  what Framecho does, the permissions it needs, and the shortcut to try.
//

import AppKit
import SwiftUI

/// What the guide's buttons ask its window to do.
struct OnboardingActions {
    var finish: (_ openLibrary: Bool) -> Void
    var changeShortcuts: () -> Void
}

struct OnboardingView: View {
    @Bindable var navigation: OnboardingNavigation
    let actions: OnboardingActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCardShown = false

    static let cardSize = CGSize(width: 760, height: 520)

    var body: some View {
        let palette = OnboardingPalette(colorScheme)
        ZStack {
            OnboardingBackdrop()
            Color.black.opacity(0.45)

            VStack(spacing: 18) {
                card(palette: palette)
                    .scaleEffect(isCardShown || reduceMotion ? 1 : 0.94)
                    .offset(y: isCardShown || reduceMotion ? 0 : 16)
                    .opacity(isCardShown ? 1 : 0)

                Text("Press esc to leave the guide at any time.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .onboardingRise(delay: 1, distance: 0)
            }
        }
        .ignoresSafeArea()
        .environment(\.onboardingPalette, palette)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86).delay(0.12)) {
                isCardShown = true
            }
        }
    }

    private func card(palette: OnboardingPalette) -> some View {
        ZStack(alignment: .top) {
            palette.background
            OnboardingGlow()
                .offset(y: -70)

            Group {
                switch navigation.page {
                case .welcome:
                    OnboardingWelcomePage(onContinue: { show(.permissions) }, onLeave: { actions.finish(true) })
                case .permissions:
                    OnboardingPermissionsPage(onContinue: { show(.ready) }, onLeave: { actions.finish(true) })
                case .ready:
                    OnboardingReadyPage(actions: actions)
                }
            }
            .id(navigation.page)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: reduceMotion ? 0 : 24)),
                removal: .opacity
            ))
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .foregroundStyle(palette.text)
        .clipShape(.rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(palette.frame) }
        .shadow(color: .black.opacity(0.55), radius: 60, y: 40)
    }

    private func show(_ page: OnboardingPage) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
            navigation.page = page
        }
    }
}

// MARK: - Footer

private struct OnboardingFooter<Trailing: View>: View {
    let step: Int
    @ViewBuilder let trailing: Trailing

    @Environment(\.onboardingPalette) private var palette

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<OnboardingPage.allCases.count, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? OnboardingPalette.accent : palette.keycapBorder)
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Step \(step + 1) of \(OnboardingPage.allCases.count)"))

            Spacer()

            HStack(spacing: 6) { trailing }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 56)
        .background(palette.bar)
        .overlay(alignment: .top) { palette.line.frame(height: 1) }
        .onboardingRise(delay: 0.7, distance: 0)
    }
}

private struct OnboardingLeaveButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(OnboardingGhostButtonStyle(key: "esc"))
            .keyboardShortcut(.cancelAction)
    }
}

// MARK: - Welcome

private struct OnboardingWelcomePage: View {
    let onContinue: () -> Void
    let onLeave: () -> Void

    @Environment(\.onboardingPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isIconShown = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 120, height: 120)
                    .shadow(color: OnboardingPalette.accent.opacity(0.35), radius: 16, y: 12)
                    .scaleEffect(isIconShown || reduceMotion ? 1 : 0.6)
                    .rotationEffect(.degrees(isIconShown || reduceMotion ? 0 : -8))
                    .opacity(isIconShown ? 1 : 0)
                    .accessibilityHidden(true)

                Text("Welcome to Framecho")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.6)
                    .padding(.top, 10)
                    .onboardingRise(delay: 0.46)

                Text("Capture, record, annotate and pin, all a shortcut away.")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .onboardingRise(delay: 0.54)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 24)

            OnboardingFooter(step: 0) {
                OnboardingLeaveButton(title: "Later", action: onLeave)
                Button("Get Started", action: onContinue)
                    .buttonStyle(OnboardingPrimaryButtonStyle(key: "↩"))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.64, dampingFraction: 0.62).delay(0.3)) {
                isIconShown = true
            }
        }
    }
}

// MARK: - Permissions

private struct OnboardingPermissionsPage: View {
    let onContinue: () -> Void
    let onLeave: () -> Void

    @Environment(\.onboardingPalette) private var palette
    @State private var center = AppPermissionCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Allow access")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.5)
                    .onboardingRise(delay: 0, distance: 8)
                Text("Screen Recording is required. Turn on the rest as you need them; you can change any of them later in Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary)
                    .padding(.top, 6)
                    .onboardingRise(delay: 0.06, distance: 8)

                VStack(spacing: 2) {
                    ForEach(Array(AppPermission.allCases.enumerated()), id: \.element) { index, permission in
                        OnboardingPermissionRow(permission: permission, index: index)
                    }
                }
                .padding(.top, 16)

                if center.isRelaunchSuggested {
                    OnboardingRelaunchNotice()
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(OnboardingMotion.ease, value: center.isRelaunchSuggested)

            OnboardingFooter(step: 1) {
                OnboardingLeaveButton(title: "Later", action: onLeave)
                Button("Continue", action: onContinue)
                    .buttonStyle(OnboardingPrimaryButtonStyle(key: "↩"))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!center.isScreenRecordingGranted)
                    .help(center.isScreenRecordingGranted ? "" : String(localized: "Allow Screen Recording to continue."))
            }
        }
        .onAppear { center.beginObserving() }
        .onDisappear { center.endObserving() }
    }
}

private struct OnboardingPermissionRow: View {
    let permission: AppPermission
    let index: Int

    @Environment(\.onboardingPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var center = AppPermissionCenter.shared
    /// The status shows once the row has settled in, a shimmer until then,
    /// so five rows don't flash five states on arrival.
    @State private var isStatusShown = false

    private var rowDelay: Double { 0.14 + Double(index) * 0.06 }

    var body: some View {
        let status = center.status(of: permission)
        let needsAttention = permission.isRequired && status != .granted

        HStack(spacing: 12) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(palette.tile, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(permission.title)
                        .font(.system(size: 14, weight: .semibold))
                    if permission.isRequired {
                        Text("Required")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OnboardingPalette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(OnboardingPalette.accent.opacity(0.14), in: .rect(cornerRadius: 4))
                    }
                }
                Text(permission.purpose)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            ZStack(alignment: .trailing) {
                if isStatusShown {
                    control(for: status)
                        .id(status)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity),
                            removal: .scale(scale: 0.9).combined(with: .opacity)
                        ))
                } else {
                    OnboardingShimmer()
                        .transition(.opacity)
                }
            }
            .animation(OnboardingMotion.pop, value: status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(needsAttention ? palette.surface : .clear, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(needsAttention ? OnboardingPalette.accent : .clear)
        }
        .animation(OnboardingMotion.ease, value: needsAttention)
        .onboardingRise(delay: rowDelay)
        .accessibilityElement(children: .contain)
        .task {
            guard !reduceMotion else {
                isStatusShown = true
                return
            }
            try? await Task.sleep(for: .seconds(rowDelay + 0.45))
            withAnimation(OnboardingMotion.ease) { isStatusShown = true }
        }
    }

    @ViewBuilder
    private func control(for status: AppPermissionStatus) -> some View {
        switch status {
        case .granted:
            Label("Allowed", systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.success)
        case .notDetermined:
            Button("Allow…") { center.request(permission) }
                .buttonStyle(OnboardingRowButtonStyle(isProminent: permission.isRequired))
        case .denied:
            Button {
                center.openSettings(for: permission)
            } label: {
                Label("System Settings", systemImage: "arrow.up.forward")
                    .labelStyle(OnboardingTrailingIconLabelStyle())
            }
            .buttonStyle(OnboardingRowButtonStyle())
            .help("macOS won't ask again. Turn Framecho on in Privacy & Security.")
        case .restricted:
            Text("Managed on this Mac")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
        }
    }
}

private struct OnboardingTrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.system(size: 9, weight: .bold))
        }
    }
}

private struct OnboardingRelaunchNotice: View {
    @Environment(\.onboardingPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(palette.secondary)
                .accessibilityHidden(true)
            Text("Turned something on in System Settings? Reopen Framecho to apply it.")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reopen") { AppPermissionCenter.shared.relaunch() }
                .buttonStyle(OnboardingGhostButtonStyle(key: "⌘R"))
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(palette.surface, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line) }
    }
}

// MARK: - Ready

private struct OnboardingReadyPage: View {
    let actions: OnboardingActions

    @Environment(\.onboardingPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hotkeys = HotkeyManager.shared
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("You're all set")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.5)
                    .onboardingRise(delay: 0, distance: 8)
                Text("Try it now: press these keys and drag over any part of the screen.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary)
                    .padding(.top, 6)
                    .onboardingRise(delay: 0.06, distance: 8)

                HStack(spacing: 10) {
                    let tokens = hotkeys.activeShortcuts[.area]?.displayTokens ?? []
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        if index > 0 {
                            Text("+")
                                .font(.system(size: 20))
                                .foregroundStyle(palette.secondary)
                        }
                        OnboardingKeycap(label: token, isLarge: true)
                    }
                }
                .padding(.top, 26)
                .onboardingRise(delay: 0.16, distance: 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(hotkeys.activeShortcuts[.area]?.displayString ?? ""))

                HStack(spacing: 6) {
                    Circle()
                        .fill(OnboardingPalette.accent)
                        .frame(width: 6, height: 6)
                        .scaleEffect(isPulsing ? 1.3 : 1)
                        .opacity(isPulsing ? 0.6 : 1)
                    Text("Waiting for you to press the shortcut…")
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingPalette.accent)
                }
                .padding(.top, 14)
                .onboardingRise(delay: 0.3, distance: 0)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    shortcutTile(.fullscreen, title: "Capture Fullscreen", systemImage: "display")
                    shortcutTile(.window, title: "Capture Window", systemImage: "macwindow")
                    shortcutTile(.screenRecording, title: "Record Screen", systemImage: "record.circle")
                    shortcutTile(.pinArea, title: "Capture Area and Pin", systemImage: "pin")
                }
                .padding(.top, 28)
                .onboardingRise(delay: 0.36)
            }
            .padding(.horizontal, 56)
            .padding(.top, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            OnboardingFooter(step: 2) {
                Button("Change Shortcuts", action: actions.changeShortcuts)
                    .buttonStyle(OnboardingGhostButtonStyle())
                OnboardingLeaveButton(title: "Done", action: { actions.finish(false) })
                Button("Open Library", action: { actions.finish(true) })
                    .buttonStyle(OnboardingPrimaryButtonStyle(key: "↩"))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { isPulsing = true }
        }
    }

    private func shortcutTile(_ action: CaptureHotkeyAction, title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(palette.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(Array((hotkeys.activeShortcuts[action]?.displayTokens ?? ["—"]).enumerated()), id: \.offset) { _, token in
                    OnboardingKeycap(label: token)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(palette.surface, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line) }
        .accessibilityElement(children: .combine)
    }
}
