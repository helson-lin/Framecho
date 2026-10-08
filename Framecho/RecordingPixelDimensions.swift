import CoreGraphics

/// The encoder's pixel dimensions, shared by source labels and capture setup.
nonisolated struct RecordingPixelDimensions: Equatable, Sendable {
    let width: Int
    let height: Int

    init(sourceSize: CGSize, pointPixelScale: CGFloat) {
        let scale = max(1, pointPixelScale)
        width = max(2, Int((sourceSize.width * scale).rounded(.toNearestOrAwayFromZero)))
        height = max(2, Int((sourceSize.height * scale).rounded(.toNearestOrAwayFromZero)))
    }

    var label: String { "\(width)×\(height)" }
}
