//
//  AnnotationCameraGeometry.swift
//  Framecho
//

import CoreGraphics
import QuartzCore
import SwiftUI

nonisolated struct AnnotationCameraQuad {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    var points: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }
}

nonisolated struct AnnotationCameraProjection {
    let quad: AnnotationCameraQuad

    private let forward: ProjectiveHomography
    private let inverse: ProjectiveHomography

    fileprivate init(
        sourceRect: CGRect,
        quad: AnnotationCameraQuad
    ) {
        if let transform = ProjectiveHomography.mapping(
            sourceRect,
            topLeft: quad.topLeft,
            topRight: quad.topRight,
            bottomRight: quad.bottomRight,
            bottomLeft: quad.bottomLeft
           ),
           let inverted = transform.inverted() {
            self.quad = quad
            forward = transform
            inverse = inverted
        } else {
            // Preview hit-testing and export must fail as one unit. Keeping a
            // transformed quad with identity homographies would make them render
            // and interact with different geometry.
            self.quad = AnnotationCameraQuad(
                topLeft: CGPoint(x: sourceRect.minX, y: sourceRect.minY),
                topRight: CGPoint(x: sourceRect.maxX, y: sourceRect.minY),
                bottomRight: CGPoint(x: sourceRect.maxX, y: sourceRect.maxY),
                bottomLeft: CGPoint(x: sourceRect.minX, y: sourceRect.maxY)
            )
            forward = .identity
            inverse = .identity
        }
    }

    var swiftUITransform: ProjectionTransform {
        forward.projectionTransform
    }

    func project(_ point: CGPoint) -> CGPoint {
        forward.applying(to: point)
    }

    func unproject(_ point: CGPoint) -> CGPoint {
        inverse.applying(to: point)
    }
}

nonisolated enum AnnotationCameraGeometry {
    static func projection(
        sourceRect: CGRect,
        imageRect: CGRect,
        canvasSize: CGSize,
        settings: AnnotationCameraSettings
    ) -> AnnotationCameraProjection {
        guard sourceRect.width > 0,
              sourceRect.height > 0,
              imageRect.width > 0,
              imageRect.height > 0 else {
            return AnnotationCameraProjection(
                sourceRect: sourceRect,
                quad: quad(for: sourceRect)
            )
        }

        let pivot = CGPoint(x: imageRect.midX, y: imageRect.midY)
        let scale: CGFloat
        if settings.projectionVersion < 2 {
            let rawImageCorners = corners(of: imageRect).map {
                legacyProjectedPoint($0, pivot: pivot, imageRect: imageRect, settings: settings)
            }
            let rawBounds = boundingRect(rawImageCorners)
            let fitScale = min(
                1,
                imageRect.width / max(rawBounds.width, 1),
                imageRect.height / max(rawBounds.height, 1)
            )
            scale = fitScale * min(max(settings.zoom, 0.4), 2.5)
        } else {
            // Zoom is the only framing scale in the current model. Do not
            // silently shrink the card as its angle changes.
            scale = min(max(settings.zoom, 0.4), 2.5)
        }
        let pan = CGSize(
            width: settings.panX * canvasSize.width,
            height: settings.panY * canvasSize.height
        )

        func projected(_ point: CGPoint) -> CGPoint {
            let rawPoint = if settings.projectionVersion < 2 {
                legacyProjectedPoint(
                    point,
                    pivot: pivot,
                    imageRect: imageRect,
                    settings: settings
                )
            } else {
                currentProjectedPoint(
                    point,
                    pivot: pivot,
                    imageRect: imageRect,
                    settings: settings
                )
            }
            return CGPoint(
                x: pivot.x + (rawPoint.x - pivot.x) * scale + pan.width,
                y: pivot.y + (rawPoint.y - pivot.y) * scale + pan.height
            )
        }

        let sourceCorners = corners(of: sourceRect)
        let destinationQuad = AnnotationCameraQuad(
            topLeft: projected(sourceCorners[0]),
            topRight: projected(sourceCorners[1]),
            bottomRight: projected(sourceCorners[2]),
            bottomLeft: projected(sourceCorners[3])
        )
        return AnnotationCameraProjection(sourceRect: sourceRect, quad: destinationQuad)
    }

    private static func currentProjectedPoint(
        _ point: CGPoint,
        pivot: CGPoint,
        imageRect: CGRect,
        settings: AnnotationCameraSettings
    ) -> CGPoint {
        var vector = Vector3(
            x: point.x - pivot.x,
            y: point.y - pivot.y,
            z: 0
        )

        // Rotate turns the card around its local center axes.
        vector = rotatedAroundX(vector, by: radians(settings.rotationXDegrees))
        vector = rotatedAroundY(vector, by: radians(settings.rotationYDegrees))

        // Tilt orbits the camera horizontally/vertically around the same
        // center. Applying the inverse world rotations to the card plane gives
        // the exact pinhole-camera view while remaining one invertible plane.
        vector = rotatedAroundY(vector, by: -radians(settings.tiltXDegrees))
        vector = rotatedAroundX(vector, by: -radians(settings.tiltYDegrees))

        return perspectivePoint(
            vector,
            pivot: pivot,
            imageRect: imageRect,
            fieldOfViewDegrees: settings.fieldOfViewDegrees,
            rollDegrees: settings.rollDegrees
        )
    }

    /// Version 1 compatibility for saved development presets/documents.
    private static func legacyProjectedPoint(
        _ point: CGPoint,
        pivot: CGPoint,
        imageRect: CGRect,
        settings: AnnotationCameraSettings
    ) -> CGPoint {
        var vector = Vector3(
            x: point.x - pivot.x,
            y: point.y - pivot.y,
            z: 0
        )

        vector = rotatedAroundX(vector, by: radians(settings.rotationXDegrees))
        vector = rotatedAroundY(vector, by: radians(settings.rotationYDegrees))

        let tiltX = tan(radians(settings.tiltXDegrees)) * 0.42
        let tiltY = tan(radians(settings.tiltYDegrees)) * 0.42
        let tiltedX = vector.x + vector.y * tiltY
        let tiltedY = vector.y + vector.x * tiltX
        vector.x = tiltedX
        vector.y = tiltedY

        return perspectivePoint(
            vector,
            pivot: pivot,
            imageRect: imageRect,
            fieldOfViewDegrees: settings.fieldOfViewDegrees,
            rollDegrees: settings.rollDegrees
        )
    }

    private static func perspectivePoint(
        _ vector: Vector3,
        pivot: CGPoint,
        imageRect: CGRect,
        fieldOfViewDegrees: CGFloat,
        rollDegrees: CGFloat
    ) -> CGPoint {
        let fov = min(max(fieldOfViewDegrees, 18), 80)
        let longestEdge = max(imageRect.width, imageRect.height)
        let focalDistance = longestEdge * (
            0.35 + 0.5 / max(tan(radians(fov) / 2), 0.01)
        )
        let denominator = max(focalDistance - vector.z, focalDistance * 0.12)
        let perspectiveScale = focalDistance / denominator
        let x = vector.x * perspectiveScale
        let y = vector.y * perspectiveScale

        let roll = radians(rollDegrees)
        let rolledX = x * cos(roll) - y * sin(roll)
        let rolledY = x * sin(roll) + y * cos(roll)
        return CGPoint(x: pivot.x + rolledX, y: pivot.y + rolledY)
    }

    private static func radians(_ degrees: CGFloat) -> CGFloat {
        degrees * .pi / 180
    }

    private static func rotatedAroundX(_ vector: Vector3, by angle: CGFloat) -> Vector3 {
        Vector3(
            x: vector.x,
            y: vector.y * cos(angle) - vector.z * sin(angle),
            z: vector.y * sin(angle) + vector.z * cos(angle)
        )
    }

    private static func rotatedAroundY(_ vector: Vector3, by angle: CGFloat) -> Vector3 {
        Vector3(
            x: vector.x * cos(angle) + vector.z * sin(angle),
            y: vector.y,
            z: -vector.x * sin(angle) + vector.z * cos(angle)
        )
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private static func quad(for rect: CGRect) -> AnnotationCameraQuad {
        let points = corners(of: rect)
        return AnnotationCameraQuad(
            topLeft: points[0],
            topRight: points[1],
            bottomRight: points[2],
            bottomLeft: points[3]
        )
    }

    private static func boundingRect(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(
            CGRect(origin: first, size: .zero)
        ) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
    }

    private struct Vector3 {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat
    }
}
