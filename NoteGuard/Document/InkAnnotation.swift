import UIKit
import PDFKit
import PencilKit

/// A full-page stamp annotation that renders a page's ink and carries its PencilKit data.
///
/// Other apps show the appearance stream (vector paths for most inks); NoteGuard reads the embedded
/// stroke data back so ink stays fully editable.
nonisolated final class InkAnnotation: PDFAnnotation {
    static let dataKey = PDFAnnotationKey(rawValue: "/NoteGuardInk")
    /// Key used before the app was renamed; still read so older notebooks keep editable ink.
    private static let legacyDataKey = PDFAnnotationKey(rawValue: "/NoteShieldInk")

    private let ink: PKDrawing

    init(drawing: PKDrawing, pageBounds: CGRect) {
        ink = drawing
        super.init(bounds: pageBounds, forType: .stamp, withProperties: nil)
        setValue(drawing.dataRepresentation().base64EncodedString(), forAnnotationKey: Self.dataKey)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called by PDFKit to build the appearance stream when the document is written out.
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        // Ink space has a top-left origin with y down; PDF space is bottom-left with y up.
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        InkRenderer.draw(ink, in: context)
        context.restoreGState()
    }

    static func drawing(from annotation: PDFAnnotation) -> PKDrawing? {
        let value = annotation.value(forAnnotationKey: dataKey) ?? annotation.value(forAnnotationKey: legacyDataKey)
        guard let encoded = value as? String, let data = Data(base64Encoded: encoded) else { return nil }
        return try? PKDrawing(data: data)
    }
}
