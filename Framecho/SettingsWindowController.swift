//
//  SettingsWindowController.swift
//  Framecho
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private var didEnterActivationPolicy = false

    static func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }

        if shared == nil {
            shared = SettingsWindowController()
        }

        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowFrameDefaults.settingsSize),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .miniaturizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        guard let window else { return }

        window.title = String(localized: "Settings")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        // AppKit's inferred order-front transition animates the custom
        // full-size-content window's shadow independently from its frame on
        // Tahoe. Keep the WindowServer geometry static and provide a simple
        // opacity entrance in `showWindow` instead.
        window.animationBehavior = .none
        // Keep the window movable only via its title bar. Background dragging
        // makes the whole content area move the window, which both feels off and
        // swallows in-content drag gestures (e.g. the overlay card editor).
        window.isMovableByWindowBackground = false
        window.delegate = self

        let hostingController = NSHostingController(rootView: SettingsView())
        // The window keeps the size it is given below rather than taking
        // the SwiftUI content's ideal size, which overrode the default
        // width; the minimum still comes from minSize.
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        // An empty unified toolbar gives the title bar the Library window's
        // height, so the traffic lights sit inside the inset sidebar panel
        // the same way in both windows.
        if window.toolbar == nil {
            window.toolbar = NSToolbar(identifier: "SettingsWindowToolbar")
        }

        // Size after the content and toolbar are in place - setting a
        // content view controller resizes the window to its view - then
        // let a saved frame, if any, take over.
        window.minSize = WindowFrameDefaults.settingsMinimum
        window.setContentSize(WindowFrameDefaults.settingsSize)
        window.setFrameAutosaveName("SettingsWindow")
        WindowFrameDefaults.adoptDefaultIfTooSmall(
            window,
            minimum: WindowFrameDefaults.settingsMinimum,
            defaultSize: WindowFrameDefaults.settingsSize
        )
        window.center()
        PreviewWindowCaptureExclusion.shared.register(window: window)
    }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }

        if !didEnterActivationPolicy {
            AppActivationPolicy.enter()
            didEnterActivationPolicy = true
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let isOpening = !window.isVisible
        let shouldAnimate = isOpening
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.alphaValue = shouldAnimate ? 0 : 1

        super.showWindow(sender)

        // AppKit focuses the first control when the window becomes key, which
        // draws a focus ring on the export folder picker before anything was
        // pressed. Start with the window itself focused; Tab still moves in.
        if isOpening {
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }

        guard shouldAnimate else { return }
        window.displayIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().alphaValue = 1
        }
    }

    func windowWillClose(_ notification: Notification) {
        if didEnterActivationPolicy {
            AppActivationPolicy.leave()
            didEnterActivationPolicy = false
        }
        Self.shared = nil
    }
}
