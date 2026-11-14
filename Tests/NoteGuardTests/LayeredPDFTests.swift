import Testing
import UIKit
import PDFKit
import PencilKit
@testable import NoteGuard

@Suite("Layered PDFs")
struct LayeredPDFTests {
    private func rewrite(_ content: String, hidden: Set<String> = []) -> String? {
        let hooks = ContentStreamRewriter.Hooks(isPropertyHidden: { hidden.contains($0) }, isXObjectHidden: { _ in false })
        return ContentStreamRewriter.rewrite(Array(content.utf8), hooks: hooks).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func plainContentIsLeftAlone() {
        #expect(rewrite("q 0 0 1 rg 10 10 50 50 re f Q BT /F1 12 Tf (Hi) Tj ET") == nil)
    }

    @Test func hiddenLayersAreDroppedAndVisibleOnesKept() throws {
        let out = try #require(rewrite("/OC /off BDC 1 0 0 rg 0 0 9 9 re f /Span BMC (x) Tj EMC EMC /OC /on BDC 0 0 1 rg 1 1 5 5 re f EMC",
                                       hidden: ["off"]))
        #expect(!out.contains("1 0 0 rg"))
        #expect(!out.contains("(x)"))
        #expect(out.contains("0 0 1 rg"))
        #expect(out.contains("1 1 5 5 re"))
    }

    /// LaTeX colours link text by clipping to the glyphs and filling a huge rectangle; Apple's
    /// renderer floods the page with that colour. The rewrite paints the text in the colour instead.
    @Test func clipTextWithHugeFillBecomesColouredText() throws {
        let out = try #require(rewrite("q 7 Tr BT /F1 14 Tf 20 30 Td [<0038>]TJ ET 0 0 1 rg -88888 -88888 99999 99999 re f 0 Tr Q"))
        #expect(!out.contains("99999"), "the page-sized fill is gone")
        #expect(out.contains("0 0 1 rg"))
        #expect(out.contains("BT 0 Tr"))
        #expect(out.contains("[<0038>]TJ"))
    }

    @Test func stringsAndInlineImagesSurviveLexing() throws {
        let content = "BT /F1 9 Tf (a (nested) \\) paren) Tj ET BI /W 1 /H 1 /CS /G /BPC 8 ID \u{0}EI\u{1} EI /OC /x BDC 0 0 1 1 re f EMC"
        let out = try #require(rewrite(content, hidden: ["x"]))
        #expect(out.contains("(a (nested) \\) paren) Tj"))
        #expect(out.contains("BI /W 1"))
        #expect(!out.contains("re f"))
    }

    // MARK: End to end

    /// A one-page PDF with a black square in a layer that starts hidden, and a link that toggles it.
    private func layeredPDF() -> Data {
        let content = "/OC /L1 BDC 0 g 50 50 100 100 re f EMC"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /OFF [5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Properties << /L1 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /OCG /Name (Square) >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 30 30] /Border [0 0 0] /A << /S /SetOCGState /State [/Toggle 5 0 R] >> >>",
        ]
        var file = "%PDF-1.5\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(format: "%010d 00000 n \n", offset) }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(file.utf8)
    }

    private func darkPixels(_ page: PDFPage) -> Int {
        darkPixelCount(size: CGSize(width: 200, height: 200)) { context in
            // darkPixelCount gives a top-left origin; PDF pages draw bottom-left.
            context.translateBy(x: 0, y: 200)
            context.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context)
        }
    }

    @Test func hiddenLayerIsNotDrawnUntilItsLinkIsTapped() throws {
        let pdf = try #require(NotebookPDF(data: layeredPDF()))
        let page = try #require(pdf.page(at: 0))
        #expect(page is NotebookPDFPage)
        #expect(pdf.optionalContent.hasLayers)
        #expect(darkPixels(page) < 50, "the square's layer starts hidden")

        let link = try #require(page.annotations.first { $0.type == "Link" })
        let toggle = try #require(pdf.layerToggle(for: link, on: page))
        pdf.optionalContent.apply(stateArray: toggle)
        #expect(darkPixels(page) > 5_000, "the link shows the square")

        pdf.optionalContent.apply(stateArray: toggle)
        #expect(darkPixels(page) < 50, "and tapping again hides it")
    }

    @Test func writingOnALayeredPDFKeepsItsLayersAndOriginalBytes() async throws {
        let original = layeredPDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try original.write(to: url)
        let document = NoteDocument(fileURL: url)
        let opened = await document.open()
        try #require(opened)
        let page = try #require(document.pdf.page(at: 0))
        document.setDrawing(PKDrawing(strokes: [makeStroke([CGPoint(x: 20, y: 20), CGPoint(x: 150, y: 150)])]), for: page)
        let saved = await document.save(to: url, for: .forOverwriting)
        #expect(saved)
        _ = await document.close()

        let data = try Data(contentsOf: url)
        #expect(data.starts(with: original), "the original bytes are untouched; changes are appended")
        let reopened = try #require(CGPDFDocument(url as CFURL))
        #expect(reopened.catalog?.dictionary("OCProperties") != nil, "other apps still get the layers")

        // The link that toggles the layer is still there, alongside the ink.
        let raw = try #require(PDFDocument(url: url)?.page(at: 0))
        #expect(raw.annotations.contains { $0.type == "Link" })
        #expect(raw.annotations.contains { InkAnnotation.drawing(from: $0) != nil })

        let again = NoteDocument(fileURL: url)
        let reopenedOK = await again.open()
        try #require(reopenedOK)
        let reopenedPage = try #require(again.pdf.page(at: 0))
        #expect(again.drawings[ObjectIdentifier(reopenedPage)]?.strokes.count == 1)
        #expect(darkPixels(reopenedPage) < 50, "the hidden layer is still hidden")
        _ = await again.close()
    }
}
