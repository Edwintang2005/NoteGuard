import UIKit
import PencilKit

/// NoteGuard's lasso for handwriting, used in place of PencilKit's when the palette's lasso is
/// picked. PencilKit's lasso can move a selection but not resize it, and on iPadOS 26 an app can't
/// see what it selected, so this replaces it.
///
/// Circle some ink to select it. Then drag inside the box to move it, drag a corner to resize it
/// (keeping its proportions; stroke thickness scales too), or tap it for Duplicate and Delete.
/// Tap elsewhere, or start a new loop, to let go. Each move, resize, duplicate or delete is one
/// undo step.
///
/// Lives in a page's `PageCanvasHost`, whose coordinates are the page's drawing coordinates.
final class InkLassoView: UIView {
    weak var canvas: PKCanvasView?
    /// Called once per finished edit with the drawing before and after, for undo.
    var onCommit: ((_ before: PKDrawing, _ after: PKDrawing, _ actionName: String) -> Void)?

    /// How far the page is magnified on screen, so handles and outlines stay a constant size.
    var magnification: CGFloat = 1 { didSet { updateLayers() } }

    var isActive = false {
        didSet {
            isUserInteractionEnabled = isActive
            if !isActive { clearSelection() }
        }
    }

    /// True while this view is changing the canvas's drawing (so it isn't treated as an outside edit).
    private(set) var isApplying = false

    private var selected: [Int] = []
    private var selectionBounds: CGRect = .null
    private var lassoPoints: [CGPoint] = []
    private var touchDown: CGPoint?

    private enum Drag {
        case lasso
        case move(start: CGPoint, original: PKDrawing, bounds: CGRect)
        case resize(anchor: CGPoint, corner: CGPoint, original: PKDrawing, bounds: CGRect)
    }
    private var drag: Drag?

    private let lassoLayer = CAShapeLayer()
    private let boxLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    /// Fraction of a stroke's length that must fall inside the loop for it to be selected.
    private let insideFraction: CGFloat = 0.5
    private let minimumSize: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false

        for layer in [lassoLayer, boxLayer, handleLayer] {
            layer.lineJoin = .round
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        boxLayer.fillColor = nil
        boxLayer.strokeColor = UIColor.systemBlue.cgColor
        handleLayer.fillColor = UIColor.white.cgColor
        handleLayer.strokeColor = UIColor.systemBlue.cgColor

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1 // two fingers still scroll the notebook
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        addInteraction(editMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for layer in [lassoLayer, boxLayer, handleLayer] { layer.frame = bounds }
        updateLayers()
    }

    /// The canvas's drawing changed from somewhere else (undo, another tool): the stroke indices
    /// held here may no longer match, so let go of the selection.
    func drawingChangedElsewhere() {
        if !isApplying { clearSelection() }
    }

    func clearSelection() {
        selected = []
        selectionBounds = .null
        lassoPoints = []
        drag = nil
        editMenu.dismissMenu()
        updateLayers()
    }

    // MARK: Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let canvas else { return }
        let p = gesture.location(in: self)

        switch gesture.state {
        case .began:
            editMenu.dismissMenu()
            // Where the finger first touched: the pan is only recognised after it has moved a little,
            // which on a small handle can already be outside it.
            let start = touchDown ?? p
            if let corner = handle(at: start) {
                let anchor = opposite(of: corner, in: selectionBounds)
                drag = .resize(anchor: anchor, corner: corner, original: canvas.drawing, bounds: selectionBounds)
            } else if !selected.isEmpty, selectionBounds.insetBy(dx: -hitSlop, dy: -hitSlop).contains(start) {
                drag = .move(start: start, original: canvas.drawing, bounds: selectionBounds)
            } else {
                clearSelection()
                drag = .lasso
                lassoPoints = [start, p]
            }
        case .changed:
            switch drag {
            case .lasso:
                lassoPoints.append(p)
            case let .move(start, original, bounds):
                let t = CGAffineTransform(translationX: p.x - start.x, y: p.y - start.y)
                apply(t, to: original)
                selectionBounds = bounds.applying(t)
            case let .resize(anchor, corner, original, bounds):
                let t = resizeTransform(anchor: anchor, corner: corner, to: p, bounds: bounds)
                apply(t, to: original)
                selectionBounds = bounds.applying(t).standardized
            case nil:
                break
            }
            updateLayers()
        case .ended:
            finishDrag()
        default:
            // Cancelled: put things back.
            switch drag {
            case let .move(_, original, bounds), let .resize(_, _, original, bounds):
                setDrawing(original)
                selectionBounds = bounds
            default:
                lassoPoints = []
            }
            drag = nil
            updateLayers()
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: self)
        if !selected.isEmpty, selectionBounds.insetBy(dx: -hitSlop, dy: -hitSlop).contains(p) {
            showMenu()
        } else {
            clearSelection()
        }
    }

    private func finishDrag() {
        defer { drag = nil; updateLayers() }
        switch drag {
        case .lasso:
            selectStrokes(inside: lassoPoints)
            lassoPoints = []
            if !selected.isEmpty { showMenu() }
        case let .move(_, original, bounds):
            if selectionBounds != bounds, let canvas { onCommit?(original, canvas.drawing, "Move") }
        case let .resize(_, _, original, bounds):
            if selectionBounds != bounds, let canvas { onCommit?(original, canvas.drawing, "Resize") }
            refreshBounds()
        case nil:
            break
        }
    }

    // MARK: Selecting

    private func selectStrokes(inside loop: [CGPoint]) {
        guard let canvas, loop.count > 2 else { return }
        let path = CGMutablePath()
        path.addLines(between: loop)
        path.closeSubpath()
        let loopBox = path.boundingBoxOfPath

        selected = canvas.drawing.strokes.indices.filter { index in
            let stroke = canvas.drawing.strokes[index]
            guard stroke.renderBounds.intersects(loopBox) else { return false }
            let points = stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
            guard !points.isEmpty else { return false }
            let inside = points.filter { path.contains($0) }.count
            return CGFloat(inside) / CGFloat(points.count) >= insideFraction
        }
        refreshBounds()
    }

    private func refreshBounds() {
        guard let canvas else { return }
        let strokes = canvas.drawing.strokes
        selectionBounds = selected.filter { $0 < strokes.count }
            .reduce(CGRect.null) { $0.union(strokes[$1].renderBounds) }
        if selectionBounds.isNull { selected = [] }
    }

    // MARK: Editing

    private func apply(_ transform: CGAffineTransform, to original: PKDrawing) {
        var drawing = original
        for index in selected where index < drawing.strokes.count {
            drawing.strokes[index].transform = original.strokes[index].transform.concatenating(transform)
        }
        setDrawing(drawing)
    }

    private func setDrawing(_ drawing: PKDrawing) {
        isApplying = true
        canvas?.drawing = drawing
        isApplying = false
    }

    /// Uniform scale about `anchor` (the corner opposite the dragged one), never flipping and never
    /// shrinking the selection below a few points.
    private func resizeTransform(anchor: CGPoint, corner: CGPoint, to point: CGPoint, bounds: CGRect) -> CGAffineTransform {
        let original = CGPoint(x: corner.x - anchor.x, y: corner.y - anchor.y)
        let now = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        let lengthSquared = original.x * original.x + original.y * original.y
        guard lengthSquared > 0 else { return .identity }
        // Project onto the diagonal so the corner tracks the finger along it.
        var scale = (now.x * original.x + now.y * original.y) / lengthSquared
        let smallestSide = max(min(bounds.width, bounds.height), 1)
        scale = max(scale, minimumSize / smallestSide)
        return CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -anchor.x, y: -anchor.y)
    }

    private func duplicateSelection() {
        guard let canvas, !selected.isEmpty else { return }
        let before = canvas.drawing
        var drawing = before
        let offset = CGAffineTransform(translationX: 16, y: 16)
        let copies = selected.filter { $0 < before.strokes.count }.map { index -> PKStroke in
            var stroke = before.strokes[index]
            stroke.transform = stroke.transform.concatenating(offset)
            return stroke
        }
        let firstNew = drawing.strokes.count
        drawing.strokes.append(contentsOf: copies)
        setDrawing(drawing)
        selected = Array(firstNew..<drawing.strokes.count) // the copies stay selected, ready to move
        refreshBounds()
        updateLayers()
        onCommit?(before, drawing, "Duplicate")
    }

    private func deleteSelection() {
        guard let canvas, !selected.isEmpty else { return }
        let before = canvas.drawing
        var drawing = before
        for index in selected.sorted(by: >) where index < drawing.strokes.count {
            drawing.strokes.remove(at: index)
        }
        setDrawing(drawing)
        clearSelection()
        onCommit?(before, drawing, "Delete")
    }

    // MARK: Hit testing

    private var hitSlop: CGFloat { 12 / magnification }

    private func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func opposite(of corner: CGPoint, in r: CGRect) -> CGPoint {
        CGPoint(x: corner.x == r.minX ? r.maxX : r.minX, y: corner.y == r.minY ? r.maxY : r.minY)
    }

    private func handle(at point: CGPoint) -> CGPoint? {
        guard !selected.isEmpty, !selectionBounds.isNull else { return nil }
        let radius = 26 / magnification
        return corners(of: selectionBounds)
            .filter { hypot($0.x - point.x, $0.y - point.y) <= radius }
            .min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }
    }

    // MARK: Drawing

    private func updateLayers() {
        let m = max(magnification, 0.01)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        lassoLayer.lineWidth = 1.5 / m
        lassoLayer.lineDashPattern = [NSNumber(value: Double(5 / m)), NSNumber(value: Double(4 / m))]
        if lassoPoints.count > 1 {
            let path = CGMutablePath()
            path.addLines(between: lassoPoints)
            lassoLayer.path = path
        } else {
            lassoLayer.path = nil
        }

        let showBox = !selected.isEmpty && !selectionBounds.isNull
        boxLayer.lineWidth = 1.5 / m
        boxLayer.lineDashPattern = [NSNumber(value: Double(6 / m)), NSNumber(value: Double(4 / m))]
        let box = selectionBounds.insetBy(dx: -4 / m, dy: -4 / m)
        boxLayer.path = showBox ? CGPath(rect: box, transform: nil) : nil

        handleLayer.lineWidth = 2 / m
        if showBox {
            let r = 7 / m
            let handles = CGMutablePath()
            for c in corners(of: selectionBounds) {
                handles.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            handleLayer.path = handles
        } else {
            handleLayer.path = nil
        }
        CATransaction.commit()
    }

    private func showMenu() {
        guard !selectionBounds.isNull else { return }
        let anchor = CGPoint(x: selectionBounds.midX, y: selectionBounds.minY)
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor))
    }
}

extension InkLassoView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard !selected.isEmpty else { return nil }
        return UIMenu(children: [
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.duplicateSelection()
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteSelection()
            },
        ])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selectionBounds.isNull ? .zero : selectionBounds
    }
}

extension InkLassoView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touchDown = touch.location(in: self)
        return true
    }
}
