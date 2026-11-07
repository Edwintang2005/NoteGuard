import UIKit
import PencilKit

/// A clean shape inferred from a rough hand-drawn stroke.
enum RecognizedShape {
    case line(CGPoint, CGPoint)
    /// Open path of straight segments (e.g. an angle or zig-zag).
    case polyline([CGPoint])
    /// Closed polygon: triangle, rectangle, quadrilateral, pentagon…
    case polygon([CGPoint])
    case ellipse(CGRect)

    /// Outline for previews.
    var path: UIBezierPath {
        let path = UIBezierPath()
        switch self {
        case let .line(a, b):
            path.move(to: a)
            path.addLine(to: b)
        case let .polyline(points):
            guard let first = points.first else { break }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
        case let .polygon(points):
            guard let first = points.first else { break }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
        case let .ellipse(rect):
            return UIBezierPath(ovalIn: rect)
        }
        return path
    }

    /// Points to feed PencilKit, densely sampled so its spline stays straight and corners stay sharp.
    var samplePoints: [CGPoint] {
        switch self {
        case let .line(a, b):
            return Self.densify([a, b], closed: false)
        case let .polyline(points):
            return Self.densify(points, closed: false)
        case let .polygon(points):
            return Self.densify(points, closed: true)
        case let .ellipse(rect):
            let steps = 96
            return (0...steps).map { i in
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi - .pi / 2
                return CGPoint(x: rect.midX + rect.width / 2 * cos(t), y: rect.midY + rect.height / 2 * sin(t))
            }
        }
    }

    private static func densify(_ corners: [CGPoint], closed: Bool, spacing: CGFloat = 3) -> [CGPoint] {
        guard corners.count >= 2 else { return corners }
        let vertices = closed ? corners + [corners[0]] : corners
        var out: [CGPoint] = []
        for i in 0..<(vertices.count - 1) {
            let a = vertices[i], b = vertices[i + 1]
            // Repeating a corner pins the B-spline to it, keeping the corner sharp.
            out.append(contentsOf: [a, a, a])
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / spacing))
            for s in 1..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        let last = vertices[vertices.count - 1]
        out.append(contentsOf: [last, last, last])
        return out
    }

    /// Builds a PencilKit stroke for this shape, borrowing ink and point style from the user's stroke.
    func stroke(styledLike template: PKStroke) -> PKStroke {
        let templatePoints = Array(template.path)
        let style = templatePoints.isEmpty ? nil : templatePoints[templatePoints.count / 2]
        let size = style?.size ?? CGSize(width: 3, height: 3)
        let points = samplePoints.enumerated().map { i, location in
            PKStrokePoint(location: location,
                          timeOffset: TimeInterval(i) * 0.005,
                          size: size,
                          opacity: style?.opacity ?? 1,
                          force: style?.force ?? 1,
                          azimuth: style?.azimuth ?? 0,
                          altitude: style?.altitude ?? .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: template.path.creationDate)
        // Sample points are already in canvas space, so no extra transform.
        return PKStroke(ink: template.ink, path: path, transform: .identity, mask: nil)
    }
}

/// Turns a rough stroke into a clean shape, or nil when it isn't confidently one.
enum ShapeRecognizer {
    static func recognize(_ raw: [CGPoint]) -> RecognizedShape? {
        let points = dedupe(raw)
        guard points.count >= 5, let first = points.first, let last = points.last else { return nil }
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal >= 24 else { return nil }

        let gap = distance(first, last)
        let isClosed = gap < max(0.22 * diagonal, 24) && pathLength(points) > 1.6 * diagonal

        if !isClosed {
            // A straight line?
            let chord = distance(first, last)
            let deviation = points.map { distanceToSegment($0, first, last) }.max() ?? 0
            if chord > 20, deviation < max(0.07 * chord, 5) { return .line(first, last) }
            // A few straight segments (an angle, a zig-zag)?
            let simplified = rdp(points, epsilon: 0.06 * diagonal)
            if simplified.count >= 3, simplified.count <= 5 { return .polyline(simplified) }
            return nil
        }

        // Closed: circle/ellipse or polygon.
        let ring = gap < 1 ? Array(points.dropLast()) : points
        let ellipseError = meanEllipseError(ring, in: box)
        if ellipseError < 0.09 { return .ellipse(snapCircle(box)) }

        let corners = mergeClose(rdpClosed(ring, epsilon: 0.08 * diagonal), minimum: 0.12 * diagonal)
        switch corners.count {
        case 3:
            return .polygon(corners)
        case 4:
            return .polygon(isAxisAlignedRectangle(corners) ? rectangleCorners(boundingBox(corners)) : corners)
        case 5, 6:
            return .polygon(corners)
        default:
            return ellipseError < 0.2 ? .ellipse(snapCircle(box)) : nil
        }
    }

    // MARK: Geometry helpers

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func dedupe(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points where out.last.map({ distance($0, p) >= 1 }) ?? true { out.append(p) }
        return out
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Ramer–Douglas–Peucker simplification of an open path.
    private static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var index = 0
        var maxDistance: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let d = distanceToSegment(points[i], first, last)
            if d > maxDistance { maxDistance = d; index = i }
        }
        guard maxDistance > epsilon else { return [first, last] }
        let left = rdp(Array(points[...index]), epsilon: epsilon)
        let right = rdp(Array(points[index...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    /// RDP for a closed ring: split at the point farthest from the start and simplify both halves.
    private static func rdpClosed(_ ring: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard ring.count > 3, let start = ring.first else { return ring }
        let far = ring.indices.max { distance(ring[$0], start) < distance(ring[$1], start) } ?? 0
        let a = rdp(Array(ring[...far]), epsilon: epsilon)
        let b = rdp(Array(ring[far...]) + [start], epsilon: epsilon)
        return Array(a.dropLast() + b.dropLast())
    }

    /// Merges corners closer than `minimum`, including the wrap-around pair.
    private static func mergeClose(_ corners: [CGPoint], minimum: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for c in corners where out.last.map({ distance($0, c) >= minimum }) ?? true { out.append(c) }
        if out.count > 2, let first = out.first, let last = out.last, distance(first, last) < minimum { out.removeLast() }
        return out
    }

    /// Mean |normalised radius − 1| against the ellipse inscribed in the bounding box.
    private static func meanEllipseError(_ points: [CGPoint], in box: CGRect) -> CGFloat {
        let rx = box.width / 2, ry = box.height / 2
        guard rx > 0, ry > 0, !points.isEmpty else { return .infinity }
        let total = points.reduce(CGFloat(0)) { sum, p in
            let dx = (p.x - box.midX) / rx, dy = (p.y - box.midY) / ry
            return sum + abs(sqrt(dx * dx + dy * dy) - 1)
        }
        return total / CGFloat(points.count)
    }

    /// Nearly-round ellipses snap to a true circle.
    private static func snapCircle(_ box: CGRect) -> CGRect {
        let ratio = box.width / max(box.height, 1)
        guard ratio > 0.85, ratio < 1.18 else { return box }
        let side = (box.width + box.height) / 2
        return CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
    }

    private static func isAxisAlignedRectangle(_ corners: [CGPoint]) -> Bool {
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let angle = abs(atan2(b.y - a.y, b.x - a.x)) // 0…π
            let offAxis = min(angle, abs(angle - .pi / 2), abs(angle - .pi))
            if offAxis > 0.26 { return false } // ~15°
        }
        return true
    }

    private static func rectangleCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
}
