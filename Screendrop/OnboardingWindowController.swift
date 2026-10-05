//
//  OnboardingWindowController.swift
//  Screendrop
//

import AppKit
import SwiftUI

enum OnboardingPage: Hashable {
    case welcome
    case permissions
}

/// Why the window opened, so the permissions page can say what went wrong
/// instead of greeting someone who just tried to take a screenshot.
enum OnboardingReason {
    case firstLaunch
    case screenRecordingNeeded
    case manual
}

@MainActor
@Observable
final class OnboardingNavigation {
    var page: OnboardingPage = .welcome
    var reason: OnboardingReason = .firstLaunch
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: OnboardingWindowController?
    private static let completedKey = "onboarding.completed"

    private let navigation = OnboardingNavigation()
    private var didEnterActivationPolicy = false
    private var onFinish: (() -> Void)?

    /// First launch: shows the welcome before anything else. A Mac that
    /// already allows Screen Recording (an update from a version without
    /// onboarding) skips it.
    /// - Returns: Whether the window opened.
    @discardableResult
    static func showIfNeeded(onFinish: @escaping () -> Void) -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completedKey) else { return false }
        guard !CGPreflightScreenCaptureAccess() else {
            defaults.set(true, forKey: completedKey)
            return false
        }
        show(page: .welcome, reason: .firstLaunch)
        shared?.onFinish = onFinish
        return true
    }

    static func show(page: OnboardingPage, reason: OnboardingReason) {
        if shared == nil {
            shared = OnboardingWindowController()
        }
        shared?.navigation.page = page
        shared?.navigation.reason = reason
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 560, height: 560)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = String(localized: "Welcome to Framecho")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(navigation: navigation, onDone: { [weak self] in self?.finish() })
        )
        PreviewWindowCaptureExclusion.shared.register(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        if !didEnterActivationPolicy {
            AppActivationPolicy.enter()
            didEnterActivationPolicy = true
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing counts as done: the guide comes back on its own only when a
        // capture needs Screen Recording.
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        if didEnterActivationPolicy {
            AppActivationPolicy.leave()
            didEnterActivationPolicy = false
        }
        let onFinish = onFinish
        self.onFinish = nil
        Self.shared = nil
        onFinish?()
    }
}
