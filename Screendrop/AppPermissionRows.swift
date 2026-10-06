//
//  AppPermissionRows.swift
//  Framecho
//
//  The permission list Settings shows: each permission with its live status
//  and the one action that moves it forward.
//

import SwiftUI

/// One permission with its live status.
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
