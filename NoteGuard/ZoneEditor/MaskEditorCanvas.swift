import UIKit
import SwiftUI
import Combine

final class EditorState: ObservableObject {
    @Published var tool: DeadZoneShape.Kind = .freehand
    @Published var selectedID: UUID?
}

/// Full-screen surface for drawing, moving and resizing dead zones directly over the glass.
///
/// - Rectangle / Ellipse: drag on empty space to draw one.
/// - Freehand: trace any outline around the crack; it closes automatically when you lift.
/// - Drag a zone to move it; drag a corner handle of the selected zone to resize it.
///
/// Only the first touch is tracked, so phantom touches from the crack can't hijack an edit.
final class MaskEditorCanvas: UIView {
    private let store: DeadZoneStore
    private let editor: EditorState
    private var cancellables = Set<AnyCancellable>()

    /// A zone's geometry in this view's coordinates. `points` is empty for rectangles/ellipses.
    private struct LocalGeometry {
        var rect: CGRect
        var points: [CGPoint]
    }

    private enum Drag {
        case creating(start: CGPoint, current: CGPoint)
        case tracing(points: [CGPoint])
        case moving(id: UUID, startTouch: CGPoint, original: LocalGeometry)
        case resizing(id: UUID, anchor: CGPoint, original: LocalGeometry)
    }

    private var drag: Drag?
    private var activeTouch: UITouch?

    private let handleRadius: CGFloat = 11
    private let handleHitRadius: CGFloat = 32
    private let minimumSize: CGFloat = 16
    private let traceSpacing: CGFloat = 3

    init(store: DeadZoneStore, editor: EditorState) {
        self.store = store
        self.editor = editor
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        contentMode = .redraw
        isMultipleTouchEnabled = true

        store.objectWillChange.sink { [weak self] _ in self?.setNeedsDisplay() }.store(in: &cancellables)
        editor.objectWillChange.sink { [weak self] _ in self?.setNeedsDisplay() }.store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    // MARK: Coordinate helpers

    private var fixedSpace: UICoordinateSpace? { window?.windowScene?.screen.fixedCoordinateSpace }

    private func localGeometry(of shape: DeadZoneShape) -> LocalGeometry? {
        guard let space = fixedSpace else { return nil }
        let size = space.bounds.size
        if shape.kind == .freehand {
            let pts = shape.points(in: size).map { space.convert($0, to: self) }
            return LocalGeometry(rect: DeadZoneShape.boundingBox(of: pts), points: pts)
        }
        return LocalGeometry(rect: space.convert(shape.rect(in: size), to: self), points: [])
    }

    /// Converts local geometry back to normalised fixed-space values.
    private func normalized(_ g: LocalGeometry, kind: DeadZoneShape.Kind) -> (rect: CGRect, points: [CGPoint]?)? {
        guard let space = fixedSpace else { return nil }
        let size = space.bounds.size
        if kind == .freehand {
            let fixed = g.points.map { convert($0, to: space) }
            return (DeadZoneShape.normalize(DeadZoneShape.boundingBox(of: fixed), in: size),
                    fixed.map { DeadZoneShape.normalize($0, in: size) })
        }
        return (DeadZoneShape.normalize(convert(g.rect, to: space), in: size), nil)
    }

    private func commit(_ id: UUID, _ g: LocalGeometry) {
        guard let kind = store.shapes.first(where: { $0.id == id })?.kind,
              let n = normalized(g, kind: kind) else { return }
        store.updateGeometry(id, normalizedRect: n.rect, normalizedPoints: n.points)
    }

    private func addShape(kind: DeadZoneShape.Kind, _ g: LocalGeometry) {
        guard g.rect.width >= minimumSize, g.rect.height >= minimumSize,
              kind != .freehand || g.points.count >= 3,
              let n = normalized(g, kind: kind) else { return }
        let shape = DeadZoneShape(kind: kind, normalizedRect: n.rect, normalizedPoints: n.points)
        store.shapes.append(shape)
        editor.selectedID = shape.id
    }

    /// Re-maps geometry into a new bounding box (scales freehand points with it).
    private static func remap(_ g: LocalGeometry, to r1: CGRect) -> LocalGeometry {
        let r0 = g.rect
        let pts = g.points.map { p in
            CGPoint(x: r1.minX + (r0.width > 0 ? (p.x - r0.minX) / r0.width : 0) * r1.width,
                    y: r1.minY + (r0.height > 0 ? (p.y - r0.minY) / r0.height : 0) * r1.height)
        }
        return LocalGeometry(rect: r1, points: pts)
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private static func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func isHit(_ shape: DeadZoneShape, at p: CGPoint) -> Bool {
        guard let space = fixedSpace else { return false }
        let path = shape.path(from: space, to: self).cgPath
        // Also accept touches just on the outline, so thin freehand zones are easy to grab.
        return path.contains(p) || DeadZoneShape.outlineBand(of: path, distance: 12).contains(p)
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        let p = touch.location(in: self)

        // 1. A corner handle of the selected zone → resize, anchored on the opposite corner.
        if let id = editor.selectedID,
           let shape = store.shapes.first(where: { $0.id == id }),
           let g = localGeometry(of: shape) {
            let corners = Self.corners(of: g.rect)
            if let i = corners.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= handleHitRadius }) {
                drag = .resizing(id: id, anchor: corners[3 - i], original: g)
                return
            }
        }

        // 2. On a zone (topmost first) → select and move.
        for shape in store.shapes.reversed() where isHit(shape, at: p) {
            guard let g = localGeometry(of: shape) else { continue }
            editor.selectedID = shape.id
            drag = .moving(id: shape.id, startTouch: p, original: g)
            return
        }

        // 3. Empty space → start a new zone.
        editor.selectedID = nil
        drag = editor.tool == .freehand ? .tracing(points: [p]) : .creating(start: p, current: p)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let drag else { return }
        let p = touch.location(in: self)

        switch drag {
        case let .creating(start, _):
            self.drag = .creating(start: start, current: p)
            setNeedsDisplay()
        case var .tracing(points):
            if let last = points.last, hypot(last.x - p.x, last.y - p.y) >= traceSpacing {
                points.append(p)
                self.drag = .tracing(points: points)
                setNeedsDisplay()
            }
        case let .moving(id, startTouch, original):
            let dx = p.x - startTouch.x, dy = p.y - startTouch.y
            commit(id, LocalGeometry(rect: original.rect.offsetBy(dx: dx, dy: dy),
                                     points: original.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }))
        case let .resizing(id, anchor, original):
            var r = Self.rect(from: anchor, to: p)
            r.size.width = max(r.width, minimumSize)
            r.size.height = max(r.height, minimumSize)
            commit(id, Self.remap(original, to: r))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        switch drag {
        case let .creating(start, _):
            addShape(kind: editor.tool, LocalGeometry(rect: Self.rect(from: start, to: touch.location(in: self)), points: []))
        case let .tracing(points):
            addShape(kind: .freehand, LocalGeometry(rect: DeadZoneShape.boundingBox(of: points), points: points))
        default:
            break
        }
        finishDrag()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        finishDrag()
    }

    private func finishDrag() {
        drag = nil
        activeTouch = nil
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        drawGrid()
        guard let space = fixedSpace else { return }

        for shape in store.shapes {
            let selected = shape.id == editor.selectedID
            let tint: UIColor = selected ? .systemBlue : .systemRed
            let body = shape.path(from: space, to: self)

            tint.withAlphaComponent(0.25).setFill()
            body.fill()
            tint.setStroke()
            body.lineWidth = selected ? 2.5 : 1.5
            body.lineJoinStyle = .round
            body.stroke()

            if selected, let g = localGeometry(of: shape) {
                if shape.kind == .freehand {
                    let box = UIBezierPath(rect: g.rect)
                    box.setLineDash([4, 4], count: 2, phase: 0)
                    box.lineWidth = 1
                    UIColor.systemBlue.withAlphaComponent(0.6).setStroke()
                    box.stroke()
                }
                for c in Self.corners(of: g.rect) {
                    let handle = UIBezierPath(ovalIn: CGRect(x: c.x - handleRadius, y: c.y - handleRadius,
                                                             width: handleRadius * 2, height: handleRadius * 2))
                    UIColor.white.setFill()
                    handle.fill()
                    UIColor.systemBlue.setStroke()
                    handle.lineWidth = 2
                    handle.stroke()
                }
            }
        }

        drawCreationPreview()

        if store.shapes.isEmpty, drag == nil {
            drawHint("Trace around the cracked area to mask it")
        }
    }

    private func drawCreationPreview() {
        let preview: UIBezierPath
        switch drag {
        case let .creating(start, current):
            let r = Self.rect(from: start, to: current)
            preview = editor.tool == .ellipse ? UIBezierPath(ovalIn: r) : UIBezierPath(rect: r)
        case let .tracing(points):
            preview = UIBezierPath(cgPath: DeadZoneShape.polygon(points))
        default:
            return
        }
        UIColor.systemRed.withAlphaComponent(0.15).setFill()
        preview.fill()
        preview.setLineDash([6, 4], count: 2, phase: 0)
        preview.lineWidth = 2
        preview.lineJoinStyle = .round
        UIColor.systemRed.setStroke()
        preview.stroke()
    }

    private func drawGrid() {
        let spacing: CGFloat = 40
        let grid = UIBezierPath()
        var x: CGFloat = 0
        while x <= bounds.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: bounds.height)); x += spacing }
        var y: CGFloat = 0
        while y <= bounds.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: bounds.width, y: y)); y += spacing }
        grid.lineWidth = 0.5
        UIColor.separator.setStroke()
        grid.stroke()
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .title3),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}

struct MaskEditorCanvasView: UIViewRepresentable {
    let store: DeadZoneStore
    let editor: EditorState

    func makeUIView(context: Context) -> MaskEditorCanvas { MaskEditorCanvas(store: store, editor: editor) }
    func updateUIView(_ uiView: MaskEditorCanvas, context: Context) {}
}
