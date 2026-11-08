import UIKit
import PDFKit

/// The Select tool: text boxes and images on the page.
///
/// Tap an object to select it (an edit menu appears), drag it to move, drag a corner handle to
/// resize, double-tap a text box to type. Two fingers still scroll and zoom. Every change goes
/// through `NoteDocument`, so it's undoable and saved into the PDF.
final class ObjectEditor: NSObject {
    private weak var pdfView: PDFView?
    private let document: NoteDocument
    private let overlay = SelectionOverlay()
    private let tap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var observers: [NSObjectProtocol] = []
    private var offsetObservation: NSKeyValueObservation?

    private(set) var selection: (annotation: PDFAnnotation, page: PDFPage)?

    private enum Drag {
        case move(original: CGRect, start: CGPoint)
        case resize(anchor: CGPoint, original: CGRect, keepAspect: CGFloat?)
    }
    private var drag: Drag?

    private var textView: UITextView?
    private var editing: (annotation: PDFAnnotation, page: PDFPage, isNew: Bool)?

    /// Told when text editing starts/ends, so the notebook can restore the tool palette afterwards.
    var onTextEditingChanged: ((Bool) -> Void)?

    var isActive = false {
        didSet {
            [tap, doubleTap, pan].forEach { $0.isEnabled = isActive }
            if !isActive { deselect() }
        }
    }

    private let handleHitRadius: CGFloat = 28
    private let minimumSize: CGFloat = 24

    init(pdfView: PDFView, document: NoteDocument) {
        self.pdfView = pdfView
        self.document = document
        super.init()

        overlay.frame = pdfView.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.addSubview(overlay)
        pdfView.addInteraction(editMenu)

        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        pan.maximumNumberOfTouches = 1
        tap.addTarget(self, action: #selector(handleTap(_:)))
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.delegate = self
        for gesture in [tap, doubleTap, pan] {
            gesture.isEnabled = false
            pdfView.addGestureRecognizer(gesture)
        }

        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged] {
            observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    /// The PDF's internal scroll view, to follow scrolling with the selection outline.
    func follow(scrollView: UIScrollView?) {
        offsetObservation = scrollView?.observe(\.contentOffset, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Inserting

    func insertTextBox() {
        guard let (page, center) = visibleCenter() else { return }
        let size = CGSize(width: 260, height: 36)
        let bounds = clamp(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                  width: size.width, height: size.height), to: page)
        let box = TextBox.make(bounds: bounds)
        document.addAnnotation(box, to: page, actionName: "Add Text Box")
        select(box, on: page, showMenu: false)
        beginEditing(box, on: page, isNew: true)
    }

    func insertImage(_ image: UIImage) {
        guard let data = ImageAnnotation.encode(image), let (page, center) = visibleCenter() else { return }
        let crop = page.bounds(for: .cropBox)
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        var width = crop.width * 0.6
        var height = width / aspect
        if height > crop.height * 0.6 { height = crop.height * 0.6; width = height * aspect }
        let bounds = clamp(CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), to: page)
        let annotation = ImageAnnotation(imageData: data, bounds: bounds)
        document.addAnnotation(annotation, to: page, actionName: "Add Image")
        select(annotation, on: page, showMenu: true)
    }

    // MARK: Selection

    func deselect() {
        endEditing()
        selection = nil
        drag = nil
        editMenu.dismissMenu()
        refresh()
    }

    private func select(_ annotation: PDFAnnotation, on page: PDFPage, showMenu: Bool) {
        selection = (annotation, page)
        refresh()
        if showMenu, let rect = selectionRect {
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
        }
    }

    private var selectionRect: CGRect? {
        guard let pdfView, let selection else { return nil }
        return pdfView.convert(selection.annotation.bounds, from: selection.page)
    }

    func refresh() {
        overlay.selectionRect = editing == nil ? selectionRect : nil
        if let editing, let textView, let pdfView {
            textView.frame = pdfView.convert(editing.annotation.bounds, from: editing.page).insetBy(dx: -4, dy: -4)
            textView.font = font(for: editing.annotation, scaledBy: pdfView.scaleFactor)
        }
    }

    // MARK: Hit testing

    private static func isEditable(_ annotation: PDFAnnotation) -> Bool {
        annotation is ImageAnnotation || TextBox.isTextBox(annotation)
    }

    private func pageAndPoint(at viewPoint: CGPoint) -> (PDFPage, CGPoint)? {
        guard let pdfView, let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        return (page, pdfView.convert(viewPoint, to: page))
    }

    private func object(at viewPoint: CGPoint) -> (PDFAnnotation, PDFPage)? {
        guard let (page, point) = pageAndPoint(at: viewPoint) else { return nil }
        let hit = page.annotations.reversed().first { Self.isEditable($0) && $0.bounds.insetBy(dx: -6, dy: -6).contains(point) }
        return hit.map { ($0, page) }
    }

    /// Index of the selected object's corner under `viewPoint` (in view space), if any.
    private func handle(at viewPoint: CGPoint) -> Int? {
        guard let rect = selectionRect else { return nil }
        return SelectionOverlay.corners(of: rect).firstIndex { hypot($0.x - viewPoint.x, $0.y - viewPoint.y) <= handleHitRadius }
    }

    // MARK: Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: pdfView)
        if editing != nil { endEditing(); return }
        if let (annotation, page) = object(at: point) {
            select(annotation, on: page, showMenu: true)
        } else {
            deselect()
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: pdfView)
        guard let (annotation, page) = object(at: point), TextBox.isTextBox(annotation) else { return }
        select(annotation, on: page, showMenu: false)
        beginEditing(annotation, on: page, isNew: false)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let pdfView else { return }
        let viewPoint = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            editMenu.dismissMenu()
            guard let selection else { return }
            let point = pdfView.convert(viewPoint, to: selection.page)
            let bounds = selection.annotation.bounds
            if let corner = handle(at: viewPoint) {
                // Corners in view order (TL, TR, BL, BR); the anchor is the opposite one, in page space.
                let viewCorners = SelectionOverlay.corners(of: pdfView.convert(bounds, from: selection.page))
                let anchor = pdfView.convert(viewCorners[3 - corner], to: selection.page)
                let aspect = (selection.annotation as? ImageAnnotation)?.aspectRatio
                drag = .resize(anchor: anchor, original: bounds, keepAspect: aspect)
            } else {
                drag = .move(original: bounds, start: point)
            }

        case .changed:
            guard let selection, let drag else { return }
            let point = pdfView.convert(viewPoint, to: selection.page)
            switch drag {
            case let .move(original, start):
                selection.annotation.bounds = clamp(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y), to: selection.page)
            case let .resize(anchor, _, aspect):
                var width = max(abs(point.x - anchor.x), minimumSize)
                var height = max(abs(point.y - anchor.y), minimumSize)
                if let aspect {
                    if width / height > aspect { height = width / aspect } else { width = height * aspect }
                }
                let x = point.x < anchor.x ? anchor.x - width : anchor.x
                let y = point.y < anchor.y ? anchor.y - height : anchor.y
                selection.annotation.bounds = CGRect(x: x, y: y, width: width, height: height)
            }
            refresh()

        case .ended, .cancelled:
            guard let selection, let drag else { return }
            let final = selection.annotation.bounds
            let original: CGRect
            switch drag {
            case let .move(o, _): original = o
            case let .resize(_, o, _): original = o
            }
            // Put it back and apply through the document so the change is undoable.
            selection.annotation.bounds = original
            document.setBounds(final, of: selection.annotation, on: selection.page,
                               actionName: { if case .move = drag { return "Move" } else { return "Resize" } }())
            self.drag = nil
            refresh()
            if gesture.state == .ended, let rect = selectionRect {
                editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
            }

        default:
            break
        }
    }

    // MARK: Text editing

    private func font(for annotation: PDFAnnotation, scaledBy scale: CGFloat = 1) -> UIFont {
        let base = annotation.font ?? TextBox.font(size: TextBox.defaultFontSize)
        return base.withSize(base.pointSize * scale)
    }

    func beginEditing(_ annotation: PDFAnnotation, on page: PDFPage, isNew: Bool) {
        guard let pdfView, TextBox.isTextBox(annotation) else { return }
        endEditing()
        editMenu.dismissMenu()
        editing = (annotation, page, isNew)

        let textView = UITextView()
        textView.text = annotation.contents
        textView.textColor = annotation.fontColor ?? .black
        textView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.06)
        textView.layer.borderColor = UIColor.systemBlue.cgColor
        textView.layer.borderWidth = 1.5
        textView.layer.cornerRadius = 4
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.overrideUserInterfaceStyle = .light
        textView.delegate = self
        annotation.shouldDisplay = false
        pdfView.addSubview(textView)
        self.textView = textView
        refresh()
        onTextEditingChanged?(true)
        textView.becomeFirstResponder()
    }

    func endEditing() {
        guard let editing, let textView else { return }
        self.editing = nil
        self.textView = nil
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : textView.text ?? ""
        textView.resignFirstResponder()
        textView.removeFromSuperview()
        editing.annotation.shouldDisplay = true

        if text.isEmpty {
            // An empty text box isn't worth keeping.
            document.removeAnnotation(editing.annotation, from: editing.page, actionName: "Delete Text Box")
            if selection?.annotation === editing.annotation { selection = nil }
        } else {
            // Grow or shrink the box to fit the text, keeping its top edge where it is.
            let old = editing.annotation.bounds
            let font = font(for: editing.annotation)
            let needed = (text as NSString).boundingRect(
                with: CGSize(width: old.width - 8, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
            ).height + 12
            let height = max(needed.rounded(.up), minimumSize)
            let bounds = CGRect(x: old.minX, y: old.maxY - height, width: old.width, height: height)
            document.setText(text, bounds: bounds, of: editing.annotation, on: editing.page)
        }
        refresh()
        onTextEditingChanged?(false)
    }

    // MARK: Actions

    func deleteSelection() {
        guard let selection else { return }
        let name = selection.annotation is ImageAnnotation ? "Delete Image" : "Delete Text Box"
        document.removeAnnotation(selection.annotation, from: selection.page, actionName: name)
        deselect()
    }

    func duplicateSelection() {
        guard let selection else { return }
        let offset = CGPoint(x: 18, y: -18)
        let copy: PDFAnnotation
        if let image = selection.annotation as? ImageAnnotation {
            copy = image.duplicate(offsetBy: offset)
        } else if let clone = selection.annotation.copy() as? PDFAnnotation {
            clone.bounds = selection.annotation.bounds.offsetBy(dx: offset.x, dy: offset.y)
            copy = clone
        } else { return }
        copy.bounds = clamp(copy.bounds, to: selection.page)
        document.addAnnotation(copy, to: selection.page, actionName: "Duplicate")
        select(copy, on: selection.page, showMenu: true)
    }

    // MARK: Geometry

    /// The current page and the visible centre of the screen in that page's coordinates.
    private func visibleCenter() -> (PDFPage, CGPoint)? {
        guard let pdfView, let page = pdfView.currentPage else { return nil }
        let center = pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
        let crop = page.bounds(for: .cropBox)
        return (page, CGPoint(x: min(max(center.x, crop.minX), crop.maxX), y: min(max(center.y, crop.minY), crop.maxY)))
    }

    private func clamp(_ rect: CGRect, to page: PDFPage) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        var r = rect
        r.size.width = min(r.width, crop.width)
        r.size.height = min(r.height, crop.height)
        r.origin.x = min(max(r.minX, crop.minX), crop.maxX - r.width)
        r.origin.y = min(max(r.minY, crop.minY), crop.maxY - r.height)
        return r
    }
}

// MARK: - Delegates

extension ObjectEditor: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let pdfView else { return true }
        let point = gestureRecognizer.location(in: pdfView)
        if handle(at: point) != nil { return true }
        // Dragging an object selects it and moves it in one go.
        if let (annotation, page) = object(at: point) {
            if selection?.annotation !== annotation { select(annotation, on: page, showMenu: false) }
            return true
        }
        return false
    }
}

extension ObjectEditor: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        // Let the box grow downwards while typing.
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        if fitting.height > textView.bounds.height {
            textView.frame.size.height = fitting.height
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === self.textView { endEditing() }
    }
}

extension ObjectEditor: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let selection else { return nil }
        var items: [UIMenuElement] = []
        if TextBox.isTextBox(selection.annotation) {
            items.append(UIAction(title: "Edit Text", image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
                guard let self, let selection = self.selection else { return }
                beginEditing(selection.annotation, on: selection.page, isNew: false)
            })
            let current = selection.annotation.font?.pointSize ?? TextBox.defaultFontSize
            items.append(UIMenu(title: "Text Size", image: UIImage(systemName: "textformat.size"), children: TextBox.fontSizes.map { size in
                UIAction(title: "\(Int(size)) pt", state: size == current ? .on : .off) { [weak self] _ in
                    guard let self, let selection = self.selection else { return }
                    document.setFontSize(size, of: selection.annotation, on: selection.page)
                    refresh()
                }
            }))
        }
        items.append(UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            self?.duplicateSelection()
        })
        items.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.deleteSelection()
        })
        return UIMenu(children: items)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selectionRect ?? .null
    }
}

/// Draws the dashed outline and corner handles of the selected object. Never takes touches.
final class SelectionOverlay: UIView {
    var selectionRect: CGRect? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Corners in a fixed order: top-left, top-right, bottom-left, bottom-right.
    static func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    override func draw(_ rect: CGRect) {
        guard let selection = selectionRect?.standardized else { return }
        let outline = UIBezierPath(rect: selection)
        outline.setLineDash([6, 4], count: 2, phase: 0)
        outline.lineWidth = 1.5
        UIColor.systemBlue.setStroke()
        outline.stroke()
        for corner in Self.corners(of: selection) {
            let handle = UIBezierPath(ovalIn: CGRect(x: corner.x - 8, y: corner.y - 8, width: 16, height: 16))
            UIColor.white.setFill()
            handle.fill()
            handle.lineWidth = 2
            UIColor.systemBlue.setStroke()
            handle.stroke()
        }
    }
}
