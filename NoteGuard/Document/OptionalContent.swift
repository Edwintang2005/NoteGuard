import Foundation
import CoreGraphics

/// Which layers (PDF optional content groups) of a document are currently shown.
///
/// Starts from the document's default configuration and changes when a link with a
/// "set layer state" action is tapped, which is how LaTeX slides make click-to-reveal pop-ups.
/// Layers are identified by their dictionary in the document's own `CGPDFDocument`.
nonisolated final class OptionalContentState: @unchecked Sendable {
    private let lock = NSLock()
    private var hidden: Set<OpaquePointer> = []
    private var _version = 0
    /// Whether the document defines any layers at all.
    let hasLayers: Bool

    /// Bumped on every change, so cached page renderings know to refresh.
    var version: Int {
        lock.lock(); defer { lock.unlock() }
        return _version
    }

    init(document: CGPDFDocument?) {
        guard let catalog = document?.catalog,
              let properties = catalog.dictionary("OCProperties") else {
            hasLayers = false
            return
        }
        hasLayers = true
        let all = properties.array("OCGs")?.dictionaries() ?? []
        guard let config = properties.dictionary("D") else { return }

        if config.name("BaseState") == "OFF" {
            let on = Set((config.array("ON")?.dictionaries() ?? []).map(\.identity))
            hidden = Set(all.map(\.identity).filter { !on.contains($0) })
        } else {
            hidden = Set((config.array("OFF")?.dictionaries() ?? []).map(\.identity))
        }

        // Automatic states for on-screen viewing (e.g. "print only" layers).
        for entry in config.array("AS")?.dictionaries() ?? [] where entry.name("Event") == "View" {
            for group in entry.array("OCGs")?.dictionaries() ?? [] {
                guard let state = group.dictionary("Usage")?.dictionary("View")?.name("ViewState") else { continue }
                if state == "OFF" { hidden.insert(group.identity) } else if state == "ON" { hidden.remove(group.identity) }
            }
        }
    }

    // MARK: Queries

    func isHidden(group: CGPDFDictionaryRef) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hidden.contains(group.identity)
    }

    /// For an `/OC` value: a layer (OCG) or a membership dictionary (OCMD).
    func isHidden(optionalContent dict: CGPDFDictionaryRef) -> Bool {
        if dict.name("Type") == "OCMD" || dict.object("OCGs") != nil {
            var groups: [CGPDFDictionaryRef] = []
            if let single = dict.dictionary("OCGs") {
                groups = [single]
            } else {
                groups = dict.array("OCGs")?.dictionaries() ?? []
            }
            guard !groups.isEmpty else { return false }
            let visible = groups.map { !isHidden(group: $0) }
            switch dict.name("P") ?? "AnyOn" {
            case "AllOn": return !visible.allSatisfy { $0 }
            case "AnyOff": return !visible.contains(false)
            case "AllOff": return visible.contains(true)
            default: return !visible.contains(true) // AnyOn
            }
        }
        return isHidden(group: dict)
    }

    // MARK: Changes

    /// Applies a `/SetOCGState` action's `/State` array: a list of `/ON`, `/OFF` or `/Toggle`, each
    /// followed by the layers it applies to.
    func apply(stateArray: CGPDFArrayRef) {
        lock.lock(); defer { lock.unlock() }
        var mode = "Toggle"
        for index in 0..<CGPDFArrayGetCount(stateArray) {
            var name: UnsafePointer<CChar>?
            if CGPDFArrayGetName(stateArray, index, &name), let name {
                mode = String(cString: name)
                continue
            }
            var group: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(stateArray, index, &group), let group else { continue }
            switch mode {
            case "ON": hidden.remove(group.identity)
            case "OFF": hidden.insert(group.identity)
            default:
                if hidden.contains(group.identity) { hidden.remove(group.identity) } else { hidden.insert(group.identity) }
            }
        }
        _version += 1
    }
}

// MARK: - CGPDF conveniences

nonisolated extension CGPDFDictionaryRef {
    /// The same object always resolves to the same dictionary within one CGPDFDocument.
    var identity: OpaquePointer { rawValue }

    func dictionary(_ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(self, key, &value) ? value : nil
    }

    func array(_ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(self, key, &value) ? value : nil
    }

    func stream(_ key: String) -> CGPDFStreamRef? {
        var value: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(self, key, &value) ? value : nil
    }

    func name(_ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(self, key, &value) ? value.map { String(cString: $0) } : nil
    }

    func object(_ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(self, key, &value) ? value : nil
    }

    func numbers(_ key: String) -> [CGFloat] {
        guard let array = array(key) else { return [] }
        return (0..<CGPDFArrayGetCount(array)).compactMap { index in
            var value: CGPDFReal = 0
            return CGPDFArrayGetNumber(array, index, &value) ? value : nil
        }
    }
}

nonisolated extension CGPDFArrayRef {
    func dictionaries() -> [CGPDFDictionaryRef] {
        (0..<CGPDFArrayGetCount(self)).compactMap { index in
            var value: CGPDFDictionaryRef?
            return CGPDFArrayGetDictionary(self, index, &value) ? value : nil
        }
    }
}

nonisolated extension CGPDFPage {
    /// A page attribute, looking up the page tree for inherited ones (such as `/Resources`).
    func inheritedDictionary(_ key: String) -> CGPDFDictionaryRef? {
        var node = dictionary
        while let current = node {
            if let value = current.dictionary(key) { return value }
            node = current.dictionary("Parent")
        }
        return nil
    }

    /// The decoded content stream(s), joined.
    func contentBytes() -> [UInt8] {
        guard let page = dictionary else { return [] }
        var bytes: [UInt8] = []
        func add(_ stream: CGPDFStreamRef) {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream, &format), format == .raw {
                bytes.append(contentsOf: data as Data)
                bytes.append(0x0A)
            }
        }
        if let stream = page.stream("Contents") {
            add(stream)
        } else if let array = page.array("Contents") {
            for index in 0..<CGPDFArrayGetCount(array) {
                var stream: CGPDFStreamRef?
                if CGPDFArrayGetStream(array, index, &stream), let stream { add(stream) }
            }
        }
        return bytes
    }
}
