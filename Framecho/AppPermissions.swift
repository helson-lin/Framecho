//
//  AppPermissions.swift
//  Framecho
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
        AppPermissionRules.isRelaunchSuggested(sentToSettings: sentToSettings, status: status(of:))
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
        AppPermissionRules.screenRecordingStatus(
            isGranted: CGPreflightScreenCaptureAccess(),
            wasRequested: UserDefaults.standard.bool(forKey: screenRecordingRequestedKey)
        )
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
                openSettings(for: .screenRecording)
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
        if permission == .screenRecording, status(of: permission) != .granted {
            ScreenRecordingPermissionPresenter.shared.show()
        }
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
