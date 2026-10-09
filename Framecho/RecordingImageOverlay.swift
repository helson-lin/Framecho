//
//  RecordingImageOverlay.swift
//  Framecho
//
//  Images laid over a Studio recording for a stretch of time - a logo, a QR
//  code, a screenshot. Each sits in canvas space, like the subtitle bar: it
//  stays put while the camera zooms and stays in frame when the export is
//  reframed. Timing is on the source timeline, like captions and zooms, so
//  an image travels with the footage it belongs to when that is cut.
//

import CoreGraphics
import Foundation
import ImageIO

nonisolated struct RecordingImageOverlay: Identifiable, Codable, Equatable, Sendable {
    static let minimumDuration: TimeInterval = 0.5
    static let defaultDuration: TimeInterval = 4
    static let fadeDuration: TimeInterval = 0.3
    /// Width as a share of the canvas width.
    static let widthRange: ClosedRange<Double> = 0.04...1
    static let defaultWidth = 0.22
    /// Corner radius as a share of the image's shorter side.
    static let cornerRadiusRange: ClosedRange<Double> = 0...0.5
    /// Gap kept from the canvas edge by the position presets, as a share of
    /// the canvas's shorter side.
    static let edgeMargin = 0.05

    var id: UUID
    /// The image's file inside the recording package's assets folder.
    var fileName: String
    /// The name the image was imported under, for the inspector.
    var displayName: String
    /// Width over height of the image as drawn, recorded at import so layout
    /// never has to decode it.
    var aspectRatio: Double
    var start: TimeInterval
    var end: TimeInterval
    /// A placement preset, resolved against the canvas at draw time so the
    /// image stays in its corner through size, aspect and caption changes.
    /// Nil for an image placed freely at `center`.
    var anchor: RecordingImageOverlayAnchor?
    /// Normalized center on the canvas, top-left origin, used when there is
    /// no anchor.
    var center: CGPoint
    var width: Double
    var opacity: Double
    var cornerRadius: Double
    var hasShadow: Bool
    /// Fades in and out over `fadeDuration` instead of cutting in.
    var fades: Bool

    init(
        id: UUID = UUID(),
        fileName: String,
        displayName: String,
        aspectRatio: Double,
        start: TimeInterval,
        end: TimeInterval,
        anchor: RecordingImageOverlayAnchor? = .center,
        center: CGPoint = CGPoint(x: 0.5, y: 0.5),
        width: Double = RecordingImageOverlay.defaultWidth,
        opacity: Double = 1,
        cornerRadius: Double = 0,
        hasShadow: Bool = false,
        fades: Bool = true
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.aspectRatio = aspectRatio
        self.start = start
        self.end = end
        self.anchor = anchor
        self.center = center
        self.width = width
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.hasShadow = hasShadow
        self.fades = fades
    }

    var duration: TimeInterval { max(0, end - start) }

    /// Every value within its range, so a hand-edited or agent-written
    /// project can't produce an unreadable layout.
    var sanitized: RecordingImageOverlay {
        var overlay = self
        overlay.aspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? min(max(aspectRatio, 0.05), 20) : 1
        overlay.center = CGPoint(x: Self.unit(center.x), y: Self.unit(center.y))
        overlay.width = Self.clamp(width, to: Self.widthRange, fallback: Self.defaultWidth)
        overlay.opacity = Self.clamp(opacity, to: 0...1, fallback: 1)
        overlay.cornerRadius = Self.clamp(cornerRadius, to: Self.cornerRadiusRange, fallback: 0)
        return overlay
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, displayName, aspectRatio, start, end, anchor, center, width
        case opacity, cornerRadius, hasShadow, fades
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try container.decode(String.self, forKey: .fileName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? fileName
        aspectRatio = try container.decodeIfPresent(Double.self, forKey: .aspectRatio) ?? 1
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        // An anchor a later build added reads as a free placement.
        anchor = (try? container.decodeIfPresent(String.self, forKey: .anchor))
            .flatMap { $0 }
            .flatMap(RecordingImageOverlayAnchor.init(rawValue:))
        center = try container.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.5)
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? Self.defaultWidth
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        hasShadow = try container.decodeIfPresent(Bool.self, forKey: .hasShadow) ?? false
        fades = try container.decodeIfPresent(Bool.self, forKey: .fades) ?? true
    }

    private static func unit(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}

// MARK: - Placement

/// The nine spots the inspector and agents offer, kept a margin in from the
/// canvas edge.
nonisolated enum RecordingImageOverlayAnchor: String, CaseIterable, Codable, Sendable {
    case topLeading = "top-left", top, topTrailing = "top-right"
    case leading = "left", center, trailing = "right"
    case bottomLeading = "bottom-left", bottom, bottomTrailing = "bottom-right"

    var column: Int { (Self.allCases.firstIndex(of: self) ?? 4) % 3 }
    var row: Int { (Self.allCases.firstIndex(of: self) ?? 4) / 3 }

    init(column: Int, row: Int) {
        self = Self.allCases[min(max(row, 0), 2) * 3 + min(max(column, 0), 2)]
    }

    /// The center that puts an overlay of this size at the spot. A row on
    /// the side of the canvas the captions sit on stops short of their band.
    func center(
        for overlay: RecordingImageOverlay,
        canvasSize: CGSize,
        captionBand: ClosedRange<CGFloat>? = nil
    ) -> CGPoint {
        CGPoint(
            x: RecordingImageOverlayLayout.columnCenters(for: overlay, canvasSize: canvasSize)[column],
            y: RecordingImageOverlayLayout.rowCenters(for: overlay, canvasSize: canvasSize, captionBand: captionBand)[row]
        )
    }
}

nonisolated enum RecordingImageOverlayLayout {
    static func size(for overlay: RecordingImageOverlay, canvasSize: CGSize) -> CGSize {
        let overlay = overlay.sanitized
        let width = overlay.width * canvasSize.width
        return CGSize(width: width, height: width / overlay.aspectRatio)
    }

    /// The normalized center an overlay draws at: its preset resolved on
    /// this canvas, or its free position.
    static func center(
        for overlay: RecordingImageOverlay,
        canvasSize: CGSize,
        captionBand: ClosedRange<CGFloat>? = nil
    ) -> CGPoint {
        guard let anchor = overlay.anchor, canvasSize.width > 0, canvasSize.height > 0 else {
            return overlay.sanitized.center
        }
        return anchor.center(for: overlay, canvasSize: canvasSize, captionBand: captionBand)
    }

    /// Where the image draws, in canvas points with a top-left origin.
    static func rect(
        for overlay: RecordingImageOverlay,
        canvasSize: CGSize,
        captionBand: ClosedRange<CGFloat>? = nil
    ) -> CGRect {
        let size = size(for: overlay, canvasSize: canvasSize)
        let center = center(for: overlay, canvasSize: canvasSize, captionBand: captionBand)
        return CGRect(
            x: center.x * canvasSize.width - size.width / 2,
            y: center.y * canvasSize.height - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func margin(_ canvasSize: CGSize) -> CGFloat {
        RecordingImageOverlay.edgeMargin * min(canvasSize.width, canvasSize.height)
    }

    /// Normalized centers of the left, middle and right columns. An image
    /// wider than the room between the margins centers instead.
    static func columnCenters(for overlay: RecordingImageOverlay, canvasSize: CGSize) -> [CGFloat] {
        guard canvasSize.width > 0 else { return [0.5, 0.5, 0.5] }
        let half = min(0.5, (size(for: overlay, canvasSize: canvasSize).width / 2 + margin(canvasSize)) / canvasSize.width)
        return [half, 0.5, 1 - half]
    }

    /// Normalized centers of the top, middle and bottom rows, the outer one
    /// on the captions' side moved clear of `captionBand`.
    static func rowCenters(
        for overlay: RecordingImageOverlay,
        canvasSize: CGSize,
        captionBand: ClosedRange<CGFloat>? = nil
    ) -> [CGFloat] {
        guard canvasSize.height > 0 else { return [0.5, 0.5, 0.5] }
        let height = size(for: overlay, canvasSize: canvasSize).height
        let margin = margin(canvasSize)
        var top = height / 2 + margin
        var bottom = canvasSize.height - height / 2 - margin
        if let captionBand {
            if captionBand.lowerBound > canvasSize.height / 2 {
                bottom = min(bottom, captionBand.lowerBound - margin - height / 2)
            } else {
                top = max(top, captionBand.upperBound + margin + height / 2)
            }
        }
        // Too tall for the room left: fall back to the middle.
        guard top <= canvasSize.height / 2, bottom >= canvasSize.height / 2 else {
            return [0.5, 0.5, 0.5]
        }
        return [top / canvasSize.height, 0.5, bottom / canvasSize.height]
    }

    /// The band the subtitle bar takes, sized for two lines, in canvas
    /// points. `fontSize` is the bar's, from SubtitleBarMetrics.
    static func captionBand(canvasSize: CGSize, verticalPosition: Double, fontSize: CGFloat) -> ClosedRange<CGFloat> {
        let height = fontSize * 1.2 * (1 + 1.12) + fontSize
        let center = canvasSize.height * CGFloat(verticalPosition)
        return (center - height / 2)...(center + height / 2)
    }

    /// Snaps a dragged center onto the preset columns and rows within
    /// `threshold` points. Landing on both makes the image that preset again.
    static func snapped(
        center: CGPoint,
        for overlay: RecordingImageOverlay,
        canvasSize: CGSize,
        captionBand: ClosedRange<CGFloat>? = nil,
        threshold: CGFloat
    ) -> (center: CGPoint, anchor: RecordingImageOverlayAnchor?) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return (center, nil) }
        func nearest(_ value: CGFloat, in candidates: [CGFloat], length: CGFloat) -> (Int, CGFloat)? {
            candidates.enumerated()
                .map { ($0.offset, $0.element, abs($0.element - value) * length) }
                .filter { $0.2 <= threshold }
                .min { $0.2 < $1.2 }
                .map { ($0.0, $0.1) }
        }
        let column = nearest(center.x, in: columnCenters(for: overlay, canvasSize: canvasSize), length: canvasSize.width)
        let row = nearest(
            center.y,
            in: rowCenters(for: overlay, canvasSize: canvasSize, captionBand: captionBand),
            length: canvasSize.height
        )
        let snappedCenter = CGPoint(x: column?.1 ?? center.x, y: row?.1 ?? center.y)
        guard let column, let row else { return (snappedCenter, nil) }
        return (snappedCenter, RecordingImageOverlayAnchor(column: column.0, row: row.0))
    }

    static func cornerRadius(for overlay: RecordingImageOverlay, in rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) * overlay.sanitized.cornerRadius
    }

    /// A soft drop shadow scaled to the canvas, so it reads the same in the
    /// preview and in a full-size export.
    static func shadow(canvasSize: CGSize) -> (radius: CGFloat, offset: CGFloat, opacity: Double) {
        let base = min(canvasSize.width, canvasSize.height)
        return (base * 0.018, base * 0.006, 0.35)
    }
}

// MARK: - Timeline

/// The overlays on the edited timeline. An image whose footage was partly
/// cut shows across what survives as one span; one cut entirely is gone.
nonisolated struct RecordingImageOverlayTimeline: Sendable, Equatable {
    struct Placement: Sendable, Equatable {
        var overlay: RecordingImageOverlay
        var editorStart: TimeInterval
        var editorEnd: TimeInterval
    }

    struct Frame: Sendable, Equatable {
        var overlay: RecordingImageOverlay
        /// The overlay's opacity with its fade applied.
        var opacity: Double
    }

    static let empty = RecordingImageOverlayTimeline(placements: [])

    /// In stacking order: later overlays draw on top.
    let placements: [Placement]

    init(placements: [Placement]) {
        self.placements = placements
    }

    init(overlays: [RecordingImageOverlay], clipTimeline: RecordingClipTimeline) {
        placements = overlays.compactMap { overlay in
            let slices = clipTimeline.slices(overlapping: overlay.start, sourceEnd: overlay.end)
            guard let first = slices.first, let last = slices.last,
                  last.editorEnd > first.editorStart else { return nil }
            return Placement(overlay: overlay.sanitized, editorStart: first.editorStart, editorEnd: last.editorEnd)
        }
    }

    var isEmpty: Bool { placements.isEmpty }

    func placement(for id: UUID) -> Placement? {
        placements.first { $0.overlay.id == id }
    }

    func frames(at editorTime: TimeInterval) -> [Frame] {
        placements.compactMap { placement in
            guard editorTime >= placement.editorStart, editorTime < placement.editorEnd else { return nil }
            let overlay = placement.overlay
            var opacity = overlay.opacity
            if overlay.fades {
                // Never longer than a third of the span, so a short image
                // still reaches full strength.
                let fade = min(RecordingImageOverlay.fadeDuration, (placement.editorEnd - placement.editorStart) / 3)
                if fade > 0 {
                    let fadeIn = (editorTime - placement.editorStart) / fade
                    let fadeOut = (placement.editorEnd - editorTime) / fade
                    opacity *= min(1, max(0, min(fadeIn, fadeOut)))
                }
            }
            guard opacity > 0.001 else { return nil }
            return Frame(overlay: overlay, opacity: opacity)
        }
    }
}

// MARK: - Assets

/// Files an overlay draws live inside the recording package, so the project
/// keeps working after the original is moved or deleted.
nonisolated enum RecordingStudioAssets {
    static let directoryName = "assets"

    struct ImportedImage: Sendable {
        var fileName: String
        var displayName: String
        var aspectRatio: Double
    }

    enum ImportError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                String(localized: "“\(name)” isn't an image Framecho can read.")
            }
        }
    }

    static func directory(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Copies an image into the package under a fresh name and measures it.
    static func importImage(from sourceURL: URL, into packageURL: URL) throws -> ImportedImage {
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        guard let image = loadImage(at: sourceURL, maxPixelSize: 512), image.height > 0 else {
            throw ImportError.unreadable(sourceURL.lastPathComponent)
        }
        let directory = directory(in: packageURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let fileName = "image-\(UUID().uuidString).\(fileExtension)"
        try FileManager.default.copyItem(at: sourceURL, to: directory.appendingPathComponent(fileName))
        return ImportedImage(
            fileName: fileName,
            displayName: displayName,
            aspectRatio: Double(image.width) / Double(image.height)
        )
    }

    /// The image upright (EXIF orientation applied), no larger than
    /// `maxPixelSize` on its long side.
    static func loadImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func loadImage(named fileName: String, in packageURL: URL, maxPixelSize: Int) -> CGImage? {
        loadImage(at: directory(in: packageURL).appendingPathComponent(fileName), maxPixelSize: maxPixelSize)
    }

    /// Removes assets no stored document refers to. Run only where no undo
    /// history could bring a removed overlay back.
    static func removeUnused(in packageURL: URL, keeping fileNames: Set<String>) {
        let directory = directory(in: packageURL)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in contents where !fileNames.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
