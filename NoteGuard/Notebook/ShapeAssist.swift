import UIKit
import PencilKit
import os

private let shapeLog = Logger(subsystem: "NoteGuard", category: "Shapes")

/// Draw-and-hold shape snapping for one canvas, like Markup in the Files app.
///
/// Draw a rough shape and keep the stylus/finger still for a moment at the end: a preview of the
/// clean shape appears. Lift to replace the stroke with it, or keep moving to cancel. Undo once
/// to get the freehand stroke back.
final class ShapeAssist: NSObject {
    private weak var canvas: PKCanvasView?
    private var points: [CGPoint] = []
    private var anchor: CGPoint = .zero
    private var holdTimer: Timer?
    private var recognized: RecognizedShape?
    /// Set when a recognised stroke has ended; applied once PencilKit commits the stroke.
    private var pendingShape: RecognizedShape?
    private var strokeCountAtStart = 0
    private let preview = CAShapeLayer()

    private let holdDuration: TimeInterval = 0.5
    /// Movement under this (points) still counts as holding still.
    private let stillTolerance: CGFloat = 4
    /// Moving further than this after a shape appears cancels it.
    private let cancelDistance: CGFloat = 14

    init(canvas: PKCanvasView) {
        self.canvas = canvas
        super.init()
        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(handleDrawing(_:)))
        preview.fillColor = nil
        preview.lineCap = .round
        preview.lineJoin = .round
        preview.isHidden = true
        canvas.layer.addSublayer(preview)
    }

    @objc private func handleDrawing(_ gesture: UIGestureRecognizer) {
        guard let canvas else { return }
        // Only pens/markers/pencils snap; erasers and lasso don't.
        guard canvas.tool is PKInkingTool else { reset(); return }
        // In drawing (page) coordinates: the canvas may be zoomed to render ink at screen resolution.
        let p = Self.drawingPoint(gesture.location(in: canvas), in: canvas)

        switch gesture.state {
        case .began:
            reset()
            points = [p]
            anchor = p
            strokeCountAtStart = canvas.drawing.strokes.count
            scheduleHold()
        case .changed:
            points.append(p)
            let moved = hypot(p.x - anchor.x, p.y - anchor.y)
            if recognized != nil {
                if moved > cancelDistance { recognized = nil; preview.isHidden = true }
            } else if moved > stillTolerance {
                anchor = p
                scheduleHold()
            }
        case .ended:
            holdTimer?.invalidate()
            preview.isHidden = true
            pendingShape = recognized
            recognized = nil
            // Normally applied from drawingDidChange(); this is a fallback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.applyPendingShape() }
        default:
            reset()
        }
    }

    /// Call from the canvas delegate's drawing-changed callback. Returns true if it replaced a stroke.
    @discardableResult
    func drawingDidChange() -> Bool { applyPendingShape() }

    @discardableResult
    private func applyPendingShape() -> Bool {
        guard let preview = pendingShape, let canvas else { return false }
        var drawing = canvas.drawing
        guard drawing.strokes.count > strokeCountAtStart, let freehand = drawing.strokes.last else { return false }
        pendingShape = nil

        // Re-recognise from PencilKit's complete stroke: the live gesture samples can miss the
        // first few points, which matters for telling closed shapes from open ones.
        let strokePoints = freehand.path.map { $0.location.applying(freehand.transform) }
        let shape = ShapeRecognizer.recognize(strokePoints) ?? preview
        shapeLog.debug("snapped to \(String(describing: shape), privacy: .public)")

        let before = drawing
        drawing.strokes[drawing.strokes.count - 1] = shape.stroke(styledLike: freehand)
        setDrawing(drawing, previous: before, actionName: "Shape")
        return true
    }

    private func setDrawing(_ drawing: PKDrawing, previous: PKDrawing, actionName: String) {
        guard let canvas else { return }
        canvas.undoManager?.registerUndo(withTarget: self) { assist in
            assist.setDrawing(previous, previous: drawing, actionName: actionName)
        }
        canvas.undoManager?.setActionName(actionName)
        canvas.drawing = drawing
    }

    // MARK: Hold detection

    private func scheduleHold() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func holdFired() {
        shapeLog.debug("hold fired with \(self.points.count) points")
        guard recognized == nil, let canvas, let shape = ShapeRecognizer.recognize(points) else { return }
        recognized = shape
        shapeLog.debug("recognised \(String(describing: shape), privacy: .public)")
        let tool = canvas.tool as? PKInkingTool
        preview.strokeColor = (tool?.color ?? .systemBlue).withAlphaComponent(0.85).cgColor
        // The preview layer is in the canvas's (zoomed) view coordinates.
        let zoom = canvas.zoomScale
        preview.lineWidth = max(2, min(tool?.width ?? 3, 12)) * zoom
        var toView = CGAffineTransform(scaleX: zoom, y: zoom)
        preview.path = shape.path.cgPath.copy(using: &toView)
        preview.frame = canvas.bounds
        preview.isHidden = false
    }

    private static func drawingPoint(_ point: CGPoint, in canvas: PKCanvasView) -> CGPoint {
        let zoom = max(canvas.zoomScale, 0.0001)
        return CGPoint(x: (point.x + canvas.contentOffset.x) / zoom, y: (point.y + canvas.contentOffset.y) / zoom)
    }

    private func reset() {
        holdTimer?.invalidate()
        holdTimer = nil
        recognized = nil
        pendingShape = nil
        points.removeAll()
        preview.isHidden = true
    }
}
