//
//  AppPermission.swift
//  Framecho
//
//  The privacy permissions Framecho uses, what each is for, and the rules
//  for reading their status. AppPermissionCenter asks macOS.
//

import Foundation

nonisolated enum AppPermission: String, CaseIterable, Identifiable {
    case screenRecording
    case microphone
    case camera
    case inputMonitoring
    case notifications

    var id: Self { self }

    /// Without it nothing can be captured; everything else adds to recordings.
    var isRequired: Bool { self == .screenRecording }

    var title: String {
        switch self {
        case .screenRecording: String(localized: "Screen Recording")
        case .microphone: String(localized: "Microphone")
        case .camera: String(localized: "Camera")
        case .inputMonitoring: String(localized: "Input Monitoring")
        case .notifications: String(localized: "Notifications")
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording:
            String(localized: "Needed for every screenshot and recording.")
        case .microphone:
            String(localized: "Adds your narration to recordings.")
        case .camera:
            String(localized: "Shows you in a camera bubble while recording.")
        case .inputMonitoring:
            String(localized: "Shows the keys you press and smooths the pointer in recordings.")
        case .notifications:
            String(localized: "Tells you when a recording has finished exporting.")
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic"
        case .camera: "video"
        case .inputMonitoring: "keyboard"
        case .notifications: "bell.badge"
        }
    }

    /// macOS only applies these to a running app after it relaunches.
    var needsRelaunchAfterGrant: Bool {
        self == .screenRecording || self == .inputMonitoring
    }

    var settingsURL: URL? {
        let string = switch self {
        case .screenRecording:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .camera:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .inputMonitoring:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .notifications:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
        }
        return URL(string: string)
    }
}

nonisolated enum AppPermissionStatus: Equatable {
    case granted
    /// macOS will show its own prompt when asked.
    case notDetermined
    /// Only System Settings can change it now.
    case denied
    /// Blocked by a profile; nobody on this Mac can change it.
    case restricted
}

/// The decisions about permissions that don't need macOS to answer them,
/// checked by scripts/check-app-permissions.swift.
nonisolated enum AppPermissionRules {
    /// There's no "not determined" to read for Screen Recording: macOS
    /// prompts only the first time it's asked, so whether Framecho has asked
    /// before stands in for it.
    static func screenRecordingStatus(isGranted: Bool, wasRequested: Bool) -> AppPermissionStatus {
        if isGranted { return .granted }
        return wasRequested ? .denied : .notDetermined
    }

    /// A grant that applies only after a relaunch, made in System Settings,
    /// and not yet seen by this process.
    static func isRelaunchSuggested(
        sentToSettings: Set<AppPermission>,
        status: (AppPermission) -> AppPermissionStatus
    ) -> Bool {
        sentToSettings.contains { $0.needsRelaunchAfterGrant && status($0) != .granted }
    }
}
