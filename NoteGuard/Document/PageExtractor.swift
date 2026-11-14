import Foundation
import CoreGraphics

/// Builds a one-page PDF from an existing page, with a replacement content stream and a deep copy
/// of the page's resources (fonts, images, forms). Used only to render a page whose content has
/// been rewritten for display; it is never saved.
nonisolated enum PageExtractor {
    static func makePDF(from page: CGPDFPage, content: [UInt8]) -> Data? {
        var writer = ObjectWriter()
        let catalog = writer.reserve()
        let pages = writer.reserve()
        let pageObject = writer.reserve()

        let resources = page.inheritedDictionary("Resources").map { writer.dictionaryReference($0) } ?? "<< >>"
        let contents = writer.add(streamDictionary: "", data: content)

        let media = page.getBoxRect(.mediaBox)
        let crop = page.getBoxRect(.cropBox)
        writer.set(catalog, "<< /Type /Catalog /Pages \(pages) 0 R >>")
        writer.set(pages, "<< /Type /Pages /Kids [\(pageObject) 0 R] /Count 1 >>")
        writer.set(pageObject, "<< /Type /Page /Parent \(pages) 0 R /MediaBox \(rect(media)) /CropBox \(rect(crop)) /Resources \(resources) /Contents \(contents) 0 R >>")
        return writer.finish(root: catalog)
    }

    private static func rect(_ r: CGRect) -> String {
        "[\(number(r.minX)) \(number(r.minY)) \(number(r.maxX)) \(number(r.maxY))]"
    }

    static func number(_ value: CGFloat) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        var text = String(format: "%.6f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Serialises CGPDF objects into a new file. Every dictionary and stream becomes its own object
/// (shared ones only once), which also breaks reference cycles.
nonisolated private struct ObjectWriter {
    private var bodies: [Data?] = []
    private var memo: [OpaquePointer: Int] = [:]

    mutating func reserve() -> Int {
        bodies.append(nil)
        return bodies.count
    }

    mutating func set(_ number: Int, _ body: String) { bodies[number - 1] = Data(body.utf8) }

    mutating func add(streamDictionary extra: String, data: [UInt8]) -> Int {
        let number = reserve()
        var body = Data("<< \(extra) /Length \(data.count) >>\nstream\n".utf8)
        body.append(contentsOf: data)
        body.append(Data("\nendstream".utf8))
        bodies[number - 1] = body
        return number
    }

    mutating func dictionaryReference(_ dict: CGPDFDictionaryRef) -> String {
        if let number = memo[dict.rawValue] { return "\(number) 0 R" }
        let number = reserve()
        memo[dict.rawValue] = number
        bodies[number - 1] = Data(serialize(dict).utf8)
        return "\(number) 0 R"
    }

    private mutating func serialize(_ dict: CGPDFDictionaryRef, skipping skipped: Set<String> = ["Parent"]) -> String {
        var entries: [(String, CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(dict, { key, object, _ in
            entries.append((String(cString: key), object))
            return true
        }, nil)
        var text = "<<"
        for (key, object) in entries where !skipped.contains(key) {
            text += " " + Self.name(key) + " " + value(object)
        }
        return text + " >>"
    }

    private mutating func streamReference(_ stream: CGPDFStreamRef) -> String {
        if let number = memo[stream.rawValue] { return "\(number) 0 R" }
        let number = reserve()
        memo[stream.rawValue] = number
        var format = CGPDFDataFormat.raw
        let data = (CGPDFStreamCopyData(stream, &format) as Data?) ?? Data()
        var skipped: Set<String> = ["Parent", "Length", "Filter", "DecodeParms"]
        var extra = ""
        switch format {
        case .jpegEncoded: extra = "/Filter /DCTDecode"
        case .JPEG2000: extra = "/Filter /JPXDecode"
        default: break
        }
        if format != .raw { skipped.insert("DL") }
        var dictText = "<<"
        if let dict = CGPDFStreamGetDictionary(stream) {
            dictText = String(serialize(dict, skipping: skipped).dropLast(2))
        }
        var body = Data("\(dictText) \(extra) /Length \(data.count) >>\nstream\n".utf8)
        body.append(data)
        body.append(Data("\nendstream".utf8))
        bodies[number - 1] = body
        return "\(number) 0 R"
    }

    private mutating func value(_ object: CGPDFObjectRef) -> String {
        switch CGPDFObjectGetType(object) {
        case .null:
            return "null"
        case .boolean:
            var value: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &value)
            return value != 0 ? "true" : "false"
        case .integer:
            var value: CGPDFInteger = 0
            CGPDFObjectGetValue(object, .integer, &value)
            return String(value)
        case .real:
            var value: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &value)
            return PageExtractor.number(value)
        case .name:
            var value: UnsafePointer<CChar>?
            CGPDFObjectGetValue(object, .name, &value)
            return Self.name(value.map { String(cString: $0) } ?? "")
        case .string:
            var value: CGPDFStringRef?
            CGPDFObjectGetValue(object, .string, &value)
            guard let value, let bytes = CGPDFStringGetBytePtr(value) else { return "()" }
            let buffer = UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(value))
            return "<" + buffer.map { String(format: "%02X", $0) }.joined() + ">"
        case .array:
            var value: CGPDFArrayRef?
            CGPDFObjectGetValue(object, .array, &value)
            guard let value else { return "[]" }
            var items: [String] = []
            for index in 0..<CGPDFArrayGetCount(value) {
                var item: CGPDFObjectRef?
                if CGPDFArrayGetObject(value, index, &item), let item { items.append(self.value(item)) }
            }
            return "[" + items.joined(separator: " ") + "]"
        case .dictionary:
            var value: CGPDFDictionaryRef?
            CGPDFObjectGetValue(object, .dictionary, &value)
            return value.map { dictionaryReference($0) } ?? "null"
        case .stream:
            var value: CGPDFStreamRef?
            CGPDFObjectGetValue(object, .stream, &value)
            return value.map { streamReference($0) } ?? "null"
        @unknown default:
            return "null"
        }
    }

    private static func name(_ name: String) -> String {
        var text = "/"
        for byte in name.utf8 {
            if byte > 0x20, byte < 0x7F, ContentLexer.isRegular(byte), byte != UInt8(ascii: "#") {
                text.append(Character(UnicodeScalar(byte)))
            } else {
                text += String(format: "#%02X", byte)
            }
        }
        return text
    }

    func finish(root: Int) -> Data {
        var file = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(file.count)
            file.append(Data("\(index + 1) 0 obj\n".utf8))
            file.append(body ?? Data("null".utf8))
            file.append(Data("\nendobj\n".utf8))
        }
        let xref = file.count
        var table = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(bodies.count + 1) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        file.append(Data(table.utf8))
        return file
    }
}
