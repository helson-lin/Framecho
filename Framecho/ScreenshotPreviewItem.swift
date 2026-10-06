//
//  ScreenshotPreviewItem.swift
//  Framecho
//

import AppKit

struct ScreenshotPreviewItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var previewImage: NSImage
    var kind: PreviewMediaKind = .image
    var autoSavedURL: URL?

    static func == (lhs: ScreenshotPreviewItem, rhs: ScreenshotPreviewItem) -> Bool {
        lhs.id == rhs.id
    }
}
