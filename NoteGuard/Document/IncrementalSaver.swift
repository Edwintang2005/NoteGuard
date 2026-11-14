import UIKit
import PDFKit
import PencilKit

/// Saves a notebook by appending an incremental update to the PDF it was opened from, the way
/// Acrobat does, instead of letting PDFKit rewrite the whole file.
///
/// PDFKit on iOS re-generates every page when it saves: it drops layers (optional content) and
/// bakes its own rendering into the page content, which ruins files such as LaTeX Beamer slides
/// for every app. An incremental update leaves the original bytes untouched and adds only:
/// NoteGuard's annotations (ink, text boxes, images) with their appearance streams, the page
/// objects whose annotation lists changed, and, when pages were added, removed or reordered, a
/// new page list (and outline, when bookmarks changed).
///
/// Every save starts again from the bytes the file had when it was opened, so autosaves replace
/// each other's update rather than piling up.
nonisolated struct IncrementalSaver {
    /// What the original file looked like when it was opened.
    struct Baseline {
        let file: PDFFile
        /// Original page objects, in order.
        let pages: [PDFFile.Page]
        /// Page (by identity) → its object number and generation in the original file.
        let pageNumbers: [ObjectIdentifier: (Int, Int)]
        /// The CGPDFPage behind each original page, to recognise copies made by Duplicate.
        let cgPageNumbers: [OpaquePointer: (Int, Int)]

        init?(bytes: [UInt8], pdf: PDFDocument) {
            guard let file = try? PDFFile(bytes: bytes), !file.isEncrypted, file.rootReference != nil else { return nil }
            let pages = file.pages()
            guard pages.count == pdf.pageCount, !pages.isEmpty else { return nil }
            var pageNumbers: [ObjectIdentifier: (Int, Int)] = [:]
            var cgPageNumbers: [OpaquePointer: (Int, Int)] = [:]
            for (index, original) in pages.enumerated() {
                guard let page = pdf.page(at: index) else { return nil }
                pageNumbers[ObjectIdentifier(page)] = (original.number, original.generation)
                if let ref = page.pageRef { cgPageNumbers[OpaquePointer(Unmanaged.passUnretained(ref).toOpaque())] = (original.number, original.generation) }
            }
            self.file = file
            self.pages = pages
            self.pageNumbers = pageNumbers
            self.cgPageNumbers = cgPageNumbers
        }
    }

    enum SaveError: Error { case unsupported(String) }

    let baseline: Baseline
    let pdf: PDFDocument
    let drawings: [ObjectIdentifier: PKDrawing]
    let outlineChanged: Bool

    private var writer: UpdateWriter

    init(baseline: Baseline, pdf: PDFDocument, drawings: [ObjectIdentifier: PKDrawing], outlineChanged: Bool) {
        self.baseline = baseline
        self.pdf = pdf
        self.drawings = drawings
        self.outlineChanged = outlineChanged
        writer = UpdateWriter(file: baseline.file)
    }

    // MARK: Building the update

    mutating func data() throws -> Data {
        let file = baseline.file
        guard let root = file.rootReference, var catalog = file.resolvedDictionary(.reference(root.0, root.1)),
              case let .reference(pagesRootNumber, pagesRootGeneration)? = catalog["Pages"] else {
            throw SaveError.unsupported("no page tree")
        }

        // Which object each current page will be.
        var pageRefs: [(PDFPage, Int, Int, isNew: Bool)] = []
        var usedOriginals = Set<Int>()
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            if let (number, generation) = baseline.pageNumbers[ObjectIdentifier(page)], !usedOriginals.contains(number) {
                usedOriginals.insert(number)
                pageRefs.append((page, number, generation, false))
            } else {
                pageRefs.append((page, writer.allocate(), 0, true))
            }
        }
        let originalOrder = baseline.pages.map(\.number)
        let structureChanged = pageRefs.map(\.1) != originalOrder

        let pagesRoot = PDFValue.reference(pagesRootNumber, pagesRootGeneration)
        for (page, number, generation, isNew) in pageRefs {
            let original = baseline.pages.first { $0.number == number && !isNew }
            let liveAnnotations = try ownAnnotations(on: page, pageRef: .reference(number, generation))
            let keptAnnotations = original.map { originalForeignAnnotations(of: $0) } ?? []
            let hadOwn = original.map { hasOwnAnnotations($0) } ?? false

            if !isNew, !structureChanged, liveAnnotations.isEmpty, !hadOwn {
                continue // untouched page: keep the original object as is
            }

            var dict: PDFDictionary
            if let original {
                dict = original.dictionary
                if structureChanged {
                    // Flattened into one page list: carry over anything the old tree supplied.
                    for (key, value) in original.inherited.entries where dict[key] == nil { dict[key] = value }
                    dict["Parent"] = pagesRoot
                }
            } else {
                dict = try newPageDictionary(for: page, parent: pagesRoot)
            }
            let annots = keptAnnotations + liveAnnotations
            dict["Annots"] = annots.isEmpty ? nil : .array(annots)
            writer.set(number, generation: generation, .dictionary(dict))
        }

        if structureChanged {
            var pagesDict = file.resolvedDictionary(pagesRoot) ?? PDFDictionary()
            pagesDict["Type"] = .name("Pages")
            pagesDict["Kids"] = .array(pageRefs.map { .reference($0.1, $0.2) })
            pagesDict["Count"] = .number(pageRefs.count)
            pagesDict["Parent"] = nil
            writer.set(pagesRootNumber, generation: pagesRootGeneration, .dictionary(pagesDict))
        }

        if outlineChanged {
            let refs = Dictionary(pageRefs.map { (ObjectIdentifier($0.0), PDFValue.reference($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
            catalog["Outlines"] = writeOutline(refs: refs)
            if catalog["Outlines"] == nil { catalog["PageMode"] = nil }
            writer.set(root.0, generation: root.1, .dictionary(catalog))
        }

        return writer.finish()
    }

    // MARK: Annotations

    private static let inkKeys = ["NoteGuardInk", "NoteShieldInk"]

    private func isOwn(_ dict: PDFDictionary) -> Bool {
        Self.inkKeys.contains { dict[$0] != nil } || dict["NoteGuardImage"] != nil
            || dict["Subtype"]?.nameValue == "FreeText"
    }

    /// Original annotation references NoteGuard doesn't manage (links, form fields, other apps'
    /// markup), kept exactly as they were.
    private func originalForeignAnnotations(of page: PDFFile.Page) -> [PDFValue] {
        (baseline.file.resolve(page.dictionary["Annots"])?.arrayValue ?? []).filter { value in
            guard let dict = baseline.file.resolvedDictionary(value) else { return true }
            if isOwn(dict) { return false }
            // Popups attached to a text box go with it.
            if dict["Subtype"]?.nameValue == "Popup", let parent = baseline.file.resolvedDictionary(dict["Parent"]), isOwn(parent) {
                return false
            }
            return true
        }
    }

    private func hasOwnAnnotations(_ page: PDFFile.Page) -> Bool {
        (baseline.file.resolve(page.dictionary["Annots"])?.arrayValue ?? []).contains { value in
            baseline.file.resolvedDictionary(value).map(isOwn) ?? false
        }
    }

    /// Writes NoteGuard's annotations for `page` and returns references to them.
    private mutating func ownAnnotations(on page: PDFPage, pageRef: PDFValue) throws -> [PDFValue] {
        var refs: [PDFValue] = []
        for annotation in page.annotations {
            if let image = annotation as? ImageAnnotation {
                var dict = baseAnnotation(subtype: "Stamp", rect: image.bounds, pageRef: pageRef)
                dict["NoteGuardImage"] = .string(Array(image.imageData.base64EncodedString().utf8))
                dict["AP"] = .dictionary(PDFDictionary([("N", try appearance(of: image))]))
                refs.append(writer.add(.dictionary(dict)))
            } else if annotation.type == "FreeText" || annotation.type == PDFAnnotationSubtype.freeText.rawValue {
                refs.append(writer.add(.dictionary(try textBoxDictionary(annotation, pageRef: pageRef))))
            }
        }
        if let drawing = drawings[ObjectIdentifier(page)], !drawing.strokes.isEmpty {
            let ink = InkAnnotation(drawing: drawing, pageBounds: page.bounds(for: .cropBox))
            var dict = baseAnnotation(subtype: "Stamp", rect: ink.bounds, pageRef: pageRef)
            dict["NoteGuardInk"] = .string(Array(drawing.dataRepresentation().base64EncodedString().utf8))
            dict["AP"] = .dictionary(PDFDictionary([("N", try appearance(of: ink))]))
            refs.append(writer.add(.dictionary(dict)))
        }
        return refs
    }

    private func baseAnnotation(subtype: String, rect: CGRect, pageRef: PDFValue) -> PDFDictionary {
        PDFDictionary([
            ("Type", .name("Annot")),
            ("Subtype", .name(subtype)),
            ("Rect", rectangle(rect)),
            ("P", pageRef),
            ("F", .number(4)), // print
        ])
    }

    private mutating func textBoxDictionary(_ annotation: PDFAnnotation, pageRef: PDFValue) throws -> PDFDictionary {
        let font = annotation.font ?? UIFont(name: "Helvetica", size: 18) ?? .systemFont(ofSize: 18)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        (annotation.fontColor ?? .black).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let fontName = font.fontName.replacingOccurrences(of: " ", with: "")
        let da = "/\(fontName) \(PDFValue.format(Double(font.pointSize))) Tf \(PDFValue.format(Double(red))) \(PDFValue.format(Double(green))) \(PDFValue.format(Double(blue))) rg"
        var dict = baseAnnotation(subtype: "FreeText", rect: annotation.bounds, pageRef: pageRef)
        dict["Contents"] = .text(annotation.contents ?? "")
        dict["DA"] = .string(Array(da.utf8))
        dict["BS"] = .dictionary(PDFDictionary([("W", .number(Int(annotation.border?.lineWidth ?? 0)))]))
        dict["AP"] = .dictionary(PDFDictionary([("N", try appearance(of: annotation))]))
        return dict
    }

    /// Draws `annotation` into a one-page PDF the size of its rectangle and turns that page into a
    /// form XObject, so the appearance is exactly what PDFKit would draw.
    private mutating func appearance(of annotation: PDFAnnotation) throws -> PDFValue {
        var box = annotation.bounds
        let data = NSMutableData()
        guard box.width > 0, box.height > 0, let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw SaveError.unsupported("appearance context")
        }
        context.beginPDFPage(nil)
        InkAnnotation.whileWriting { annotation.draw(with: .mediaBox, in: context) }
        context.endPDFPage()
        context.closePDF()

        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { throw SaveError.unsupported("appearance render") }
        var form = PDFDictionary([
            ("Type", .name("XObject")),
            ("Subtype", .name("Form")),
            ("BBox", rectangle(annotation.bounds)),
        ])
        if let resources = page.inheritedDictionary("Resources") {
            form["Resources"] = writer.importDictionary(resources)
        }
        form["Filter"] = .name("FlateDecode")
        let content = withExtendedLifetime(document) { page.contentBytes() }
        return writer.add(.stream(form, Flate.encode(content)))
    }

    // MARK: New pages

    /// A page added in NoteGuard (from a template, another PDF, or a duplicate).
    private mutating func newPageDictionary(for page: PDFPage, parent: PDFValue) throws -> PDFDictionary {
        guard let cgPage = page.pageRef else { throw SaveError.unsupported("page without content") }
        let key = OpaquePointer(Unmanaged.passUnretained(cgPage).toOpaque())
        // A duplicate of an original page shares its content and resources.
        if let (number, _) = baseline.cgPageNumbers[key], let original = baseline.pages.first(where: { $0.number == number }) {
            var dict = original.dictionary
            for (key, value) in original.inherited.entries where dict[key] == nil { dict[key] = value }
            dict["Parent"] = parent
            dict["Annots"] = nil
            return dict
        }
        var dict = PDFDictionary([
            ("Type", .name("Page")),
            ("Parent", parent),
            ("MediaBox", rectangle(cgPage.getBoxRect(.mediaBox))),
        ])
        let crop = cgPage.getBoxRect(.cropBox)
        if crop != cgPage.getBoxRect(.mediaBox) { dict["CropBox"] = rectangle(crop) }
        if cgPage.rotationAngle != 0 { dict["Rotate"] = .number(Int(cgPage.rotationAngle)) }
        if let resources = cgPage.inheritedDictionary("Resources") {
            dict["Resources"] = writer.importDictionary(resources)
        }
        let content = cgPage.contentBytes()
        dict["Contents"] = writer.add(.stream(PDFDictionary([("Filter", .name("FlateDecode"))]), Flate.encode(content)))
        return dict
    }

    // MARK: Outline

    private mutating func writeOutline(refs: [ObjectIdentifier: PDFValue]) -> PDFValue? {
        guard let root = pdf.outlineRoot, root.numberOfChildren > 0 else { return nil }
        let rootNumber = writer.allocate()
        let count = writeChildren(of: root, parent: rootNumber, refs: refs)
        guard let (first, last) = count.ends else { return nil }
        writer.set(rootNumber, generation: 0, .dictionary(PDFDictionary([
            ("Type", .name("Outlines")),
            ("First", .reference(first, 0)),
            ("Last", .reference(last, 0)),
            ("Count", .number(count.total)),
        ])))
        return .reference(rootNumber, 0)
    }

    /// Writes the children of `node`; returns the first/last object numbers and how many descendants.
    private mutating func writeChildren(of node: PDFOutline, parent: Int, refs: [ObjectIdentifier: PDFValue]) -> (ends: (Int, Int)?, total: Int) {
        var items: [(PDFOutline, Int)] = []
        for i in 0..<node.numberOfChildren {
            if let child = node.child(at: i) { items.append((child, writer.allocate())) }
        }
        var total = 0
        for (index, (item, number)) in items.enumerated() {
            var dict = PDFDictionary([
                ("Title", .text(item.label ?? "Untitled")),
                ("Parent", .reference(parent, 0)),
            ])
            if index > 0 { dict["Prev"] = .reference(items[index - 1].1, 0) }
            if index + 1 < items.count { dict["Next"] = .reference(items[index + 1].1, 0) }
            if let destination = item.destination, let page = destination.page, let pageRef = refs[ObjectIdentifier(page)] {
                let point = destination.point
                let top: PDFValue = point.y.isFinite && point.y < 1e6 ? .number(Double(point.y)) : .null
                let left: PDFValue = point.x.isFinite && point.x < 1e6 ? .number(Double(point.x)) : .null
                dict["Dest"] = .array([pageRef, .name("XYZ"), left, top, .null])
            } else if let action = item.action as? PDFActionURL, let url = action.url {
                dict["A"] = .dictionary(PDFDictionary([("S", .name("URI")), ("URI", .string(Array(url.absoluteString.utf8)))]))
            }
            let children = writeChildren(of: item, parent: number, refs: refs)
            if let (first, last) = children.ends {
                dict["First"] = .reference(first, 0)
                dict["Last"] = .reference(last, 0)
                dict["Count"] = .number(item.isOpen ? children.total : -children.total)
            }
            writer.set(number, generation: 0, .dictionary(dict))
            total += 1 + (item.isOpen ? children.total : 0)
        }
        guard let first = items.first?.1, let last = items.last?.1 else { return (nil, 0) }
        return ((first, last), total)
    }

    private func rectangle(_ rect: CGRect) -> PDFValue {
        .array([rect.minX, rect.minY, rect.maxX, rect.maxY].map { .number(Double($0)) })
    }
}

// MARK: - Writing the update

/// Collects new and replaced objects and appends them, with a cross-reference section, to the
/// original bytes.
nonisolated struct UpdateWriter {
    private let file: PDFFile
    private var nextNumber: Int
    private var objects: [(number: Int, generation: Int, value: PDFValue)] = []
    private var importedStreams: [OpaquePointer: PDFValue] = [:]

    init(file: PDFFile) {
        self.file = file
        nextNumber = file.size
    }

    mutating func allocate() -> Int {
        defer { nextNumber += 1 }
        return nextNumber
    }

    mutating func set(_ number: Int, generation: Int, _ value: PDFValue) {
        objects.removeAll { $0.number == number }
        objects.append((number, generation, value))
    }

    /// Adds a new indirect object and returns a reference to it.
    mutating func add(_ value: PDFValue) -> PDFValue {
        let number = allocate()
        objects.append((number, 0, value))
        return .reference(number, 0)
    }

    // MARK: Importing from CGPDF

    /// Copies a dictionary from another PDF (CoreGraphics' view of it). Streams become new objects,
    /// shared ones only once.
    mutating func importDictionary(_ dict: CGPDFDictionaryRef, depth: Int = 0) -> PDFValue {
        var entries: [(String, CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(dict, { key, object, _ in
            entries.append((String(cString: key), object))
            return true
        }, nil)
        var out = PDFDictionary()
        for (name, object) in entries where name != "Parent" {
            out[name] = importObject(object, depth: depth + 1)
        }
        return .dictionary(out)
    }

    private mutating func importObject(_ object: CGPDFObjectRef, depth: Int) -> PDFValue {
        guard depth < 40 else { return .null }
        switch CGPDFObjectGetType(object) {
        case .null: return .null
        case .boolean:
            var value: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &value)
            return .bool(value != 0)
        case .integer:
            var value: CGPDFInteger = 0
            CGPDFObjectGetValue(object, .integer, &value)
            return .number(value)
        case .real:
            var value: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &value)
            return .number(Double(value))
        case .name:
            var value: UnsafePointer<CChar>?
            CGPDFObjectGetValue(object, .name, &value)
            return .name(value.map { String(cString: $0) } ?? "")
        case .string:
            var value: CGPDFStringRef?
            CGPDFObjectGetValue(object, .string, &value)
            guard let value, let bytes = CGPDFStringGetBytePtr(value) else { return .string([]) }
            return .string(Array(UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(value))))
        case .array:
            var value: CGPDFArrayRef?
            CGPDFObjectGetValue(object, .array, &value)
            guard let value else { return .array([]) }
            var items: [PDFValue] = []
            for index in 0..<CGPDFArrayGetCount(value) {
                var item: CGPDFObjectRef?
                if CGPDFArrayGetObject(value, index, &item), let item { items.append(importObject(item, depth: depth + 1)) }
            }
            return .array(items)
        case .dictionary:
            var value: CGPDFDictionaryRef?
            CGPDFObjectGetValue(object, .dictionary, &value)
            return value.map { importDictionary($0, depth: depth + 1) } ?? .null
        case .stream:
            var value: CGPDFStreamRef?
            CGPDFObjectGetValue(object, .stream, &value)
            guard let value else { return .null }
            if let existing = importedStreams[value.rawValue] { return existing }
            var format = CGPDFDataFormat.raw
            let data = [UInt8]((CGPDFStreamCopyData(value, &format) as Data?) ?? Data())
            var dict = PDFDictionary()
            if let streamDict = CGPDFStreamGetDictionary(value), case let .dictionary(imported) = importDictionary(streamDict, depth: depth + 1) {
                dict = imported
            }
            for key in ["Length", "Filter", "DecodeParms", "DL"] { dict[key] = nil }
            let encoded: [UInt8]
            switch format {
            case .jpegEncoded:
                dict["Filter"] = .name("DCTDecode")
                encoded = data
            case .JPEG2000:
                dict["Filter"] = .name("JPXDecode")
                encoded = data
            default:
                dict["Filter"] = .name("FlateDecode")
                encoded = Flate.encode(data)
            }
            let reference = add(.stream(dict, encoded))
            importedStreams[value.rawValue] = reference
            return reference
        @unknown default:
            return .null
        }
    }

    // MARK: Output

    func finish() -> Data {
        var out = file.bytes
        if out.last != 0x0A { out.append(0x0A) }
        var offsets: [(Int, Int, Int)] = [] // number, generation, offset
        for (number, generation, value) in objects.sorted(by: { $0.number < $1.number }) {
            offsets.append((number, generation, out.count))
            out += Array("\(number) \(generation) obj\n".utf8)
            PDFSerializer.write(value, to: &out)
            out += Array("\nendobj\n".utf8)
        }

        var trailer = PDFDictionary()
        for key in ["Root", "Info", "ID"] { trailer[key] = file.trailer[key] }
        trailer["Prev"] = .number(file.lastXRefOffset)

        if file.usesXRefStreams {
            let xrefNumber = nextNumber
            let xrefOffset = out.count
            var entries = offsets
            entries.append((xrefNumber, 0, xrefOffset))
            entries.sort { $0.0 < $1.0 }
            var index: [PDFValue] = []
            var data: [UInt8] = []
            var i = 0
            while i < entries.count {
                var j = i
                while j + 1 < entries.count, entries[j + 1].0 == entries[j].0 + 1 { j += 1 }
                index += [.number(entries[i].0), .number(j - i + 1)]
                for entry in entries[i...j] {
                    data.append(1)
                    data += [UInt8((entry.2 >> 24) & 0xFF), UInt8((entry.2 >> 16) & 0xFF), UInt8((entry.2 >> 8) & 0xFF), UInt8(entry.2 & 0xFF)]
                    data += [UInt8((entry.1 >> 8) & 0xFF), UInt8(entry.1 & 0xFF)]
                }
                i = j + 1
            }
            trailer["Type"] = .name("XRef")
            trailer["Size"] = .number(xrefNumber + 1)
            trailer["W"] = .array([.number(1), .number(4), .number(2)])
            trailer["Index"] = .array(index)
            out += Array("\(xrefNumber) 0 obj\n".utf8)
            PDFSerializer.write(.stream(trailer, data), to: &out)
            out += Array("\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        } else {
            let xrefOffset = out.count
            out += Array("xref\n".utf8)
            let sorted = offsets.sorted { $0.0 < $1.0 }
            var i = 0
            while i < sorted.count {
                var j = i
                while j + 1 < sorted.count, sorted[j + 1].0 == sorted[j].0 + 1 { j += 1 }
                out += Array("\(sorted[i].0) \(j - i + 1)\n".utf8)
                for entry in sorted[i...j] {
                    out += Array(String(format: "%010d %05d n \n", entry.2, entry.1).utf8)
                }
                i = j + 1
            }
            trailer["Size"] = .number(nextNumber)
            out += Array("trailer\n".utf8)
            PDFSerializer.write(.dictionary(trailer), to: &out)
            out += Array("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        }
        return Data(out)
    }
}
