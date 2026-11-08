import Testing
import UIKit
import PDFKit
import PencilKit
@testable import NoteGuard

@Suite("Vector ink")
struct InkRendererTests {
    let canvas = CGSize(width: 520, height: 260)

    /// Compares where ink lands in PencilKit's own rendering vs. the vector renderer used for PDFs.
    /// Compared at 3× (a real iPad screen), so hairline strokes aren't lost to anti-aliasing.
    private let resolution: CGFloat = 3

    private func overlap(for drawing: PKDrawing) -> (iou: Double, vectorAlpha: [UInt8]) {
        var raster: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            raster = drawing.image(from: CGRect(origin: .zero, size: canvas), scale: resolution)
        }
        let pixels = CGSize(width: canvas.width * resolution, height: canvas.height * resolution)
        let reference = alphaChannel(size: pixels) { context in
            context.scaleBy(x: resolution, y: resolution)
            UIGraphicsPushContext(context)
            raster?.draw(in: CGRect(origin: .zero, size: canvas))
            UIGraphicsPopContext()
        }
        let vector = alphaChannel(size: pixels) { context in
            context.scaleBy(x: resolution, y: resolution)
            InkRenderer.draw(drawing, in: context)
        }

        // How much of each rendering has ink from the other within 2 px (at 3×): a geometric match
        // that, unlike exact pixel overlap, isn't thrown off by sub-pixel anti-aliasing on hairlines.
        let width = Int(pixels.width), height = Int(pixels.height)
        let r = reference.map { $0 > 60 }, v = vector.map { $0 > 60 }
        func near(_ mask: [Bool], _ x: Int, _ y: Int) -> Bool {
            for dy in -2...2 { for dx in -2...2 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < width, ny < height, mask[ny * width + nx] { return true }
            } }
            return false
        }
        var refInk = 0, refMatched = 0, vecInk = 0, vecMatched = 0
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            if r[i] { refInk += 1; if near(v, x, y) { refMatched += 1 } }
            if v[i] { vecInk += 1; if near(r, x, y) { vecMatched += 1 } }
        } }
        guard refInk > 0, vecInk > 0 else { return (0, vector) }
        let score = min(Double(refMatched) / Double(refInk), Double(vecMatched) / Double(vecInk))
        return (score, vector)
    }

    /// When NG_DUMP_DIR is set (TEST_RUNNER_NG_DUMP_DIR for xcodebuild), writes PencilKit's rendering
    /// on top and the vector rendering below, for eyeballing.
    private func dumpComparison(_ drawing: PKDrawing, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["NG_DUMP_DIR"] else { return }
        let size = CGSize(width: canvas.width, height: canvas.height * 2)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing.image(from: CGRect(origin: .zero, size: canvas), scale: 2).draw(at: .zero)
            }
            context.cgContext.translateBy(x: 0, y: canvas.height)
            InkRenderer.draw(drawing, in: context.cgContext)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    @Test(arguments: [2.0, 4.0, 10.0])
    func penInkMatchesPencilKit(width: Double) {
        let zigzag = (0..<12).map { i in CGPoint(x: 30 + CGFloat(i) * 40, y: i.isMultiple(of: 2) ? 60 : 200) }
        let drawing = PKDrawing(strokes: [makeStroke(zigzag, width: width)])
        let result = overlap(for: drawing)
        print("pen width \(width): match \(result.iou)")
        dumpComparison(drawing, name: "pen-\(Int(width))")
        #expect(result.iou > 0.9, "vector ink should land where PencilKit draws (match \(result.iou))")
    }

    @Test func markerInkIsSeeThrough() {
        let stroke = makeStroke([CGPoint(x: 40, y: 130), CGPoint(x: 480, y: 130)], width: 20, ink: PKInk(.marker, color: .systemYellow))
        let result = overlap(for: PKDrawing(strokes: [stroke]))
        let maxAlpha = result.vectorAlpha.max() ?? 0
        #expect(maxAlpha > 0 && maxAlpha < 230, "highlighter ink must not hide what's underneath (max alpha \(maxAlpha))")
    }

    @Test func savedInkIsVectorNotAnImage() throws {
        let url = try makeNotebook(.blank)
        let pdf = try #require(PDFDocument(url: url))
        let page = try #require(pdf.page(at: 0))
        let drawing = PKDrawing(strokes: [makeStroke([CGPoint(x: 50, y: 50), CGPoint(x: 400, y: 300)], width: 4)])
        page.addAnnotation(InkAnnotation(drawing: drawing, pageBounds: page.bounds(for: .cropBox)))
        let data = try #require(pdf.dataRepresentation())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Subtype /Image"), "pen ink should be paths, not an embedded picture")
    }
}

@Suite("Templates")
struct TemplateTests {
    @Test(arguments: PageTemplate.allCases)
    func everyTemplateIsOneA4Page(template: PageTemplate) throws {
        let pdf = try #require(PDFDocument(data: template.pdfData()))
        #expect(pdf.pageCount == 1)
        let size = try #require(pdf.page(at: 0)).bounds(for: .cropBox).size
        #expect(abs(size.width - PageTemplate.a4.width) < 1 && abs(size.height - PageTemplate.a4.height) < 1)
    }

    @Test func libraryNamesAreUniqueSortedAndDeletable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = TemplateLibrary(directory: folder)
        let data = PageTemplate.grid.pdfData()
        try library.save(data, named: "Weekly")
        try library.save(data, named: "Weekly")
        try library.save(data, named: "Algebra / maths")
        #expect(library.all().map(\.name) == ["Algebra - maths", "Weekly", "Weekly 2"])
        try library.delete(library.all()[0])
        #expect(library.all().count == 2)
    }

    @Test func savedTemplateFlattensInk() async throws {
        let url = try makeNotebook()
        let document = NoteDocument(fileURL: url)
        let opened = await document.open()
        try #require(opened)
        let page = try #require(document.pdf.page(at: 0))
        document.setDrawing(PKDrawing(strokes: [makeStroke([CGPoint(x: 60, y: 60), CGPoint(x: 300, y: 300)])]), for: page)

        let template = try #require(PDFDocument(data: document.flattenedTemplateData(for: page)))
        let templatePage = try #require(template.page(at: 0))
        #expect(template.pageCount == 1)
        #expect(templatePage.annotations.isEmpty, "ink is part of the template's page content, not editable ink")
        _ = await document.close()
    }
}
