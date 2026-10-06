//
//  CaptureBlockedView.swift
//  Framecho
//
//  What a capture without Screen Recording opens: a small window that says
//  why nothing happened and gives the one next step, instead of the whole
//  setup guide.
//

import SwiftUI

struct CaptureBlockedView: View {
    let onClose: () -> Void

    static let size = CGSize(width: 560, height: 420)

    @Environment(\.colorScheme) private var colorScheme
    @State private var center = AppPermissionCenter.shared

    var body: some View {
        let palette = OnboardingPalette(colorScheme)
        let status = center.status(of: .screenRecording)

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Image(systemName: "lock")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(OnboardingPalette.accent)
                    .frame(width: 56, height: 56)
                    .background(OnboardingPalette.accent.opacity(0.14), in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)

                Text("Screen Recording permission needed")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.top, 16)

                Text("That capture didn't happen. Allow Screen Recording for Framecho in System Settings, then reopen Framecho.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Open Privacy & Security › Screen & System Audio Recording")
                    step(2, "Turn on the switch next to Framecho")
                    step(3, "Come back here and click Reopen")
                }
                .padding(.top, 18)
            }
            .padding(.horizontal, 48)
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 6) {
                Spacer()
                Button("Not Now", action: onClose)
                    .buttonStyle(OnboardingGhostButtonStyle(key: "esc"))
                    .keyboardShortcut(.cancelAction)
                primaryButton(for: status)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .background(palette.bar)
            .overlay(alignment: .top) { palette.line.frame(height: 1) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(palette.text)
        .background(palette.background)
        .environment(\.onboardingPalette, palette)
        .onAppear { center.beginObserving() }
        .onDisappear { center.endObserving() }
    }

    /// One button that always does the next thing: ask, go to System
    /// Settings, or reopen once the switch may be on.
    @ViewBuilder
    private func primaryButton(for status: AppPermissionStatus) -> some View {
        let style = OnboardingPrimaryButtonStyle(key: "↩")
        if status == .granted {
            Button("Done", action: onClose).buttonStyle(style)
        } else if center.sentToSettings.contains(.screenRecording) {
            Button("Reopen") { center.relaunch() }.buttonStyle(style)
        } else if status == .notDetermined {
            Button("Allow…") { center.request(.screenRecording) }.buttonStyle(style)
        } else {
            Button("Open System Settings") { center.openSettings(for: .screenRecording) }.buttonStyle(style)
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            OnboardingKeycap(label: "\(number)")
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(OnboardingPalette(colorScheme).secondary)
        }
    }
}
