import Foundation

/// Rewrites a page's content stream so Apple's PDF renderer shows what other viewers show.
///
/// Two things are handled:
///
/// - **Optional content (layers).** Marked content tagged `/OC /name BDC … EMC`, and form XObjects
///   with an `/OC` entry, are dropped when their layer is hidden. Apple's renderer ignores layers,
///   so without this, "print only" content and closed pop-ups are drawn on screen.
/// - **Text used as a clipping mask.** LaTeX packages colour link text by showing the glyphs in a
///   clipping render mode (`4`–`7 Tr`) and then filling an enormous rectangle, which the clip
///   limits to the letters. Apple's renderer can lose that clip and flood the whole page with the
///   colour. Here the clip-only text is removed and, where the huge fill would have painted it,
///   the same text is drawn normally in the fill colour instead.
///
/// The result is only used for display; the saved file keeps its original content.
nonisolated enum ContentStreamRewriter {
    struct Hooks {
        /// Whether the marked-content property `name` (from `/Resources /Properties`) is a hidden layer.
        var isPropertyHidden: (String) -> Bool
        /// Whether the XObject `name` (from `/Resources /XObject`) belongs to a hidden layer.
        var isXObjectHidden: (String) -> Bool
    }

    /// Quick test for whether `content` uses anything this rewriter changes.
    static func mightNeedRewrite(_ content: [UInt8]) -> Bool {
        usesOptionalContent(content) || content.containsClipRenderMode()
    }

    /// Whether `content` marks any of its parts as belonging to a layer.
    static func usesOptionalContent(_ content: [UInt8]) -> Bool {
        content.containsSequence(Array("/OC".utf8))
    }

    /// The rewritten stream, or `nil` if nothing needed changing.
    static func rewrite(_ content: [UInt8], hooks: Hooks) -> [UInt8]? {
        var rewriter = Rewriter(source: content, hooks: hooks)
        rewriter.run()
        return rewriter.changed ? rewriter.output : nil
    }
}

// MARK: - Rewriting

nonisolated private struct Rewriter {
    let source: [UInt8]
    let hooks: ContentStreamRewriter.Hooks
    var output: [UInt8] = []
    var changed = false

    private struct GraphicsState {
        var renderMode = 0
        /// Bodies of text objects shown in a clipping mode at this level (their clip is in force).
        var clipTexts: [[UInt8]] = []
    }

    private var states = [GraphicsState()]
    /// Inside a hidden layer: how many marked-content sections deep.
    private var hiddenDepth = 0

    // Text object being collected (BT … ET).
    private var inText = false
    private var textOps: [Operation] = []
    private var textShownInClipMode = false
    private var textShownVisibly = false

    // Path being built since the last painting operator.
    private var pathOps: [Operation] = []
    private var pathIsHuge = false

    init(source: [UInt8], hooks: ContentStreamRewriter.Hooks) {
        self.source = source
        self.hooks = hooks
        output.reserveCapacity(source.count)
    }

    private var state: GraphicsState {
        get { states[states.count - 1] }
        set { states[states.count - 1] = newValue }
    }

    mutating func run() {
        var lexer = ContentLexer(bytes: source)
        while let op = lexer.next() { handle(op) }
        // Unbalanced streams: write whatever is still buffered.
        for op in textOps { emit(op) }
        for op in pathOps { emit(op) }
    }

    private mutating func handle(_ op: Operation) {
        // Hidden layer: drop everything up to the matching EMC.
        if hiddenDepth > 0 {
            changed = true
            switch op.name {
            case "BDC", "BMC": hiddenDepth += 1
            case "EMC": hiddenDepth -= 1
            default: break
            }
            return
        }

        if inText {
            collectText(op)
            return
        }

        switch op.name {
        case "BDC":
            if op.operands.count >= 2, case .name("OC") = op.operands[0],
               case let .name(property) = op.operands[1], hooks.isPropertyHidden(property) {
                hiddenDepth = 1
                changed = true
                return
            }
            emit(op)
        case "q":
            states.append(state)
            emit(op)
        case "Q":
            if states.count > 1 { states.removeLast() }
            emit(op)
        case "Tr":
            if let mode = op.operands.first?.number { state.renderMode = Int(mode) }
            emit(op)
        case "BT":
            inText = true
            textOps = [op]
            textShownInClipMode = false
            textShownVisibly = false
        case "Do":
            if case let .name(name)? = op.operands.first, hooks.isXObjectHidden(name) {
                changed = true
                return
            }
            emit(op)
        case "m", "l", "c", "v", "y", "h", "re":
            pathOps.append(op)
            if op.operands.contains(where: { abs($0.number ?? 0) > 20_000 }) { pathIsHuge = true }
        case "f", "F", "f*", "B", "B*", "b", "b*", "S", "s", "n":
            paint(op)
        default:
            emit(op)
        }
    }

    // MARK: Text

    private mutating func collectText(_ op: Operation) {
        switch op.name {
        case "Tr":
            if let mode = op.operands.first?.number { state.renderMode = Int(mode) }
            textOps.append(op)
        case "Tj", "TJ", "'", "\"":
            if state.renderMode >= 4 { textShownInClipMode = true } else { textShownVisibly = true }
            textOps.append(op)
        case "ET":
            textOps.append(op)
            finishText()
        default:
            textOps.append(op)
        }
    }

    private mutating func finishText() {
        inText = false
        defer { textOps = [] }
        guard textShownInClipMode else {
            for op in textOps { emit(op) }
            return
        }
        changed = true
        // The text's body without BT/ET and without render-mode changes, for drawing it later.
        var body: [UInt8] = []
        for op in textOps.dropFirst().dropLast() where op.name != "Tr" {
            body.append(contentsOf: source[op.range])
            body.append(0x0A)
        }
        state.clipTexts.append(body)
        // Modes 4–6 also paint the text; keep that part (as mode 0–2) without the clip.
        if textShownVisibly || state.renderMode < 7 {
            let visibleMode = max(0, min(state.renderMode - 4, 2))
            append("q BT \(visibleMode) Tr\n")
            output.append(contentsOf: body)
            append("ET Q\n")
        }
    }

    // MARK: Paths

    private mutating func paint(_ op: Operation) {
        defer {
            pathOps = []
            pathIsHuge = false
        }
        let clipTexts = state.clipTexts
        guard pathIsHuge, !clipTexts.isEmpty, op.name != "n" else {
            for path in pathOps { emit(path) }
            emit(op)
            return
        }
        // A page-flooding fill meant to colour clip-mode text: draw that text in the colour instead.
        changed = true
        let mode: Int
        switch op.name {
        case "S", "s": mode = 1
        case "B", "B*", "b", "b*": mode = 2
        default: mode = 0
        }
        for body in clipTexts {
            append("q BT \(mode) Tr\n")
            output.append(contentsOf: body)
            append("ET Q\n")
        }
    }

    // MARK: Output

    private mutating func emit(_ op: Operation) {
        output.append(contentsOf: source[op.range])
        output.append(0x0A)
    }

    private mutating func append(_ text: String) {
        output.append(contentsOf: Array(text.utf8))
    }
}

// MARK: - Lexing

nonisolated struct Operation {
    enum Operand {
        case number(Double)
        case name(String)
        case other

        var number: Double? {
            if case let .number(value) = self { return value }
            return nil
        }
    }

    var operands: [Operand]
    var name: String
    /// Bytes of the whole operation (operands and operator) in the source.
    var range: Range<Int>
}

/// Splits a content stream into operations. Strings, arrays, dictionaries and inline images are
/// kept intact as single operands.
nonisolated struct ContentLexer {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func next() -> Operation? {
        var operands: [Operation.Operand] = []
        var start: Int?
        while true {
            skipWhitespaceAndComments()
            guard index < bytes.count else { return nil }
            let tokenStart = index
            if start == nil { start = tokenStart }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "/"):
                index += 1
                let nameStart = index
                while index < bytes.count, Self.isRegular(bytes[index]) { index += 1 }
                operands.append(.name(String(decoding: bytes[nameStart..<index], as: UTF8.self)))
            case UInt8(ascii: "("):
                skipLiteralString()
                operands.append(.other)
            case UInt8(ascii: "<"):
                if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") { skipDictionary() } else { skipHexString() }
                operands.append(.other)
            case UInt8(ascii: "["):
                skipArray()
                operands.append(.other)
            case UInt8(ascii: "]"), UInt8(ascii: ">"), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                index += 1 // stray delimiter; ignore
            default:
                while index < bytes.count, Self.isRegular(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[tokenStart..<index], as: UTF8.self)
                if let value = Double(word) {
                    operands.append(.number(value))
                } else if word == "true" || word == "false" || word == "null" {
                    operands.append(.other)
                } else {
                    if word == "BI" { skipInlineImage() }
                    return Operation(operands: operands, name: word, range: start!..<index)
                }
            }
        }
    }

    // MARK: Skipping

    private mutating func skipWhitespaceAndComments() {
        while index < bytes.count {
            let byte = bytes[index]
            if Self.isWhitespace(byte) {
                index += 1
            } else if byte == UInt8(ascii: "%") {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else {
                return
            }
        }
    }

    private mutating func skipLiteralString() {
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\\") {
                index += 1
            } else if byte == UInt8(ascii: "(") {
                depth += 1
            } else if byte == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { return }
            }
        }
    }

    private mutating func skipHexString() {
        while index < bytes.count, bytes[index] != UInt8(ascii: ">") { index += 1 }
        index += 1
    }

    private mutating func skipDictionary() {
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "("), depth > 0 {
                skipLiteralString()
                continue
            }
            if byte == UInt8(ascii: "<"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") {
                depth += 1
                index += 2
            } else if byte == UInt8(ascii: ">"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: ">") {
                depth -= 1
                index += 2
                if depth == 0 { return }
            } else {
                index += 1
            }
        }
    }

    private mutating func skipArray() {
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "(") {
                skipLiteralString()
                continue
            }
            index += 1
            if byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return }
            }
        }
    }

    /// After `BI`: the image dictionary, `ID`, binary data, then `EI`. The whole image becomes part
    /// of the `BI` operation's range.
    private mutating func skipInlineImage() {
        // Find the ID keyword.
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "I"), bytes[index + 1] == UInt8(ascii: "D"),
               index > 0, Self.isWhitespace(bytes[index - 1]) || bytes[index - 1] == UInt8(ascii: ">") {
                index += 3
                break
            }
            index += 1
        }
        // Find whitespace, EI, whitespace/end.
        while index + 2 < bytes.count {
            if Self.isWhitespace(bytes[index]), bytes[index + 1] == UInt8(ascii: "E"), bytes[index + 2] == UInt8(ascii: "I"),
               index + 3 == bytes.count || !Self.isRegular(bytes[index + 3]) {
                index += 3
                return
            }
            index += 1
        }
        index = bytes.count
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
}

nonisolated private extension Array where Element == UInt8 {
    func containsSequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        let first = needle[0]
        var i = 0
        while i <= count - needle.count {
            if self[i] == first, Array(self[i..<(i + needle.count)]) == needle { return true }
            i += 1
        }
        return false
    }

    /// Whether a text render mode 4–7 (one that clips) is set anywhere.
    func containsClipRenderMode() -> Bool {
        guard count >= 4 else { return false }
        for i in 0..<(count - 3) where self[i + 2] == UInt8(ascii: "T") && self[i + 3] == UInt8(ascii: "r") {
            let digit = self[i]
            if digit >= UInt8(ascii: "4"), digit <= UInt8(ascii: "7"), ContentLexer.isWhitespace(self[i + 1]),
               i == 0 || !ContentLexer.isRegular(self[i - 1]) {
                return true
            }
        }
        return false
    }
}
