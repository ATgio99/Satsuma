import CoreGraphics
import Foundation
import SwiftUI

/// Wheel geometry shared by the app and the original app's own web demo:
/// inner 48·0.8·1.1 + 8·0.8, outer 166·0.8·0.9, backdrop outer + 6.4, gap 4, corner 20.16, labels from radius 40.
enum PetalGeometry {
    static let innerRadius: CGFloat = 48 * 0.8 * 1.1 + 8 * 0.8          // 48.64
    static let outerRadius: CGFloat = 166 * 0.8 * 0.9                    // 119.52
    static let backdropRadius: CGFloat = outerRadius + 8 * 0.8           // 125.92
    static let backdropHoleRadius: CGFloat = 42.24
    static let gap: CGFloat = 5 * 0.8                                    // 4
    static let corner: CGFloat = 28 * 0.8 * 0.9                          // 20.16
    static let labelInnerRadius: CGFloat = 50 * 0.8                      // 40
    static let labelRadiusFactor: CGFloat = 0.56
    static let introOuterRadius: CGFloat = 50.4

    /// Center angle of petal `slot` among `count` (top first, clockwise; three petals start at π).
    static func centerAngle(slot: Int, count: Int) -> CGFloat {
        (count == 3 ? .pi : .pi / 2) - 2 * .pi * CGFloat(slot) / CGFloat(max(count, 1))
    }

    static func sectorAngle(count: Int) -> CGFloat { 2 * .pi / CGFloat(max(count, 1)) }

    /// Angular half-gap that keeps the petal edges 2 pt away from the boundary ray at radius `r`.
    static func gapAngle(at radius: CGFloat) -> CGFloat {
        asin(min(0.95, gap / 2 / max(radius, gap / 2 + 0.01)))
    }

    static var labelRadius: CGFloat { labelInnerRadius + (outerRadius - labelInnerRadius) * labelRadiusFactor }

    /// Point at `radius`/`angle` in y-down view coordinates around `center`.
    static func point(_ radius: CGFloat, _ angle: CGFloat, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
    }

    /// Label center in y-down coordinates.
    static func labelCenter(center: CGPoint, angle: CGFloat) -> CGPoint {
        point(labelRadius, angle, center: center)
    }

    /// Rounded annular sector (y-down). Straight sides run parallel to the boundary rays.
    static func petalPath(center: CGPoint, slot: Int, count: Int,
                          inner: CGFloat = innerRadius, outer: CGFloat = outerRadius) -> CGPath {
        let a = centerAngle(slot: slot, count: count)
        let n = sectorAngle(count: count)
        let l = a - n / 2, s = a + n / 2
        let r = gapAngle(at:)
        let d = l + r(outer), i = s - r(outer)
        let c = l + r(inner), g = s - r(inner)
        let f = min(0.15, (i - d) * 0.24)
        let u = min(0.18, (g - c) * 0.18)
        let v = inner / max(0.01, cos(u))
        let y = v + inner * tan(u)
        let o = outer - corner
        func p(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint { point(radius, angle, center: center) }

        let path = CGMutablePath()
        path.move(to: p(y, l + r(y)))
        path.addLine(to: p(o, l + r(o)))
        path.addQuadCurve(to: p(outer, d + f), control: p(outer, d))
        // y-down: decreasing math angle goes clockwise on screen.
        path.addArc(center: center, radius: outer, startAngle: -(d + f), endAngle: -(i - f), clockwise: true)
        path.addQuadCurve(to: p(o, s - r(o)), control: p(outer, i))
        path.addLine(to: p(y, s - r(y)))
        path.addQuadCurve(to: p(inner, g - u), control: p(v, s - r(v)))
        path.addArc(center: center, radius: inner, startAngle: -(g - u), endAngle: -(c + u), clockwise: false)
        path.addQuadCurve(to: p(y, l + r(y)), control: p(v, l + r(v)))
        path.closeSubpath()
        return path
    }

    /// Slot under a point (y-down offset from the wheel center), or nil in gaps/hub/outside.
    static func slot(atOffset dx: CGFloat, _ dy: CGFloat, count: Int) -> Int? {
        let distance = hypot(dx, dy)
        guard count > 0, distance >= innerRadius, distance <= outerRadius else { return nil }
        let angle = atan2(-dy, dx)
        let sector = sectorAngle(count: count)
        let twoPi = 2 * CGFloat.pi
        let relative = ((centerAngle(slot: 0, count: count) - angle).truncatingRemainder(dividingBy: twoPi) + twoPi)
            .truncatingRemainder(dividingBy: twoPi)
        let index = Int((relative / sector).rounded()) % count
        let delta = angle - centerAngle(slot: index, count: count)
        let wrapped = abs(atan2(sin(delta), cos(delta)))
        return wrapped > sector / 2 - asin(gap / 2 / distance) ? nil : index
    }
}

/// SwiftUI shape for one petal, in its own frame (center = frame center).
struct PetalShape: Shape {
    var slot: Int
    var count: Int
    var outer: CGFloat = PetalGeometry.outerRadius

    func path(in rect: CGRect) -> Path {
        Path(PetalGeometry.petalPath(center: CGPoint(x: rect.midX, y: rect.midY), slot: slot, count: count, outer: outer))
    }
}

/// Backdrop ring behind the petals (hole radius 42.24).
struct RingShape: Shape {
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(center: center, radius: outer, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .degrees(360), endAngle: .zero, clockwise: true)
        return path
    }
}
