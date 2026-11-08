import Testing
import CoreGraphics
@testable import NoteGuard

@Suite("Shape recognition")
struct ShapeRecognizerTests {
    @Test func roughRectangleSnapsToAxisAlignedRectangle() throws {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 300), CGPoint(x: 100, y: 300)]
        let shape = try #require(ShapeRecognizer.recognize(roughPath(corners, closed: true)))
        guard case let .polygon(points) = shape else { Issue.record("expected a polygon, got \(shape)"); return }
        #expect(points.count == 4)
        let xs = Set(points.map { Int($0.x.rounded()) }), ys = Set(points.map { Int($0.y.rounded()) })
        #expect(xs.count == 2 && ys.count == 2, "a snapped rectangle has exactly two distinct x and y values")
    }

    @Test func roughCircleSnapsToCircle() throws {
        let points = (0...64).map { i -> CGPoint in
            let t = CGFloat(i) / 64 * 2 * .pi
            let r = 120 + sin(t * 5) * 3
            return CGPoint(x: 300 + r * cos(t), y: 300 + r * sin(t))
        }
        let shape = try #require(ShapeRecognizer.recognize(points))
        guard case let .ellipse(rect) = shape else { Issue.record("expected an ellipse, got \(shape)"); return }
        #expect(abs(rect.width - rect.height) < 1, "near-round shapes snap to a true circle")
        #expect(abs(rect.midX - 300) < 6 && abs(rect.midY - 300) < 6)
    }

    @Test func roughTriangleSnapsToTriangle() throws {
        let corners = [CGPoint(x: 250, y: 80), CGPoint(x: 420, y: 360), CGPoint(x: 80, y: 360)]
        let shape = try #require(ShapeRecognizer.recognize(roughPath(corners, closed: true)))
        guard case let .polygon(points) = shape else { Issue.record("expected a polygon, got \(shape)"); return }
        #expect(points.count == 3)
    }

    @Test func nearlyStraightStrokeSnapsToLine() throws {
        let shape = try #require(ShapeRecognizer.recognize(roughPath([CGPoint(x: 50, y: 50), CGPoint(x: 450, y: 260)], closed: false)))
        guard case let .line(a, b) = shape else { Issue.record("expected a line, got \(shape)"); return }
        #expect(hypot(a.x - 50, a.y - 50) < 5)
        #expect(hypot(b.x - 450, b.y - 260) < 5)
    }

    @Test func tinyStrokesAreLeftAlone() {
        #expect(ShapeRecognizer.recognize(roughPath([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 8)], closed: false, spacing: 1)) == nil)
    }

    @Test func handwritingIsLeftAlone() {
        // A long wavy line, like cursive: no clean shape.
        let wave = (0...200).map { i in CGPoint(x: CGFloat(i) * 3, y: 200 + sin(CGFloat(i) * 0.35) * 30) }
        #expect(ShapeRecognizer.recognize(wave) == nil)
    }
}

