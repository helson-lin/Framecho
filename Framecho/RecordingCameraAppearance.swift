import CoreGraphics
import Foundation

nonisolated enum RecordingCameraShape: String, CaseIterable, Sendable {
    case circle
    case square

    var roundness: Double {
        switch self {
        case .circle: 0.5
        case .square: 0.12
        }
    }
}

/// Appearance is applied to the already-mirrored camera master, keeping
/// existing recordings unchanged and allowing reversible Studio edits.
nonisolated struct RecordingCameraAppearance: Codable, Equatable, Sendable {
    var roundness: Double = 0.5
    var isFlipped = false

    var shape: RecordingCameraShape {
        get { roundness >= 0.5 ? .circle : .square }
        set { roundness = newValue.roundness }
    }

    func transform(in rect: CGRect) -> CGAffineTransform {
        isFlipped
            ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.midX * 2, ty: 0)
            : .identity
    }
}
