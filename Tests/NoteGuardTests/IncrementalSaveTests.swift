import Testing
import UIKit
import PDFKit
import PencilKit
@testable import NoteGuard

@Suite("Incremental saving")
struct IncrementalSaveTests {
    let line = makeStroke([CGPoint(x: 80, y: 120), CGPoint(x: 300, y: 140)])

    private func open(_ url: URL) async throws -> NoteDocument {
        let document = NoteDocument(fileURL: url)
        let opened = await document.open()
        try #require(opened)
        return document
    }

    private func save(_ document: NoteDocument) async {
        let saved = await document.save(to: document.fileURL, for: .forOverwriting)
        #expect(saved)
    }

    @Test func repeatedSavesReplaceRatherThanPileUp() async throws {
        let url = try makeNotebook()
        let originalSize = try Data(contentsOf: url).count
        let document = try await open(url)
        let page = try #require(document.pdf.page(at: 0))
        document.setDrawing(PKDrawing(strokes: [line]), for: page)
        await save(document)
        let first = try Data(contentsOf: url).count
        await save(document)
        await save(document)
        let third = try Data(contentsOf: url).count
        #expect(first > originalSize)
        #expect(third == first, "each save starts again from the opened file")
        _ = await document.close()
    }

    @Test func textBoxFontSizeAndTextSurvive() async throws {
        let url = try makeNotebook(.blank)
        let document = try await open(url)
        let page = try #require(document.pdf.page(at: 0))
        let box = TextBox.make(bounds: CGRect(x: 100, y: 600, width: 220, height: 40))
        box.contents = "Größe (24 pt) ✓"
        box.font = TextBox.font(size: 24)
        document.addAnnotation(box, to: page, actionName: "Add Text Box")
        await save(document)
        _ = await document.close()

        let reopened = try await open(url)
        let read = try #require(reopened.pdf.page(at: 0)?.annotations.first(where: TextBox.isTextBox))
        #expect(read.contents == "Größe (24 pt) ✓")
        #expect(read.font?.pointSize == 24)
        #expect(read.font?.familyName == "Helvetica")
        _ = await reopened.close()
    }

    @Test func addedMovedAndDeletedPagesAreSaved() async throws {
        let url = try makeNotebook(.lined)
        let document = try await open(url)
        let first = try #require(document.pdf.page(at: 0))
        let grid = try #require(PageSource.builtIn(.grid).makePage(size: PageTemplate.a4))
        let dotted = try #require(PageSource.builtIn(.dotted).makePage(size: PageTemplate.a4))
        document.insert(grid, at: 1)
        document.insert(dotted, at: 2)
        document.setDrawing(PKDrawing(strokes: [line]), for: grid)
        document.movePage(from: 2, to: 0) // dotted, lined, grid
        let duplicate = try #require(document.duplicate(first)) // dotted, lined, lined copy, grid
        document.remove(dotted) // lined, lined copy, grid
        #expect(document.index(of: duplicate) == 1)
        await save(document)
        _ = await document.close()

        let reopened = try await open(url)
        #expect(reopened.pdf.pageCount == 3)
        let reopenedGrid = try #require(reopened.pdf.page(at: 2))
        #expect(reopened.drawings[ObjectIdentifier(reopenedGrid)]?.strokes.count == 1, "ink stays with its page")
        // The duplicate draws the same lined template as the first page.
        let a = try #require(reopened.pdf.page(at: 0)).thumbnail(of: CGSize(width: 60, height: 85), for: .cropBox).pngData()
        let b = try #require(reopened.pdf.page(at: 1)).thumbnail(of: CGSize(width: 60, height: 85), for: .cropBox).pngData()
        #expect(a == b)
        _ = await reopened.close()
    }

    @Test func bookmarksRemovedAndAddedAreSaved() async throws {
        let url = try makeNotebook()
        let document = try await open(url)
        let page = try #require(document.pdf.page(at: 0))
        let second = try #require(PageSource.builtIn(.blank).makePage(size: PageTemplate.a4))
        document.insert(second, at: 1)
        document.addBookmark(for: page, label: "Intro")
        document.addBookmark(for: second, label: "Ünïcode")
        await save(document)
        _ = await document.close()

        let reopened = try await open(url)
        #expect(reopened.bookmarks.map(\.label) == ["Intro", "Ünïcode"])
        #expect(reopened.bookmarks.last.flatMap { reopened.index(of: $0.page) } == 1)
        _ = await reopened.close()
    }

    /// A small PDF that stores its objects in an object stream and its cross references in a
    /// compressed xref stream, as LaTeX (pdfTeX, dvipdfmx) output usually does.
    private func objectStreamPDF() -> Data {
        let content = Array("0 g 50 50 100 100 re f".utf8)
        var file = Array("%PDF-1.5\n".utf8)
        // Objects 1 (catalog), 2 (pages), 3 (page) live in object stream 5.
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>",
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << >> >>",
        ]
        var header = ""
        var body = ""
        for (i, object) in objects.enumerated() {
            header += "\(i + 1) \(body.utf8.count) "
            body += object + "\n"
        }
        let objStm = Array((header + "\n" + body).utf8)
        let first = (header + "\n").utf8.count
        var offsets: [Int: Int] = [:]
        offsets[4] = file.count
        file += Array("4 0 obj\n<< /Length \(content.count) >>\nstream\n".utf8) + content + Array("\nendstream\nendobj\n".utf8)
        let packed = Flate.encode(objStm)
        offsets[5] = file.count
        file += Array("5 0 obj\n<< /Type /ObjStm /N 3 /First \(first) /Filter /FlateDecode /Length \(packed.count) >>\nstream\n".utf8)
        file += packed + Array("\nendstream\nendobj\n".utf8)
        // xref stream (object 6), with a PNG Up predictor like real files.
        let xrefOffset = file.count
        var rows: [[UInt8]] = []
        rows.append([0, 0, 0, 0, 0xFF])
        for i in 0..<3 { rows.append([2, 0, 0, 5, UInt8(i)]) }
        for number in [4, 5] {
            let o = offsets[number]!
            rows.append([1, UInt8(o >> 16 & 0xFF), UInt8(o >> 8 & 0xFF), UInt8(o & 0xFF), 0])
        }
        rows.append([1, UInt8(xrefOffset >> 16 & 0xFF), UInt8(xrefOffset >> 8 & 0xFF), UInt8(xrefOffset & 0xFF), 0])
        var predicted: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: 5)
        for row in rows {
            predicted.append(2)
            for (x, byte) in row.enumerated() { predicted.append(byte &- previous[x]) }
            previous = row
        }
        let xref = Flate.encode(predicted)
        file += Array("6 0 obj\n<< /Type /XRef /Size 7 /W [1 3 1] /Root 1 0 R /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 5 >> /Length \(xref.count) >>\nstream\n".utf8)
        file += xref + Array("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return Data(file)
    }

    @Test func readsAndUpdatesObjectStreamFiles() async throws {
        let original = objectStreamPDF()
        let parsed = try PDFFile(bytes: [UInt8](original))
        #expect(parsed.usesXRefStreams)
        #expect(parsed.pages().map(\.number) == [3])
        #expect(parsed.pages().first?.inherited["MediaBox"] != nil, "inherited from the page tree")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try original.write(to: url)
        let document = try await open(url)
        let page = try #require(document.pdf.page(at: 0))
        document.setDrawing(PKDrawing(strokes: [line]), for: page)
        await save(document)
        _ = await document.close()

        let data = try Data(contentsOf: url)
        #expect(data.starts(with: original))
        let updated = try PDFFile(bytes: [UInt8](data))
        #expect(updated.usesXRefStreams, "the update uses an xref stream like the original")
        let reopened = try await open(url)
        let reopenedPage = try #require(reopened.pdf.page(at: 0))
        #expect(reopened.drawings[ObjectIdentifier(reopenedPage)]?.strokes.count == 1)
        _ = await reopened.close()
    }

    /// The real lecture slides from this bug, when available on this Mac (skipped elsewhere).
    @Test func realLectureSlidesStayIntact() async throws {
        let source = URL(fileURLWithPath: "/Users/Edwin_1/Downloads/Lecture slides-20261114/LectureSlides/Lecture_1.pdf")
        guard let original = try? Data(contentsOf: source) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try original.write(to: url)
        let document = try await open(url)
        let page = try #require(document.pdf.page(at: 6))
        document.setDrawing(PKDrawing(strokes: [line]), for: page)
        await save(document)
        _ = await document.close()

        let data = try Data(contentsOf: url)
        #expect(data.starts(with: original))
        #expect(data.count - original.count < 200_000, "only the changes are appended (\(data.count - original.count) bytes)")
        let reopened = try await open(url)
        #expect(reopened.pdf.pageCount == 36)
        let reopenedPage = try #require(reopened.pdf.page(at: 6))
        #expect(reopened.drawings[ObjectIdentifier(reopenedPage)]?.strokes.count == 1)
        let cg = try #require(CGPDFDocument(url as CFURL))
        #expect(cg.catalog?.dictionary("OCProperties") != nil)
        _ = await reopened.close()
    }
}
