import Testing
import UIKit
import PDFKit
import PencilKit
@testable import NoteGuard

@Suite("Notebook files")
struct NoteDocumentTests {
    let line = makeStroke([CGPoint(x: 80, y: 120), CGPoint(x: 300, y: 140), CGPoint(x: 480, y: 130)])

    private func open(_ url: URL) async throws -> NoteDocument {
        let document = NoteDocument(fileURL: url)
        let opened = await document.open()
        try #require(opened)
        return document
    }

    private func saveAndClose(_ document: NoteDocument) async {
        let saved = await document.save(to: document.fileURL, for: .forOverwriting)
        #expect(saved)
        _ = await document.close()
    }

    @Test func inkSurvivesSaveAndReopenAndIsVisibleToOtherApps() async throws {
        let url = try makeNotebook()
        let document = try await open(url)
        let page = try #require(document.pdf.page(at: 0))
        document.setDrawing(PKDrawing(strokes: [line]), for: page)
        await saveAndClose(document)

        // Any PDF reader sees exactly one ink annotation.
        let raw = try #require(PDFDocument(url: url))
        let inkAnnotations = try #require(raw.page(at: 0)).annotations.filter { InkAnnotation.drawing(from: $0) != nil }
        #expect(inkAnnotations.count == 1)

        // ...and its appearance actually shows the ink. `raw` was opened without NoteGuard's
        // loading code, so its annotation is a plain stamp drawn from the appearance stream in the
        // file, the way Files and Preview draw it.
        let rawPage = try #require(raw.page(at: 0))
        let box = rawPage.bounds(for: .cropBox)
        let dark = darkPixelCount(size: box.size) { context in
            context.translateBy(x: -box.minX, y: box.height + box.minY)
            context.scaleBy(x: 1, y: -1)
            rawPage.draw(with: .cropBox, to: context)
        }
        #expect(dark > 300, "the saved ink must be visible to other PDF readers (\(dark) dark pixels)")

        // NoteGuard gets editable strokes back, and the static copy is gone from the page.
        let reopened = try await open(url)
        let reopenedPage = try #require(reopened.pdf.page(at: 0))
        #expect(reopened.drawings[ObjectIdentifier(reopenedPage)]?.strokes.count == 1)
        #expect(reopenedPage.annotations.allSatisfy { InkAnnotation.drawing(from: $0) == nil })
        _ = await reopened.close()
    }

    @Test func textBoxesAndImagesSurviveSaveAndReopen() async throws {
        let url = try makeNotebook(.blank)
        let document = try await open(url)
        let page = try #require(document.pdf.page(at: 0))

        let box = TextBox.make(bounds: CGRect(x: 100, y: 600, width: 200, height: 40))
        box.contents = "Hello from NoteGuard"
        document.addAnnotation(box, to: page, actionName: "Add Text Box")

        let picture = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let data = try #require(ImageAnnotation.encode(picture))
        document.addAnnotation(ImageAnnotation(imageData: data, bounds: CGRect(x: 100, y: 300, width: 200, height: 100)),
                               to: page, actionName: "Add Image")
        await saveAndClose(document)

        let reopened = try await open(url)
        let annotations = try #require(reopened.pdf.page(at: 0)).annotations
        let text = annotations.first(where: TextBox.isTextBox)
        #expect(text?.contents == "Hello from NoteGuard")
        let image = annotations.compactMap { $0 as? ImageAnnotation }.first
        #expect(image != nil, "images come back as editable ImageAnnotations")
        #expect(abs((image?.aspectRatio ?? 0) - 2) < 0.01)
        _ = await reopened.close()
    }

    @Test func pageInsertDeleteAndMoveUndoOneAtATime() async throws {
        let document = try await open(try makeNotebook())
        let first = try #require(document.pdf.page(at: 0))
        let second = try #require(PageTemplate.grid.makePage(size: PageTemplate.a4))
        let third = try #require(PageTemplate.dotted.makePage(size: PageTemplate.a4))
        document.setDrawing(PKDrawing(strokes: [line]), for: first)

        undoGroup(document) { document.insert(second, at: 1) }
        undoGroup(document) { document.insert(third, at: 2) }
        undoGroup(document) { document.movePage(from: 2, to: 0) }
        #expect(order(document) == [third, first, second].map(ObjectIdentifier.init))

        undoGroup(document) { document.remove(first) }
        #expect(document.pdf.pageCount == 2)
        #expect(document.drawings[ObjectIdentifier(first)] == nil)

        document.undoManager.undo() // delete
        #expect(order(document) == [third, first, second].map(ObjectIdentifier.init))
        #expect(document.drawings[ObjectIdentifier(first)]?.strokes.count == 1, "undoing a delete restores its ink")
        document.undoManager.undo() // move
        #expect(order(document) == [first, second, third].map(ObjectIdentifier.init))
        document.undoManager.undo() // insert third
        document.undoManager.undo() // insert second
        #expect(order(document) == [ObjectIdentifier(first)])
        document.undoManager.redo()
        #expect(order(document) == [first, second].map(ObjectIdentifier.init))
        _ = await document.close()
    }

    @Test func duplicateCopiesInkAndObjectsIndependently() async throws {
        let document = try await open(try makeNotebook())
        let page = try #require(document.pdf.page(at: 0))
        document.setDrawing(PKDrawing(strokes: [line]), for: page)
        let box = TextBox.make(bounds: CGRect(x: 50, y: 50, width: 100, height: 30))
        box.contents = "Original"
        document.addAnnotation(box, to: page, actionName: "Add Text Box")

        let copy = try #require(document.duplicate(page))
        #expect(document.pdf.pageCount == 2)
        #expect(document.drawings[ObjectIdentifier(copy)]?.strokes.count == 1)
        let copiedBox = try #require(copy.annotations.first(where: TextBox.isTextBox))
        #expect(copiedBox !== box, "the copy owns its own text box")
        #expect(copiedBox.contents == "Original")
        _ = await document.close()
    }

    @Test func bookmarksAreSavedAsThePDFOutline() async throws {
        let url = try makeNotebook()
        let document = try await open(url)
        let page = try #require(document.pdf.page(at: 0))
        undoGroup(document) { document.addBookmark(for: page, label: "Lecture 1") }
        #expect(document.bookmarks.map(\.label) == ["Lecture 1"])
        await saveAndClose(document)

        let raw = try #require(PDFDocument(url: url))
        #expect(raw.outlineRoot?.child(at: 0)?.label == "Lecture 1", "other readers see the bookmark")

        let reopened = try await open(url)
        let firstPage = try #require(reopened.pdf.page(at: 0))
        let outline = try #require(reopened.bookmark(for: firstPage))
        undoGroup(reopened) { reopened.removeBookmark(outline) }
        #expect(reopened.bookmarks.isEmpty)
        reopened.undoManager.undo()
        #expect(reopened.bookmarks.map(\.label) == ["Lecture 1"])
        _ = await reopened.close()
    }

    @Test func textAndPlacementEditsUndo() async throws {
        let document = try await open(try makeNotebook(.blank))
        let page = try #require(document.pdf.page(at: 0))
        let box = TextBox.make(bounds: CGRect(x: 50, y: 50, width: 100, height: 30))
        undoGroup(document) { document.addAnnotation(box, to: page, actionName: "Add Text Box") }
        undoGroup(document) { document.setText("Hi", bounds: box.bounds, of: box, on: page) }
        undoGroup(document) { document.setBounds(CGRect(x: 200, y: 200, width: 100, height: 30), of: box, on: page, actionName: "Move") }
        undoGroup(document) { document.setFontSize(32, of: box, on: page) }

        document.undoManager.undo()
        #expect(box.font?.pointSize == TextBox.defaultFontSize)
        document.undoManager.undo()
        #expect(box.bounds.origin == CGPoint(x: 50, y: 50))
        document.undoManager.undo()
        #expect((box.contents ?? "").isEmpty)
        document.undoManager.undo()
        #expect(!page.annotations.contains(box))
        _ = await document.close()
    }

    @Test func savingAHundredInkedPagesIsQuick() async throws {
        let url = try makeNotebook()
        let document = try await open(url)
        for i in 1..<100 {
            if let page = PageTemplate.lined.makePage(size: PageTemplate.a4) { document.insert(page, at: i) }
        }
        let scribble = makeStroke((0..<300).map { i in CGPoint(x: 40 + CGFloat(i % 100) * 5, y: 80 + CGFloat(i / 100) * 30) })
        for i in 0..<document.pdf.pageCount {
            if let page = document.pdf.page(at: i) { document.setDrawing(PKDrawing(strokes: [scribble, line]), for: page) }
        }

        let clock = ContinuousClock()
        let elapsed = try clock.measure { _ = try document.contents(forType: "com.adobe.pdf") }
        print("Serialising 100 inked pages took \(elapsed)")
        #expect(elapsed < .seconds(15))
        _ = await document.close()
    }

    private func order(_ document: NoteDocument) -> [ObjectIdentifier] {
        (0..<document.pdf.pageCount).compactMap { document.pdf.page(at: $0).map(ObjectIdentifier.init) }
    }
}
