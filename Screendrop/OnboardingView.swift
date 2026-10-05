//
//  OnboardingView.swift
//  Screendrop
//
//  The first-run guide: what Framecho does, then the permissions it needs,
//  each with its live status and the one action that moves it forward.
//

import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var navigation: OnboardingNavigation
    let onDone: () -> Void

    var body: some View {
        ZStack {
            switch navigation.page {
            case .welcome:
                OnboardingWelcomePage(onContinue: { show(.permissions) })
                    .transition(pageTransition(forward: false))
            case .permissions:
                OnboardingPermissionsPage(
                    reason: navigation.reason,
                    onBack: navigation.reason == .firstLaunch ? { show(.welcome) } : nil,
                    onDone: onDone
                )
                .transition(pageTransition(forward: true))
            }
        }
        .frame(width: 560, height: 560)
    }

    private func show(_ page: OnboardingPage) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy(duration: 0.3)) {
            navigation.page = page
        }
    }

    private func pageTransition(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 24 : -24)),
            removal: .opacity
        )
    }
}

// MARK: - Welcome

private struct OnboardingWelcomePage: View {
    let onContinue: () -> Void

    @State private var hotkeys = HotkeyManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("Welcome to Framecho")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 16)

            Text("Capture, record and mark up your screen from the menu bar or a shortcut.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 20) {
                OnboardingFeatureRow(
                    systemImage: "camera.viewfinder",
                    title: "Capture anything",
                    detail: Text(captureDetail)
                )
                OnboardingFeatureRow(
                    systemImage: "record.circle",
                    title: "Record your screen",
                    detail: Text("With narration, a camera bubble and the keys you press.")
                )
                OnboardingFeatureRow(
                    systemImage: "pin",
                    title: "Mark up and pin",
                    detail: Text("Annotate a capture, or pin it on top while you work.")
                )
            }
            .frame(maxWidth: 400, alignment: .leading)
            .padding(.top, 36)

            Spacer(minLength: 24)

            HStack {
                Spacer()
                Button(action: onContinue) {
                    Text("Continue")
                        .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
    }

    private var captureDetail: String {
        if let shortcut = hotkeys.activeShortcuts[.area] {
            return String(localized: "A screen, a window or an area. Press \(shortcut.displayString) to draw one.")
        }
        return String(localized: "A screen, a window or an area.")
    }
}

private struct OnboardingFeatureRow: View {
    let systemImage: String
    let title: LocalizedStringResource
    let detail: Text

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                detail
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Permissions

private struct OnboardingPermissionsPage: View {
    let reason: OnboardingReason
    let onBack: (() -> Void)?
    let onDone: () -> Void

    @State private var center = AppPermissionCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reason == .screenRecordingNeeded ? "Allow Screen Recording" : "Allow access")
                    .font(.system(size: 24, weight: .bold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 44)

            VStack(spacing: 0) {
                ForEach(Array(AppPermission.allCases.enumerated()), id: \.element) { index, permission in
                    if index > 0 {
                        Divider().padding(.leading, 52)
                    }
                    AppPermissionRow(permission: permission)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.top, 20)

            if center.isRelaunchSuggested {
                AppPermissionRelaunchNotice()
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .transition(.opacity)
            }

            Spacer(minLength: 16)

            HStack {
                if let onBack {
                    Button("Back", action: onBack)
                        .controlSize(.large)
                }
                Spacer()
                if center.isScreenRecordingGranted {
                    Button(action: onDone) {
                        Text("Done").frame(minWidth: 88)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: onDone)
                        .controlSize(.large)
                        .help("You can allow access later in Settings > General.")
                }
            }
            .padding(24)
        }
        .animation(.snappy(duration: 0.2), value: center.isRelaunchSuggested)
        .onAppear { center.beginObserving() }
        .onDisappear { center.endObserving() }
    }

    private var subtitle: String {
        switch reason {
        case .screenRecordingNeeded:
            String(localized: "Framecho can't capture the screen until Screen Recording is allowed. Turn it on, then try again.")
        case .firstLaunch, .manual:
            String(localized: "Screen Recording is required. The rest are optional, and you can change any of them later.")
        }
    }
}

// MARK: - Shared rows

/// One permission with its live status. Used by the guide and by Settings.
struct AppPermissionRow: View {
    let permission: AppPermission

    @State private var center = AppPermissionCenter.shared

    var body: some View {
        let status = center.status(of: permission)
        HStack(spacing: 12) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.tint.quaternary, in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.body.weight(.medium))
                    if permission.isRequired {
                        Text("Required")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundStyle(.secondary)
                            .overlay(Capsule().strokeBorder(.separator))
                    }
                }
                Text(permission.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            control(for: status)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func control(for status: AppPermissionStatus) -> some View {
        switch status {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
        case .notDetermined:
            if permission.isRequired {
                Button("Allow…") { center.request(permission) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Allow…") { center.request(permission) }
            }
        case .denied:
            Button("Open System Settings") { center.openSettings(for: permission) }
                .help("macOS won't ask again. Turn Framecho on in Privacy & Security.")
        case .restricted:
            Text("Managed on this Mac")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// macOS applies some grants only to a freshly opened app.
struct AppPermissionRelaunchNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Turned it on in System Settings? Quit and reopen Framecho to apply it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Quit & Reopen") { AppPermissionCenter.shared.relaunch() }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}
