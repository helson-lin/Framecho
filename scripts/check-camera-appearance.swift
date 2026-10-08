import CoreGraphics
import Foundation

@main
struct CameraAppearanceChecks {
    static func main() throws {
        var appearance = RecordingCameraAppearance()
        precondition(appearance.shape == .circle && !appearance.isFlipped)
        appearance.shape = .square
        precondition(appearance.roundness == 0.12)
        appearance.isFlipped = true
        let decoded = try JSONDecoder().decode(
            RecordingCameraAppearance.self,
            from: JSONEncoder().encode(appearance)
        )
        precondition(decoded == appearance)
        appearance.shape = .circle
        precondition(appearance.roundness == 0.5 && appearance.isFlipped)

        // Nonzero canvas origin: the bubble must flip around its own center,
        // with its crop, vertical position, and border staying in place.
        let rect = CGRect(x: 40, y: 70, width: 160, height: 160)
        let transform = appearance.transform(in: rect)
        precondition(CGPoint(x: rect.minX, y: rect.minY).applying(transform)
                     == CGPoint(x: rect.maxX, y: rect.minY))
        precondition(CGPoint(x: rect.midX, y: rect.midY).applying(transform)
                     == CGPoint(x: rect.midX, y: rect.midY))
        let point = CGPoint(x: 55, y: 112)
        precondition(point.applying(transform).applying(transform) == point)
        appearance.isFlipped = false
        precondition(appearance.transform(in: rect) == .identity)

        // Exercise the same clipped Core Graphics draw as the exporter with
        // an asymmetric image. A flip must exchange left and right pixels.
        let source = bitmap(width: 4, height: 2)
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        source.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        source.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        let image = source.makeImage()!
        let target = bitmap(width: 8, height: 6)
        let bubble = CGRect(x: 2, y: 2, width: 4, height: 2)
        let baseline = bitmap(width: 8, height: 6)
        baseline.draw(image, in: bubble)
        target.addRect(bubble)
        target.clip()
        target.concatenate(RecordingCameraAppearance(isFlipped: true).transform(in: bubble))
        target.draw(image, in: bubble)
        let bytes = target.data!.assumingMemoryBound(to: UInt8.self)
        let left = 2 * target.bytesPerRow + 2 * 4
        let right = 2 * target.bytesPerRow + 5 * 4
        let original = baseline.data!.assumingMemoryBound(to: UInt8.self)
        for channel in 0..<4 {
            precondition(bytes[left + channel] == original[right + channel], "Left should match the original right")
            precondition(bytes[right + channel] == original[left + channel], "Right should match the original left")
        }
        precondition(bytes[0 + 3] == 0, "Pixels outside the bubble remain transparent")
        print("Camera appearance checks passed (shape, persistence, orientation, clipped rendering).")
    }

    static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}
