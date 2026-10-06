//
//  ProjectiveHomography.swift
//  Framecho
//

import CoreGraphics
import QuartzCore
import SwiftUI

/// A plane-to-plane projective mapping. Shared by the screenshot camera and
/// the video card projection so preview, hit-testing and export agree.
nonisolated struct ProjectiveHomography: Equatable, Sendable {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let d: CGFloat
    let e: CGFloat
    let f: CGFloat
    let g: CGFloat
    let h: CGFloat
    let i: CGFloat

    static let identity = ProjectiveHomography(
        a: 1, b: 0, c: 0,
        d: 0, e: 1, f: 0,
        g: 0, h: 0, i: 1
    )

    static func mapping(
        _ sourceRect: CGRect,
        topLeft p0: CGPoint,
        topRight p1: CGPoint,
        bottomRight p2: CGPoint,
        bottomLeft p3: CGPoint
    ) -> ProjectiveHomography? {
        guard sourceRect.width > 0, sourceRect.height > 0 else { return nil }

        let dx1 = p1.x - p2.x
        let dx2 = p3.x - p2.x
        let dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y
        let dy2 = p3.y - p2.y
        let dy3 = p0.y - p1.y + p2.y - p3.y

        let unit: ProjectiveHomography
        let denominator = dx1 * dy2 - dx2 * dy1
        if abs(dx3) < 0.000001 && abs(dy3) < 0.000001 {
            unit = ProjectiveHomography(
                a: p1.x - p0.x,
                b: p3.x - p0.x,
                c: p0.x,
                d: p1.y - p0.y,
                e: p3.y - p0.y,
                f: p0.y,
                g: 0,
                h: 0,
                i: 1
            )
        } else {
            guard abs(denominator) > 0.000001 else { return nil }
            let projectiveX = (dx3 * dy2 - dx2 * dy3) / denominator
            let projectiveY = (dx1 * dy3 - dx3 * dy1) / denominator
            unit = ProjectiveHomography(
                a: p1.x - p0.x + projectiveX * p1.x,
                b: p3.x - p0.x + projectiveY * p3.x,
                c: p0.x,
                d: p1.y - p0.y + projectiveX * p1.y,
                e: p3.y - p0.y + projectiveY * p3.y,
                f: p0.y,
                g: projectiveX,
                h: projectiveY,
                i: 1
            )
        }

        let inverseWidth = 1 / sourceRect.width
        let inverseHeight = 1 / sourceRect.height
        return ProjectiveHomography(
            a: unit.a * inverseWidth,
            b: unit.b * inverseHeight,
            c: unit.c - unit.a * sourceRect.minX * inverseWidth - unit.b * sourceRect.minY * inverseHeight,
            d: unit.d * inverseWidth,
            e: unit.e * inverseHeight,
            f: unit.f - unit.d * sourceRect.minX * inverseWidth - unit.e * sourceRect.minY * inverseHeight,
            g: unit.g * inverseWidth,
            h: unit.h * inverseHeight,
            i: unit.i - unit.g * sourceRect.minX * inverseWidth - unit.h * sourceRect.minY * inverseHeight
        )
    }

    func applying(to point: CGPoint) -> CGPoint {
        let denominator = g * point.x + h * point.y + i
        guard abs(denominator) > 0.000001 else { return point }
        return CGPoint(
            x: (a * point.x + b * point.y + c) / denominator,
            y: (d * point.x + e * point.y + f) / denominator
        )
    }

    func inverted() -> ProjectiveHomography? {
        let determinant = a * (e * i - f * h)
            - b * (d * i - f * g)
            + c * (d * h - e * g)
        guard abs(determinant) > 0.000001 else { return nil }
        let reciprocal = 1 / determinant
        return ProjectiveHomography(
            a: (e * i - f * h) * reciprocal,
            b: (c * h - b * i) * reciprocal,
            c: (b * f - c * e) * reciprocal,
            d: (f * g - d * i) * reciprocal,
            e: (a * i - c * g) * reciprocal,
            f: (c * d - a * f) * reciprocal,
            g: (d * h - e * g) * reciprocal,
            h: (b * g - a * h) * reciprocal,
            i: (a * e - b * d) * reciprocal
        )
    }

    /// Row-vector layout used by Core Animation and SwiftUI.
    var caTransform: CATransform3D {
        CATransform3D(
            m11: a, m12: d, m13: 0, m14: g,
            m21: b, m22: e, m23: 0, m24: h,
            m31: 0, m32: 0, m33: 1, m34: 0,
            m41: c, m42: f, m43: 0, m44: i
        )
    }

    var projectionTransform: ProjectionTransform {
        ProjectionTransform(caTransform)
    }
}
