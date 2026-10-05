//
//  AppPermissions.swift
//  Screendrop
//
//  One place that knows every privacy permission Framecho asks for: what it
//  is for, whether it's granted, how to ask, and where in System Settings to
//  send the user once macOS stops asking. The onboarding window and Settings
//  both read it.
//

import AppKit
import AVFoundation
import IOKit.hid
import Observation
import UserNotifications

enum AppPermission: String, CaseIterable, Identifiable {
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

    fileprivate var settingsURL: URL? {
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

enum AppPermissionStatus: Equatable {
    case granted
    /// macOS will show its own prompt when asked.
    case notDetermined
    /// Only System Settings can change it now.
    case denied
    /// Blocked by a profile; nobody on this Mac can change it.
    case restricted
}

@MainActor
@Observable
final class AppPermissionCenter {
    static let shared = AppPermissionCenter()

    private(set) var statuses: [AppPermission: AppPermissionStatus] = [:]
    /// Permissions sent to System Settings this session. macOS applies a
    /// Screen Recording or Input Monitoring grant only after a relaunch, so
    /// these are the ones that may be waiting on one.
    private(set) var sentToSettings: Set<AppPermission> = []

    @ObservationIgnored private var observerCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private static let screenRecordingRequestedKey = "permissions.screenRecordingRequested"

    private init() {
        refresh()
    }

    func status(of permission: AppPermission) -> AppPermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    var isScreenRecordingGranted: Bool { status(of: .screenRecording) == .granted }

    /// Whether a grant made in System Settings needs Framecho to relaunch.
    var isRelaunchSuggested: Bool {
        sentToSettings.contains { $0.needsRelaunchAfterGrant && status(of: $0) != .granted }
    }

    // MARK: Status

    func refresh() {
        statuses[.screenRecording] = Self.screenRecordingStatus()
        statuses[.microphone] = Self.status(for: .audio)
        statuses[.camera] = Self.status(for: .video)
        statuses[.inputMonitoring] = Self.inputMonitoringStatus()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            statuses[.notifications] = switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .granted
            case .notDetermined: .notDetermined
            case .denied: .denied
            @unknown default: .denied
            }
        }
    }

    /// macOS posts nothing when a permission changes in System Settings, so a
    /// visible permissions list polls while it's on screen.
    func beginObserving() {
        observerCount += 1
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refresh()
            }
        }
    }

    func endObserving() {
        observerCount = max(0, observerCount - 1)
        guard observerCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    private static func screenRecordingStatus() -> AppPermissionStatus {
        if CGPreflightScreenCaptureAccess() { return .granted }
        // There's no "not determined" to read; macOS prompts only the first
        // time it's asked, so remember asking.
        return UserDefaults.standard.bool(forKey: screenRecordingRequestedKey) ? .denied : .notDetermined
    }

    private static func status(for mediaType: AVMediaType) -> AppPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    private static func inputMonitoringStatus() -> AppPermissionStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .notDetermined
        }
    }

    // MARK: Asking

    /// Shows macOS's prompt when it still will, and System Settings when it
    /// won't.
    func request(_ permission: AppPermission) {
        switch status(of: permission) {
        case .granted, .restricted:
            return
        case .denied:
            openSettings(for: permission)
            return
        case .notDetermined:
            break
        }

        switch permission {
        case .screenRecording:
            UserDefaults.standard.set(true, forKey: Self.screenRecordingRequestedKey)
            // On current macOS this shows a dialog that leads to System
            // Settings; the grant itself happens there.
            if !CGRequestScreenCaptureAccess() {
                sentToSettings.insert(.screenRecording)
            }
            refresh()
        case .microphone, .camera:
            let mediaType: AVMediaType = permission == .microphone ? .audio : .video
            Task {
                _ = await AVCaptureDevice.requestAccess(for: mediaType)
                refresh()
            }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() {
                sentToSettings.insert(.inputMonitoring)
            }
            refresh()
        case .notifications:
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                refresh()
            }
        }
    }

    func openSettings(for permission: AppPermission) {
        sentToSettings.insert(permission)
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Capture gate

    /// Call before capturing. Without Screen Recording, macOS hands back a
    /// picture of the wallpaper or nothing at all, so a window explaining
    /// that opens instead and the capture is skipped.
    func ensureScreenRecording() -> Bool {
        refresh()
        if isScreenRecordingGranted {
            // Pressing the shortcut the guide suggests ends the guide.
            OnboardingWindowController.closeForCapture()
            return true
        }
        OnboardingWindowController.show(page: .permissions, reason: .screenRecordingNeeded)
        return false
    }

    // MARK: Relaunch

    /// Opens a fresh copy once this one has quit, so a new grant applies.
    func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            FailureAlert.present(message: String(localized: "Framecho couldn't reopen itself"), error: error)
        }
    }
}
