//
//  CloudImageTranscoder.swift
//  Screendrop
//
//  Screenshots live in History as lossless PNG, which is far heavier than a
//  share page needs. Before a cloud upload the image is re-encoded as AVIF -
//  every current browser displays it, unlike HEIC - and optionally scaled
//  from Retina pixels down to points. The History original is never touched;
//  the upload goes from a temporary copy.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CloudImageUploadFormat: String, CaseIterable, Identifiable {
    case avif
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .avif: String(localized: "AVIF (smaller)")
        case .original: String(localized: "Original")
        }
    }
}

nonisolated enum CloudImageTranscoder {
    struct Settings: Sendable {
        var quality: Double
        var downscalesRetina: Bool
    }

    /// The current preferences, or nil when uploads keep the original file.
    @MainActor
    static var currentSettings: Settings? {
        guard CloudUploadPreferences.imageFormat == .avif else { return nil }
        return Settings(
            quality: CloudUploadPreferences.imageQuality,
            downscalesRetina: CloudUploadPreferences.downscalesRetinaImages
        )
    }

    /// Whether this file is worth re-encoding. Lossless and browser-hostile
    /// formats are; already-compressed web formats go up untouched, and
    /// JPEG is left alone rather than compressed a second time.
    static func shouldTranscode(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .png) || type.conforms(to: .heic) || type.conforms(to: .tiff)
    }

    /// Writes an AVIF copy of `sourceURL` into its own temporary directory,
    /// keeping the original file name stem (the worker shows it as the
    /// default title). Returns nil when the copy would not be smaller, so a
    /// tiny flat PNG never grows on the way up.
    ///
    /// - Parameter scaleReferenceURL: Where to read the Retina scale from,
    ///   ahead of `sourceURL` itself. Annotated renders are written at 72 DPI
    ///   whatever the capture was; their untouched base image keeps the real
    ///   density.
    static func transcodeToAVIF(
        sourceURL: URL,
        scaleReferenceURL: URL?,
        settings: Settings
    ) throws -> URL? {
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let sourceScale = scaleReferenceURL.flatMap(pixelScale(of:)) ?? pixelScale(of: sourceURL) ?? 1
        let scale = settings.downscalesRetina ? sourceScale : 1
        let image: CGImage?
        if scale > 1.01, let size = pixelSize(of: source) {
            let maxPixelSize = Int((Double(max(size.width, size.height)) / scale).rounded())
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw CocoaError(.fileReadCorruptFile) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Framecho-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationURL = directory
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("avif")

        do {
            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                "public.avif" as CFString,
                1,
                nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            // Downscaled output is one pixel per point; otherwise keep the
            // source's density so a Retina copy still reports as 2x.
            let dpi = 72 * (scale > 1.01 ? 1 : sourceScale)
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: settings.quality,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw CocoaError(.fileWriteUnknown)
            }

            if scale <= 1.01,
               let originalSize = fileSize(sourceURL),
               let encodedSize = fileSize(destinationURL),
               encodedSize >= originalSize {
                removeTemporaryCopy(destinationURL)
                return nil
            }
            return destinationURL
        } catch {
            removeTemporaryCopy(destinationURL)
            throw error
        }
    }

    /// Deletes a copy made by `transcodeToAVIF`, along with its directory.
    static func removeTemporaryCopy(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Pixels per point recorded by the capture (144 DPI on Retina).
    private static func pixelScale(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
              dpi > 0 else {
            return nil
        }
        return dpi / 72
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    private static func fileSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}
