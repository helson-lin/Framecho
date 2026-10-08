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
    /// 2980 × 1880 px on a 2× Retina display.
    static let studioSize = CGSize(width: 1490, height: 940)
    static let studioMinimum = CGSize(width: 980, height: 720)
    /// 1640 × 1220 px on a 2× Retina display.
    static let settingsSize = CGSize(width: 820, height: 610)
    static let settingsMinimum = CGSize(width: 680, height: 540)

    private static let resetVersionKey = "windowFramesResetVersion"
    /// Bump to discard saved Studio and Settings frames once more.
    private static let resetVersion = 1

    /// Drops the saved Studio and Settings frames once, so both open at
    /// their defaults after an update; sizes chosen afterwards are kept.
    static func discardOutdatedFrames(in defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: resetVersionKey) < resetVersion else { return }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame VIDEO_EDITOR") || key == "NSWindow Frame SettingsWindow" {
            defaults.removeObject(forKey: key)
        }
        defaults.set(resetVersion, forKey: resetVersionKey)
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
