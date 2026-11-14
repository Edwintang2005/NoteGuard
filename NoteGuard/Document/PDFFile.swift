import Foundation

/// Read access to an existing PDF file's objects by number, enough to append an incremental
/// update to it: the cross-reference chain (tables and streams), objects inside object streams,
/// the trailer, and the page tree.
nonisolated final class PDFFile {
    enum Location {
        case offset(Int)
        case compressed(stream: Int, index: Int)
    }

    let bytes: [UInt8]
    /// Object number → where its newest version lives.
    private(set) var locations: [Int: Location] = [:]
    /// The newest trailer (for an xref stream, that stream's dictionary).
    private(set) var trailer = PDFDictionary()
    /// Offset of the newest cross-reference section (`startxref`).
    private(set) var lastXRefOffset = 0
    /// Whether the newest cross-reference section is a stream (so updates should use one too).
    private(set) var usesXRefStreams = false
    /// One more than the highest object number in use.
    private(set) var size = 0

    private var cache: [Int: PDFValue] = [:]
    private var objectStreams: [Int: (offsets: [Int: Int], data: [UInt8], first: Int)] = [:]

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        try readCrossReferences()
    }

    var isEncrypted: Bool { trailer["Encrypt"] != nil }

    var rootReference: (Int, Int)? { trailer["Root"]?.reference }

    // MARK: Objects

    func object(_ number: Int) -> PDFValue? {
        if let cached = cache[number] { return cached }
        guard let location = locations[number] else { return nil }
        let value: PDFValue?
        switch location {
        case let .offset(offset):
            var lexer = PDFLexer(bytes: bytes, at: offset)
            lexer.resolveLength = { [weak self] number, _ in self?.resolve(.reference(number, 0))?.int }
            value = (try? lexer.indirectObject())?.2
        case let .compressed(stream, index):
            value = compressedObject(stream: stream, index: index, number: number)
        }
        if let value { cache[number] = value }
        return value
    }

    /// Follows references until a direct value.
    func resolve(_ value: PDFValue?) -> PDFValue? {
        var current = value
        var hops = 0
        while case let .reference(number, _)? = current, hops < 32 {
            current = object(number)
            hops += 1
        }
        return current
    }

    func resolvedDictionary(_ value: PDFValue?) -> PDFDictionary? { resolve(value)?.dictionary }

    /// A stream's decoded bytes (Flate with optional PNG predictor; other filters unsupported).
    func decodedStream(_ value: PDFValue?) -> [UInt8]? {
        guard case let .stream(dict, data)? = resolve(value) else { return nil }
        let filters: [String]
        switch resolve(dict["Filter"]) {
        case nil: filters = []
        case let .name(name)?: filters = [name]
        case let .array(items)?: filters = items.compactMap { resolve($0)?.nameValue }
        default: return nil
        }
        guard filters.allSatisfy({ $0 == "FlateDecode" }) else { return nil }
        var out = data
        for _ in filters {
            guard let decoded = Flate.decode(out) else { return nil }
            out = decoded
        }
        if let parms = resolvedDictionary(dict["DecodeParms"]), let predictor = resolve(parms["Predictor"])?.int, predictor >= 10 {
            out = Flate.unpredict(out,
                                  columns: resolve(parms["Columns"])?.int ?? 1,
                                  colors: resolve(parms["Colors"])?.int ?? 1,
                                  bitsPerComponent: resolve(parms["BitsPerComponent"])?.int ?? 8)
        }
        return out
    }

    private func compressedObject(stream: Int, index: Int, number: Int) -> PDFValue? {
        if objectStreams[stream] == nil {
            guard case let .stream(dict, _)? = object(stream), let data = decodedStream(object(stream)),
                  let count = resolve(dict["N"])?.int, let first = resolve(dict["First"])?.int else { return nil }
            var lexer = PDFLexer(bytes: data)
            var offsets: [Int: Int] = [:]
            for _ in 0..<count {
                guard let objectNumber = Int(lexer.word()), let offset = Int(lexer.word()) else { break }
                offsets[objectNumber] = offset
            }
            objectStreams[stream] = (offsets, data, first)
        }
        guard let entry = objectStreams[stream], let offset = entry.offsets[number] else { return nil }
        var lexer = PDFLexer(bytes: entry.data, at: entry.first + offset)
        return try? lexer.object()
    }

    // MARK: Cross references

    private func readCrossReferences() throws {
        guard let startxref = findLast(Array("startxref".utf8)) else { throw PDFSyntaxError.malformed("no startxref") }
        var lexer = PDFLexer(bytes: bytes, at: startxref + 9)
        guard let offset = Int(lexer.word()), offset < bytes.count else { throw PDFSyntaxError.malformed("startxref") }
        lastXRefOffset = offset

        var visited = Set<Int>()
        var next: Int? = offset
        var first = true
        while let position = next, !visited.contains(position), position < bytes.count {
            visited.insert(position)
            let (sectionTrailer, isStream) = try readSection(at: position)
            if first {
                trailer = sectionTrailer
                usesXRefStreams = isStream
                first = false
            }
            // Hybrid files: a table's trailer can point at an extra xref stream.
            if let hybrid = sectionTrailer["XRefStm"]?.int, !visited.contains(hybrid) {
                visited.insert(hybrid)
                _ = try? readSection(at: hybrid)
            }
            next = sectionTrailer["Prev"]?.int
        }
        size = max(trailer["Size"]?.int ?? 0, (locations.keys.max() ?? 0) + 1)
    }

    /// Reads one section; entries already known from a newer section are kept.
    private func readSection(at position: Int) throws -> (PDFDictionary, Bool) {
        var lexer = PDFLexer(bytes: bytes, at: position)
        let save = lexer.index
        if lexer.word() == "xref" {
            while true {
                let save = lexer.index
                let word = lexer.word()
                if word == "trailer" { break }
                guard let start = Int(word), let count = Int(lexer.word()) else {
                    lexer.index = save
                    throw PDFSyntaxError.malformed("xref subsection")
                }
                for i in 0..<count {
                    let offsetWord = lexer.word()
                    _ = lexer.word() // generation
                    let kind = lexer.word()
                    let number = start + i
                    guard locations[number] == nil, kind == "n", let offset = Int(offsetWord), offset > 0 else { continue }
                    locations[number] = .offset(offset)
                }
            }
            guard let dict = try lexer.object().dictionary else { throw PDFSyntaxError.malformed("trailer") }
            return (dict, false)
        }
        lexer.index = save
        let (_, _, value) = try lexer.indirectObject()
        guard case let .stream(dict, _) = value, dict["Type"]?.nameValue == "XRef",
              let data = decodedStream(value) else { throw PDFSyntaxError.malformed("xref stream") }
        let widths = (dict["W"]?.arrayValue ?? []).compactMap(\.int)
        guard widths.count == 3 else { throw PDFSyntaxError.malformed("xref /W") }
        let entrySize = widths.reduce(0, +)
        var ranges: [(Int, Int)] = []
        if let index = dict["Index"]?.arrayValue?.compactMap(\.int), index.count % 2 == 0 {
            for i in stride(from: 0, to: index.count, by: 2) { ranges.append((index[i], index[i + 1])) }
        } else {
            ranges = [(0, dict["Size"]?.int ?? 0)]
        }
        var cursor = 0
        func field(_ width: Int, default value: Int) -> Int {
            guard width > 0 else { return value }
            var result = 0
            for _ in 0..<width {
                result = result << 8 | Int(data[cursor])
                cursor += 1
            }
            return result
        }
        for (start, count) in ranges {
            for i in 0..<count {
                guard cursor + entrySize <= data.count else { break }
                let type = field(widths[0], default: 1)
                let second = field(widths[1], default: 0)
                let third = field(widths[2], default: 0)
                let number = start + i
                guard locations[number] == nil else { continue }
                switch type {
                case 1: if second > 0 { locations[number] = .offset(second) }
                case 2: locations[number] = .compressed(stream: second, index: third)
                default: break
                }
            }
        }
        return (dict, true)
    }

    private func findLast(_ needle: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        var i = bytes.count - needle.count
        let lowest = max(0, bytes.count - 4096)
        while i >= lowest {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle { return i }
            i -= 1
        }
        return nil
    }

    // MARK: Pages

    struct Page {
        let number: Int
        let generation: Int
        let dictionary: PDFDictionary
        /// Attributes this page inherits from its ancestors in the page tree.
        let inherited: PDFDictionary
    }

    /// Every page, in document order.
    func pages() -> [Page] {
        guard let root = rootReference, let catalog = resolvedDictionary(.reference(root.0, root.1)),
              let pagesRef = catalog["Pages"] else { return [] }
        var result: [Page] = []
        var visited = Set<Int>()
        func walk(_ reference: PDFValue, inherited: PDFDictionary) {
            guard case let .reference(number, generation) = reference, !visited.contains(number),
                  let dict = resolvedDictionary(reference) else { return }
            visited.insert(number)
            var inherited = inherited
            for key in ["Resources", "MediaBox", "CropBox", "Rotate"] where dict[key] != nil {
                inherited[key] = dict[key]
            }
            if dict["Type"]?.nameValue == "Pages" || dict["Kids"] != nil {
                for kid in resolve(dict["Kids"])?.arrayValue ?? [] { walk(kid, inherited: inherited) }
            } else {
                result.append(Page(number: number, generation: generation, dictionary: dict, inherited: inherited))
            }
        }
        walk(pagesRef, inherited: PDFDictionary())
        return result
    }
}
