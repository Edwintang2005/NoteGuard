import UIKit
import PDFKit
import PencilKit

/// A plain PDF file opened in place. There is no private format:
///
/// - Handwriting is saved *inside the PDF* as one annotation per page, with a normal
///   appearance stream, so Files, Preview, Acrobat and friends all show it.
/// - The same annotation carries the raw PencilKit stroke data, so when the PDF is reopened
///   here the ink comes back fully editable (erase, undo, recolour later).
final class NoteDocument: UIDocument {
    enum DocumentError: LocalizedError {
        case unreadable, unwritable
        var errorDescription: String? {
            switch self {
            case .unreadable: "This file isn't a readable PDF."
            case .unwritable: "The PDF couldn't be written."
            }
        }
    }

    private(set) var pdf = PDFDocument()

    /// Ink per page, in page space: origin at the top-left of the page's crop box, y pointing
    /// down, 1 unit = 1 PDF point. Keyed by page object so inserting pages can't shuffle ink.
    var drawings: [ObjectIdentifier: PKDrawing] = [:]

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data, let document = PDFDocument(data: data) else {
            throw DocumentError.unreadable
        }

        var drawings: [ObjectIdentifier: PKDrawing] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var ink = PKDrawing()
            var found = false
            for annotation in page.annotations {
                guard let drawing = InkAnnotation.drawing(from: annotation) else { continue }
                ink.append(drawing)
                found = true
                // The live canvas shows this ink now; drop the static copy so it isn't drawn twice.
                page.removeAnnotation(annotation)
            }
            if found { drawings[ObjectIdentifier(page)] = ink }
        }

        pdf = document
        self.drawings = drawings
    }

    override func contents(forType typeName: String) throws -> Any {
        // Work on a copy so the open document never shows the static ink annotations.
        guard let base = pdf.dataRepresentation(), let output = PDFDocument(data: base) else {
            throw DocumentError.unwritable
        }
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index),
                  let drawing = drawings[ObjectIdentifier(page)], !drawing.strokes.isEmpty,
                  let target = output.page(at: index) else { continue }
            target.addAnnotation(InkAnnotation(drawing: drawing, pageBounds: target.bounds(for: .cropBox)))
        }
        guard let data = output.dataRepresentation() else { throw DocumentError.unwritable }
        return data
    }

    func setDrawing(_ drawing: PKDrawing, for page: PDFPage) {
        drawings[ObjectIdentifier(page)] = drawing
        updateChangeCount(.done)
    }

    func insert(_ page: PDFPage, at index: Int) {
        pdf.insert(page, at: index)
        updateChangeCount(.done)
    }

    func remove(_ page: PDFPage) {
        let index = pdf.index(for: page)
        guard index != NSNotFound else { return }
        drawings[ObjectIdentifier(page)] = nil
        pdf.removePage(at: index)
        updateChangeCount(.done)
    }
}

/// A full-page stamp annotation that renders a page's ink and carries its PencilKit data.
nonisolated final class InkAnnotation: PDFAnnotation {
    static let dataKey = PDFAnnotationKey(rawValue: "/NoteGuardInk")
    /// Key used before the app was renamed; still read so older notebooks keep editable ink.
    private static let legacyDataKey = PDFAnnotationKey(rawValue: "/NoteShieldInk")
    /// Rasterisation scale for the appearance other apps display (4× ≈ 288 dpi).
    private static let renderScale: CGFloat = 4

    private let image: CGImage?
    private let inkBounds: CGRect

    init(drawing: PKDrawing, pageBounds: CGRect) {
        inkBounds = drawing.bounds
        var rendered: UIImage?
        // Render in light mode so dark-mode colour inversion never leaks into the file.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = drawing.image(from: drawing.bounds, scale: Self.renderScale)
        }
        image = rendered?.cgImage
        super.init(bounds: pageBounds, forType: .stamp, withProperties: nil)
        setValue(drawing.dataRepresentation().base64EncodedString(), forAnnotationKey: Self.dataKey)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called by PDFKit to build the appearance stream when the document is written out.
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image, !inkBounds.isEmpty else { return }
        // Ink space has a top-left origin with y down; PDF space is bottom-left with y up.
        let rect = CGRect(x: bounds.minX + inkBounds.minX,
                          y: bounds.maxY - inkBounds.maxY,
                          width: inkBounds.width,
                          height: inkBounds.height)
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    static func drawing(from annotation: PDFAnnotation) -> PKDrawing? {
        let value = annotation.value(forAnnotationKey: dataKey) ?? annotation.value(forAnnotationKey: legacyDataKey)
        guard let encoded = value as? String,
              let data = Data(base64Encoded: encoded) else { return nil }
        return try? PKDrawing(data: data)
    }
}
