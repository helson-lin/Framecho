//
//  RecordingPointerArtworkCapture.swift
//  Framecho
//
//  Converts AppKit-provided cursor images into the recording sidecar format.
//  Shapes Framecho draws in place of the pointer are in RecordingCursorStyle.
//

import AppKit
import Foundation

@MainActor
enum PointerArtworkCapture {
    static func defaultArtwork() -> PointerArtwork? {
        capture(NSCursor.arrow, id: "pointer-default")
    }

    /// Identifies what a cursor looks like without encoding it.
    /// `NSCursor.currentSystem` returns a new object on every call, so object
    /// identity never repeats; hot spot, size, and pixels do. Nil when the
    /// pixels can't be read, so the caller captures rather than guessing.
    static func fingerprint(of cursor: NSCursor) -> Int? {
        let image = cursor.image
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let pixels = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)?
            .dataProvider?.data else {
            return nil
        }
        var hasher = Hasher()
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        hasher.combine(image.size.width)
        hasher.combine(image.size.height)
        hasher.combine(pixels as Data)
        return hasher.finalize()
    }

    static func capture(_ cursor: NSCursor, id: String) -> PointerArtwork? {
        let image = cursor.image
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let imageData = bitmap.representation(using: .png, properties: [:]),
              !imageData.isEmpty else {
            return nil
        }

        let imageSize = image.size
        let width = imageSize.width.isFinite && imageSize.width > 0
            ? imageSize.width
            : CGFloat(bitmap.pixelsWide)
        let height = imageSize.height.isFinite && imageSize.height > 0
            ? imageSize.height
            : CGFloat(bitmap.pixelsHigh)
        guard width > 0, height > 0 else { return nil }

        let hotSpot = cursor.hotSpot
        return PointerArtwork(
            artworkID: id,
            imageData: imageData,
            anchorPoint: PointerArtwork.Point(
                x: min(max(hotSpot.x.isFinite ? hotSpot.x : 0, 0), width),
                y: min(max(hotSpot.y.isFinite ? hotSpot.y : 0, 0), height)
            ),
            referenceSize: PointerArtwork.Size(
                width: width,
                height: height
            )
        )
    }
}
