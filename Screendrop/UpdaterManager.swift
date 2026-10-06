//
//  UpdaterManager.swift
//  Framecho
//

import AppKit
import Combine
import Foundation
import Sparkle

/// Manages Sparkle auto-update lifecycle.
///
/// Sparkle's `SPUStandardUpdaterController` must be created early, before
/// `applicationDidFinishLaunching` returns, so the automatic update check
/// schedule starts correctly.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    /// Framecho's own feed and EdDSA key are in Info.plist. Turning this off
    /// stops the updater and hides its menu item and Settings section.
    static let isEnabled = true

    private let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }

    func start() {
        #if DEBUG
        return
        #else
        guard Self.isEnabled else { return }
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        #if DEBUG
        return
        #else
        guard Self.isEnabled else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }
}
