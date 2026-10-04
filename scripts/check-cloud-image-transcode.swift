import CoreGraphics
import Foundation
import ImageIO

// Exercises the pre-upload AVIF transcode without launching Framecho.
@main
struct CloudImageTranscodeChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("framecho-transcode-check-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        // A noisy 800x600 image: big enough that AVIF beats PNG.
        func writePNG(_ name: String, dpi: Double?) throws -> URL {
            let width = 800, height = 600
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            var generator = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: height, by: 4) {
                for x in stride(from: 0, to: width, by: 4) {
                    let shade = CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255
                    context.setFillColor(red: shade, green: CGFloat(x) / CGFloat(width), blue: CGFloat(y) / CGFloat(height), alpha: 1)
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
            let url = root.appendingPathComponent(name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            var properties: [CFString: Any] = [:]
            if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
            CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
            return url
        }
        func info(_ url: URL) -> (width: Int, height: Int, dpi: Double?, bytes: Int) {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            return (
                properties[kCGImagePropertyPixelWidth] as! Int,
                properties[kCGImagePropertyPixelHeight] as! Int,
                (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
                try! url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            )
        }

        let retina = try writePNG("Framecho_retina.png", dpi: 144)

        // Full resolution: same pixels and density, smaller file, clean name.
        let full = try CloudImageTranscoder.transcodeToAVIF(
            sourceURL: retina, scaleReferenceURL: nil,
            settings: .init(quality: 0.8, downscalesRetina: false)
        )!
        precondition(full.lastPathComponent == "Framecho_retina.avif")
        let fullInfo = info(full)
        precondition(fullInfo.width == 800 && fullInfo.height == 600)
        precondition(fullInfo.dpi == 144)
        precondition(fullInfo.bytes < info(retina).bytes)
        CloudImageTranscoder.removeTemporaryCopy(full)
        precondition(!manager.fileExists(atPath: full.deletingLastPathComponent().path))

        // 1x: halved from the 144 DPI capture.
        let scaled = try CloudImageTranscoder.transcodeToAVIF(
            sourceURL: retina, scaleReferenceURL: nil,
            settings: .init(quality: 0.8, downscalesRetina: true)
        )!
        let scaledInfo = info(scaled)
        precondition(scaledInfo.width == 400 && scaledInfo.height == 300, "\(scaledInfo)")
        precondition(scaledInfo.dpi == 72)
        CloudImageTranscoder.removeTemporaryCopy(scaled)

        // An annotated render is written at 72 DPI; the base image supplies
        // the real scale, for both the 1x size and the full-size density.
        let annotated = try writePNG("annotated.png", dpi: 72)
        let annotatedScaled = try CloudImageTranscoder.transcodeToAVIF(
            sourceURL: annotated, scaleReferenceURL: retina,
            settings: .init(quality: 0.8, downscalesRetina: true)
        )!
        precondition(info(annotatedScaled).width == 400)
        CloudImageTranscoder.removeTemporaryCopy(annotatedScaled)
        let annotatedFull = try CloudImageTranscoder.transcodeToAVIF(
            sourceURL: annotated, scaleReferenceURL: retina,
            settings: .init(quality: 0.8, downscalesRetina: false)
        )!
        precondition(info(annotatedFull).width == 800 && info(annotatedFull).dpi == 144)
        CloudImageTranscoder.removeTemporaryCopy(annotatedFull)

        let rendered = try writePNG("rendered.png", dpi: nil)
        let fromBase = try CloudImageTranscoder.transcodeToAVIF(
            sourceURL: rendered, scaleReferenceURL: retina,
            settings: .init(quality: 0.8, downscalesRetina: true)
        )!
        precondition(info(fromBase).width == 400)
        CloudImageTranscoder.removeTemporaryCopy(fromBase)

        // No DPI anywhere: nothing to infer, so no scaling.
        let unknown = try CloudImageTranscoder.transcodeToAVIF(
            sourceURL: rendered, scaleReferenceURL: root.appendingPathComponent("missing.png"),
            settings: .init(quality: 0.8, downscalesRetina: true)
        )!
        precondition(info(unknown).width == 800)
        CloudImageTranscoder.removeTemporaryCopy(unknown)

        precondition(CloudImageTranscoder.shouldTranscode(retina))
        precondition(!CloudImageTranscoder.shouldTranscode(root.appendingPathComponent("a.jpg")))
        precondition(!CloudImageTranscoder.shouldTranscode(root.appendingPathComponent("a.gif")))
        print("PASS: AVIF output, 1x from DPI and from base image, no-DPI passthrough, cleanup")
    }
}
