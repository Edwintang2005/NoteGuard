import Foundation

/// A PDF object as written in the file. Numbers keep their original text and strings their raw
/// bytes, so copying an object out and back is lossless.
nonisolated indirect enum PDFValue: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string([UInt8])
    case name(String)
    case array([PDFValue])
    case dictionary(PDFDictionary)
    case reference(Int, Int)
    /// A stream: its dictionary and its bytes exactly as stored (still encoded).
    case stream(PDFDictionary, [UInt8])

    var int: Int? {
        if case let .number(text) = self { return Int(text) ?? Double(text).map { Int($0) } }
        return nil
    }

    var double: Double? {
        if case let .number(text) = self { return Double(text) }
        return nil
    }

    var nameValue: String? {
        if case let .name(name) = self { return name }
        return nil
    }

    var dictionary: PDFDictionary? {
        switch self {
        case let .dictionary(dict), let .stream(dict, _): dict
        default: nil
        }
    }

    var arrayValue: [PDFValue]? {
        if case let .array(items) = self { return items }
        return nil
    }

    var reference: (Int, Int)? {
        if case let .reference(number, generation) = self { return (number, generation) }
        return nil
    }

    static func number(_ value: Double) -> PDFValue { .number(PDFValue.format(value)) }
    static func number(_ value: Int) -> PDFValue { .number(String(value)) }
    static func text(_ string: String) -> PDFValue { .string(PDFValue.textBytes(string)) }

    /// PDF text-string bytes: plain ASCII where possible, else UTF-16BE with a byte-order mark.
    static func textBytes(_ string: String) -> [UInt8] {
        if string.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { return Array(string.utf8) }
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in string.utf16 { bytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        return bytes
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e12 { return String(Int(value)) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

/// An ordered PDF dictionary (order is kept so rewritten objects stay recognisable).
nonisolated struct PDFDictionary: Equatable {
    private(set) var entries: [(key: String, value: PDFValue)] = []

    init(_ entries: [(String, PDFValue)] = []) {
        for (key, value) in entries { self[key] = value }
    }

    subscript(key: String) -> PDFValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    static func == (lhs: PDFDictionary, rhs: PDFDictionary) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

// MARK: - Writing

nonisolated enum PDFSerializer {
    static func bytes(_ value: PDFValue) -> [UInt8] {
        var out: [UInt8] = []
        write(value, to: &out)
        return out
    }

    static func write(_ value: PDFValue, to out: inout [UInt8]) {
        switch value {
        case .null: out += Array("null".utf8)
        case let .bool(flag): out += Array((flag ? "true" : "false").utf8)
        case let .number(text): out += Array(text.utf8)
        case let .string(bytes):
            out.append(UInt8(ascii: "<"))
            for byte in bytes { out += Array(String(format: "%02X", byte).utf8) }
            out.append(UInt8(ascii: ">"))
        case let .name(name): out += Array(nameToken(name).utf8)
        case let .array(items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(0x20) }
                write(item, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case let .dictionary(dict):
            write(dict, to: &out)
        case let .reference(number, generation):
            out += Array("\(number) \(generation) R".utf8)
        case let .stream(dict, data):
            var dict = dict
            dict["Length"] = .number(data.count)
            write(dict, to: &out)
            out += Array("\nstream\n".utf8)
            out += data
            out += Array("\nendstream".utf8)
        }
    }

    static func write(_ dict: PDFDictionary, to out: inout [UInt8]) {
        out += Array("<<".utf8)
        for (key, value) in dict.entries {
            out += Array(nameToken(key).utf8)
            out.append(0x20)
            write(value, to: &out)
            out.append(0x0A)
        }
        out += Array(">>".utf8)
    }

    static func nameToken(_ name: String) -> String {
        var text = "/"
        for byte in name.utf8 {
            if byte > 0x20, byte < 0x7F, PDFLexer.isRegular(byte), byte != UInt8(ascii: "#") {
                text.append(Character(UnicodeScalar(byte)))
            } else {
                text += String(format: "#%02X", byte)
            }
        }
        return text
    }
}

// MARK: - Reading

nonisolated enum PDFSyntaxError: Error {
    case malformed(String)
}

/// Parses PDF objects from bytes. Streams need `/Length`, which may be an indirect reference, so a
/// resolver can be supplied.
nonisolated struct PDFLexer {
    let bytes: [UInt8]
    var index: Int
    var resolveLength: ((Int, Int) -> Int?)?

    init(bytes: [UInt8], at index: Int = 0) {
        self.bytes = bytes
        self.index = index
    }

    // MARK: Character classes

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
    }

    static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }

    static func isRegular(_ byte: UInt8) -> Bool { !isWhitespace(byte) && !isDelimiter(byte) }

    mutating func skipWhitespace() {
        while index < bytes.count {
            if Self.isWhitespace(bytes[index]) {
                index += 1
            } else if bytes[index] == UInt8(ascii: "%") {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else {
                return
            }
        }
    }

    /// A run of regular characters (a number, keyword or bare word).
    mutating func word() -> String {
        skipWhitespace()
        let start = index
        while index < bytes.count, Self.isRegular(bytes[index]) { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func expect(_ keyword: String) throws {
        let found = word()
        guard found == keyword else { throw PDFSyntaxError.malformed("expected \(keyword), found \(found)") }
    }

    /// `n g obj value endobj` at the current position; returns (number, generation, value).
    mutating func indirectObject() throws -> (Int, Int, PDFValue) {
        guard let number = Int(word()), let generation = Int(word()) else {
            throw PDFSyntaxError.malformed("object header")
        }
        try expect("obj")
        let value = try object()
        return (number, generation, value)
    }

    mutating func object() throws -> PDFValue {
        skipWhitespace()
        guard index < bytes.count else { throw PDFSyntaxError.malformed("unexpected end") }
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "/"):
            index += 1
            return .name(nameBody())
        case UInt8(ascii: "("):
            return .string(literalString())
        case UInt8(ascii: "<"):
            if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") {
                let dict = try dictionary()
                return try streamIfPresent(after: dict)
            }
            return .string(hexString())
        case UInt8(ascii: "["):
            index += 1
            var items: [PDFValue] = []
            while true {
                skipWhitespace()
                guard index < bytes.count else { throw PDFSyntaxError.malformed("array") }
                if bytes[index] == UInt8(ascii: "]") { index += 1; break }
                items.append(try object())
            }
            return .array(items)
        default:
            let token = word()
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "":
                index += 1 // stray delimiter
                return .null
            default:
                guard Double(token) != nil else { throw PDFSyntaxError.malformed("token \(token)") }
                // Could be the start of `n g R`.
                if let number = Int(token) {
                    let save = index
                    let second = word()
                    if let generation = Int(second) {
                        let third = word()
                        if third == "R" { return .reference(number, generation) }
                    }
                    index = save
                }
                return .number(token)
            }
        }
    }

    private mutating func dictionary() throws -> PDFDictionary {
        index += 2
        var dict = PDFDictionary()
        while true {
            skipWhitespace()
            guard index < bytes.count else { throw PDFSyntaxError.malformed("dictionary") }
            if bytes[index] == UInt8(ascii: ">") {
                index += 2
                return dict
            }
            guard bytes[index] == UInt8(ascii: "/") else { throw PDFSyntaxError.malformed("dictionary key") }
            index += 1
            let key = nameBody()
            dict[key] = try object()
        }
    }

    private mutating func streamIfPresent(after dict: PDFDictionary) throws -> PDFValue {
        let save = index
        skipWhitespace()
        guard word() == "stream" else {
            index = save
            return .dictionary(dict)
        }
        // The data starts after the EOL following `stream`.
        if index < bytes.count, bytes[index] == 0x0D { index += 1 }
        if index < bytes.count, bytes[index] == 0x0A { index += 1 }
        let start = index
        var length: Int?
        switch dict["Length"] {
        case let .number(text)?: length = Int(text)
        case let .reference(number, generation)?: length = resolveLength?(number, generation)
        default: break
        }
        if let length, start + length <= bytes.count, endstreamFollows(start + length) {
            index = start + length
        } else {
            // Bad or missing length: scan for the keyword.
            guard let end = find(Array("endstream".utf8), from: start) else {
                throw PDFSyntaxError.malformed("stream end")
            }
            var stop = end
            if stop > start, bytes[stop - 1] == 0x0A { stop -= 1 }
            if stop > start, bytes[stop - 1] == 0x0D { stop -= 1 }
            index = stop
        }
        let data = Array(bytes[start..<index])
        skipWhitespace()
        _ = word() // endstream
        return .stream(dict, data)
    }

    private func endstreamFollows(_ position: Int) -> Bool {
        var probe = PDFLexer(bytes: bytes, at: position)
        return probe.word() == "endstream"
    }

    func find(_ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        var i = start
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    private mutating func nameBody() -> String {
        var raw: [UInt8] = []
        while index < bytes.count, Self.isRegular(bytes[index]) {
            if bytes[index] == UInt8(ascii: "#"), index + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                raw.append(value)
                index += 3
            } else {
                raw.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: raw, as: UTF8.self)
    }

    private mutating func literalString() -> [UInt8] {
        index += 1
        var out: [UInt8] = []
        var depth = 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { return out }
                let next = bytes[index]
                index += 1
                switch next {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case 0x0D:
                    if index < bytes.count, bytes[index] == 0x0A { index += 1 }
                case 0x0A:
                    break
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(next - UInt8(ascii: "0"))
                    for _ in 0..<2 {
                        guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[index]) else { break }
                        value = value * 8 + Int(bytes[index] - UInt8(ascii: "0"))
                        index += 1
                    }
                    out.append(UInt8(value & 0xFF))
                default:
                    out.append(next)
                }
            case UInt8(ascii: "("):
                depth += 1
                out.append(byte)
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return out }
                out.append(byte)
            default:
                out.append(byte)
            }
        }
        return out
    }

    private mutating func hexString() -> [UInt8] {
        index += 1
        var digits: [UInt8] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: ">") {
            if !Self.isWhitespace(bytes[index]) { digits.append(bytes[index]) }
            index += 1
        }
        index += 1
        if digits.count % 2 == 1 { digits.append(UInt8(ascii: "0")) }
        var out: [UInt8] = []
        var i = 0
        while i < digits.count {
            out.append(UInt8(String(decoding: digits[i...(i + 1)], as: UTF8.self), radix: 16) ?? 0)
            i += 2
        }
        return out
    }
}

// MARK: - Flate

nonisolated enum Flate {
    /// zlib-wrapped data (what PDF's FlateDecode uses) → raw bytes.
    static func decode(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > 2 else { return nil }
        // NSData's .zlib is raw DEFLATE: skip the 2-byte zlib header (and ignore the checksum).
        let body = Data(data[2...])
        guard let out = try? (body as NSData).decompressed(using: .zlib) else { return nil }
        return [UInt8](out as Data)
    }

    static func encode(_ data: [UInt8]) -> [UInt8] {
        guard let deflated = try? (Data(data) as NSData).compressed(using: .zlib) else { return data }
        var out: [UInt8] = [0x78, 0x9C]
        out += [UInt8](deflated as Data)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        out += [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
        return out
    }

    /// Undoes a PNG predictor (DecodeParms /Predictor 10–15).
    static func unpredict(_ data: [UInt8], columns: Int, colors: Int = 1, bitsPerComponent: Int = 8) -> [UInt8] {
        let bpp = max(1, colors * bitsPerComponent / 8)
        let rowLength = (columns * colors * bitsPerComponent + 7) / 8
        var out: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: rowLength)
        var i = 0
        while i + rowLength < data.count + 1, i < data.count {
            let filter = data[i]
            i += 1
            guard i + rowLength <= data.count else { break }
            var row = Array(data[i..<(i + rowLength)])
            i += rowLength
            for x in 0..<rowLength {
                let left = x >= bpp ? Int(row[x - bpp]) : 0
                let up = Int(previous[x])
                let upLeft = x >= bpp ? Int(previous[x - bpp]) : 0
                let value = Int(row[x])
                switch filter {
                case 1: row[x] = UInt8((value + left) & 0xFF)
                case 2: row[x] = UInt8((value + up) & 0xFF)
                case 3: row[x] = UInt8((value + (left + up) / 2) & 0xFF)
                case 4:
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    let predictor = pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft)
                    row[x] = UInt8((value + predictor) & 0xFF)
                default: break
                }
            }
            out += row
            previous = row
        }
        return out
    }
}
