//
//  ScreenshotImageLoader.swift
//  Framecho
//
//  Created by Codex on 26/04/26.
//

import AppKit
import ImageIO

enum ScreenshotImageLoader {
    static func imageSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        
        return CGSize(width: width, height: height)
    }
    
    static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    /// Decodes the image at its native pixel resolution. Used when the
    /// low-resolution editing preview preference is disabled.
    static func fullResolutionImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    /// Same thumbnail as `downsampledImage`, decoded off the main actor so a
    /// large capture doesn't hold up the UI while its preview is made.
    static func downsampledImageInBackground(at url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let pixelSize = max(1, Int(maxPixelSize.rounded(.up)))
        let cgImage = await Task.detached(priority: .userInitiated) {
            downsampledCGImage(at: url, maxPixelSize: pixelSize)
        }.value
        return cgImage.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
    }

    private nonisolated static func downsampledCGImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }
}

/// Carries a capture's pixel density (144 DPI on Retina) onto images derived
/// from it. Without it ImageIO writes 72 DPI, and Preview and other viewers
/// then show an edited Retina screenshot at twice its on-screen size.
nonisolated enum ImageDensityMetadata {
    /// DPI properties to pass when adding a derived image to a destination;
    /// empty when the source records none.
    static func properties(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        var density: [CFString: Any] = [:]
        density[kCGImagePropertyDPIWidth] = properties[kCGImagePropertyDPIWidth]
        density[kCGImagePropertyDPIHeight] = properties[kCGImagePropertyDPIHeight]
        return density
    }
}
