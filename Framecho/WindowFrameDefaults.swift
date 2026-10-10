//
//  WindowFrameDefaults.swift
//  Framecho
//
//  Default window sizes, and guards against restored sizes that no longer
//  fit them. macOS restores a window's last frame over its default size, so
//  a frame saved by an older layout - smaller than today's minimum - would
//  otherwise stick forever.
//

import AppKit

enum WindowFrameDefaults {
    /// 3448 × 2188 px on a 2× Retina display: close to the whole screen of
    /// a 16-inch MacBook Pro. A smaller screen caps it at its visible frame.
    static let studioSize = CGSize(width: 1724, height: 1094)
    static let studioMinimum = CGSize(width: 980, height: 720)
    /// 1840 × 1220 px on a 2× Retina display.
    static let settingsSize = CGSize(width: 920, height: 610)
    static let settingsMinimum = CGSize(width: 680, height: 540)

    /// Saved frames to drop once, per window: bump a version when that
    /// window's default size changes, so it opens at the new default after
    /// an update. Sizes chosen afterwards are kept.
    private static let resets: [(versionKey: String, version: Int, frameKey: (String) -> Bool)] = [
        ("windowFramesResetVersion", 4, { $0.hasPrefix("NSWindow Frame VIDEO_EDITOR") }),
        ("settingsWindowFrameResetVersion", 3, { $0 == "NSWindow Frame SettingsWindow" }),
    ]

    static func discardOutdatedFrames(in defaults: UserDefaults = .standard) {
        // Before the per-window versions, one reset covered both windows.
        if defaults.integer(forKey: "windowFramesResetVersion") >= 1,
           defaults.object(forKey: "settingsWindowFrameResetVersion") == nil {
            defaults.set(1, forKey: "settingsWindowFrameResetVersion")
        }
        for reset in resets where defaults.integer(forKey: reset.versionKey) < reset.version {
            for key in defaults.dictionaryRepresentation().keys where reset.frameKey(key) {
                defaults.removeObject(forKey: key)
            }
            defaults.set(reset.version, forKey: reset.versionKey)
        }
    }

    /// The default size, capped to what the screen can show.
    static func fitted(_ size: CGSize, in available: CGSize) -> CGSize {
        CGSize(width: min(size.width, available.width), height: min(size.height, available.height))
    }

    /// A restored frame smaller than the window's minimum came from an
    /// older layout; open at the default size instead.
    static func adoptDefaultIfTooSmall(_ window: NSWindow, minimum: CGSize, defaultSize: CGSize) {
        let content = window.contentRect(forFrameRect: window.frame).size
        guard content.width < minimum.width - 1 || content.height < minimum.height - 1 else { return }
        window.setContentSize(defaultSize)
        window.center()
    }
}
