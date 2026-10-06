//
//  AnnotationColorSampler.swift
//  Framecho
//
//  Reads screenshot pixels for color tags and the color loupe, in sRGB so a
//  hex is the one a browser or design tool would show for it.
//

import CoreGraphics

enum AnnotationColorSampler {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The pixels around a point, upright, and the color of the one in the middle.
    struct Neighborhood {
        /// `(2 * radius + 1)` pixels square. Pixels beyond the image's edge are transparent.
        var image: CGImage
        var center: ColorTagProps
    }

    /// The color of the pixel under `point`, given in the image's own pixel
    /// space (y-down, `pageSize` units). `image` may be a scaled copy, as the
    /// low-resolution preview is.
    static func color(in image: CGImage, pageSize: CGSize, at point: Vec) -> ColorTagProps? {
        neighborhood(in: image, pageSize: pageSize, around: point, radius: 0)?.center
    }

    static func neighborhood(in image: CGImage, pageSize: CGSize, around point: Vec, radius: Int) -> Neighborhood? {
        guard pageSize.width > 0, pageSize.height > 0,
              point.x >= 0, point.y >= 0,
              point.x < Double(pageSize.width), point.y < Double(pageSize.height) else { return nil }

        let x = min(image.width - 1, Int(point.x * Double(image.width) / Double(pageSize.width)))
        let y = min(image.height - 1, Int(point.y * Double(image.height) / Double(pageSize.height)))
        let side = radius * 2 + 1

        // Cropping shares the image's pixels, so this stays cheap enough to run per mouse move.
        let wanted = CGRect(x: x - radius, y: y - radius, width: side, height: side)
        let available = wanted.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !available.isEmpty, let crop = image.cropping(to: available),
              let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        // Crop rects are y-down; the context is y-up.
        let offsetX = available.minX - wanted.minX
        let offsetY = available.minY - wanted.minY
        context.draw(crop, in: CGRect(
            x: offsetX,
            y: CGFloat(side) - offsetY - available.height,
            width: available.width,
            height: available.height
        ))

        guard let data = context.data, let result = context.makeImage() else { return nil }
        // The middle pixel is the middle of the buffer whichever way up its rows run.
        let pixel = data.advanced(by: (radius * side + radius) * 4).assumingMemoryBound(to: UInt8.self)
        // Un-premultiply, so a translucent pixel reports its own color.
        let alpha = Int(pixel[3])
        func channel(_ value: UInt8) -> Int {
            alpha == 0 ? 0 : min(255, (Int(value) * 255 + alpha / 2) / alpha)
        }
        return Neighborhood(
            image: result,
            center: ColorTagProps(red: channel(pixel[0]), green: channel(pixel[1]), blue: channel(pixel[2]))
        )
    }
}
