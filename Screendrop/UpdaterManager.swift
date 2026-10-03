//
//  UpdaterManager.swift
//  Screendrop
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

    /// Off in this fork: the feed in Info.plist is upstream's appcast, and an
    /// update from it would replace this build with the official release.
    static let isEnabled = false

    private let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

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
