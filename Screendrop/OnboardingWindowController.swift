//
//  OnboardingWindowController.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Why the guide was asked for. A capture that needs Screen Recording gets a
/// small window that explains just that; anything else gets the full guide.
enum OnboardingReason {
    case firstLaunch
    case screenRecordingNeeded
    case manual
}

@MainActor
@Observable
final class OnboardingNavigation {
    var page: OnboardingPage = .welcome
}

@MainActor
enum OnboardingWindowController {
    private static var guide: OnboardingOverlayController?
    private static var blocked: CaptureBlockedWindowController?

    private static let completedKey = "onboarding.completed"
    /// Set when the guide opens. Granting Screen Recording takes a relaunch,
    /// so a guide that was started but never finished picks up again.
    private static let startedKey = "onboarding.started"

    static var isShowingGuide: Bool { guide != nil }

    /// First launch, or a relaunch partway through: opens the guide. A Mac
    /// that already allows Screen Recording and never saw the guide (an
    /// update from a version without one) skips it.
    /// - Returns: Whether the guide opened.
    @discardableResult
    static func showIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        switch OnboardingLaunch.decision(
            isCompleted: defaults.bool(forKey: completedKey),
            isResuming: defaults.bool(forKey: startedKey),
            isScreenRecordingGranted: CGPreflightScreenCaptureAccess()
        ) {
        case .none:
            return false
        case .markCompleted:
            defaults.set(true, forKey: completedKey)
            return false
        case .show(let page):
            showGuide(page: page)
            return true
        }
    }

    static func show(page: OnboardingPage, reason: OnboardingReason) {
        switch reason {
        case .screenRecordingNeeded:
            if guide != nil {
                guide?.show(page: .permissions)
                return
            }
            if blocked == nil {
                blocked = CaptureBlockedWindowController { blocked = nil }
            }
            blocked?.showWindow(nil)
        case .firstLaunch, .manual:
            showGuide(page: page)
        }
    }

    /// A capture is starting: get out of its way at once, without opening
    /// the Library.
    static func closeForCapture() {
        guide?.close(openLibrary: false, animated: false)
        blocked?.close()
    }

    private static func showGuide(page: OnboardingPage) {
        blocked?.close()
        if guide == nil {
            UserDefaults.standard.set(true, forKey: startedKey)
            guide = OnboardingOverlayController(page: page) {
                UserDefaults.standard.set(true, forKey: completedKey)
                guide = nil
            }
        }
        guide?.show(page: page)
    }
}

// MARK: - Full-screen guide

private final class OnboardingOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The guide covers the screen the pointer is on, over the menu bar. It
/// fades away while another app is in front - System Settings, most often
/// - and lets clicks through, then returns when Framecho does.
@MainActor
private final class OnboardingOverlayController {
    private let window: OnboardingOverlayWindow
    private let navigation = OnboardingNavigation()
    private let onClose: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var isClosing = false

    init(page: OnboardingPage, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        window = OnboardingOverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.title = String(localized: "Welcome to Framecho")
        navigation.page = page

        let actions = OnboardingActions(
            finish: { [weak self] openLibrary in self?.close(openLibrary: openLibrary, animated: true) },
            changeShortcuts: { [weak self] in
                self?.close(openLibrary: false, animated: true) {
                    SettingsWindowController.show(tab: .screenshots)
                }
            }
        )
        window.contentView = NSHostingView(rootView: OnboardingView(navigation: navigation, actions: actions))
        PreviewWindowCaptureExclusion.shared.register(window: window)
    }

    func show(page: OnboardingPage) {
        let isFirstShow = !window.isVisible
        navigation.page = page
        guard isFirstShow else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        AppActivationPolicy.enter()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fade(to: 1, duration: 0.42)
        observeActivation()
    }

    func close(openLibrary: Bool, animated: Bool, then completion: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []

        let finish = { [self] in
            window.orderOut(nil)
            window.contentView = nil
            AppActivationPolicy.leave()
            onClose()
            if openLibrary {
                CaptureLibraryModel.shared.show()
            }
            completion?()
        }
        if animated {
            fade(to: 0, duration: 0.22, completion: finish)
        } else {
            finish()
        }
    }

    private func observeActivation() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window.ignoresMouseEvents = true
                self.fade(to: 0, duration: 0.2)
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosing else { return }
                self.window.ignoresMouseEvents = false
                self.window.makeKeyAndOrderFront(nil)
                self.fade(to: 1, duration: 0.3)
            }
        })
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }
}

// MARK: - Capture blocked

@MainActor
private final class CaptureBlockedWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CaptureBlockedView.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = String(localized: "Allow Screen Recording")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: CaptureBlockedView(onClose: { [weak window] in window?.close() })
        )
        PreviewWindowCaptureExclusion.shared.register(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true {
            AppActivationPolicy.enter()
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.leave()
        onClose()
    }
}
