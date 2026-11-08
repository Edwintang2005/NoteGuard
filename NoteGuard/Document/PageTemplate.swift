import UIKit
import PDFKit

/// Built-in paper styles. The pattern is real PDF page content (not ink), so the eraser never
/// touches it and other apps show it too.
enum PageTemplate: String, CaseIterable, Identifiable {
    case blank, lined, grid, dotted, cornell, music, planner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cornell: "Cornell Notes"
        case .music: "Music Staves"
        case .planner: "Weekly Planner"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .blank: "doc"
        case .lined: "line.3.horizontal"
        case .grid: "squareshape.split.3x3"
        case .dotted: "circle.grid.3x3"
        case .cornell: "rectangle.split.2x1"
        case .music: "music.note"
        case .planner: "calendar"
        }
    }

    /// A4 portrait, in PDF points.
    static let a4 = CGSize(width: 595.28, height: 841.89)

    func pdfData(pageSize: CGSize = PageTemplate.a4) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            draw(in: context.cgContext, bounds: bounds)
        }
    }

    func makePage(size: CGSize) -> PDFPage? {
        PDFDocument(data: pdfData(pageSize: size))?.page(at: 0)
    }

    // MARK: Drawing

    private static let rule = UIColor(red: 0.62, green: 0.75, blue: 0.90, alpha: 1)
    private static let ink = UIColor(white: 0.35, alpha: 1)

    private func draw(in ctx: CGContext, bounds: CGRect) {
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(bounds)

        switch self {
        case .blank:
            break

        case .lined:
            Self.ruledLines(in: ctx, from: 80, to: bounds.maxY - 30, x: 0...bounds.maxX, spacing: 26)
            Self.line(in: ctx, from: CGPoint(x: 64, y: 0), to: CGPoint(x: 64, y: bounds.maxY),
                      color: UIColor.systemRed.withAlphaComponent(0.45), width: 0.6)

        case .grid:
            let spacing: CGFloat = 20
            ctx.setStrokeColor(Self.rule.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(0.4)
            for x in stride(from: spacing, to: bounds.maxX, by: spacing) {
                ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
            }
            for y in stride(from: spacing, to: bounds.maxY, by: spacing) {
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
            ctx.strokePath()

        case .dotted:
            let spacing: CGFloat = 20, r: CGFloat = 0.9
            ctx.setFillColor(UIColor(white: 0.6, alpha: 1).cgColor)
            for y in stride(from: spacing, to: bounds.maxY, by: spacing) {
                for x in stride(from: spacing, to: bounds.maxX, by: spacing) {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }

        case .cornell:
            // Title band, cue column on the left, summary box at the bottom.
            let header: CGFloat = 90, cue: CGFloat = 0.28 * bounds.width, summary = bounds.maxY - 150
            Self.ruledLines(in: ctx, from: header + 26, to: summary - 8, x: 0...bounds.maxX, spacing: 26)
            Self.ruledLines(in: ctx, from: summary + 32, to: bounds.maxY - 20, x: 0...bounds.maxX, spacing: 26)
            Self.line(in: ctx, from: CGPoint(x: 0, y: header), to: CGPoint(x: bounds.maxX, y: header), color: Self.ink, width: 1)
            Self.line(in: ctx, from: CGPoint(x: 0, y: summary), to: CGPoint(x: bounds.maxX, y: summary), color: Self.ink, width: 1)
            Self.line(in: ctx, from: CGPoint(x: cue, y: header), to: CGPoint(x: cue, y: summary), color: Self.ink, width: 1)
            Self.label("Cues", at: CGPoint(x: 14, y: header + 6), in: ctx)
            Self.label("Notes", at: CGPoint(x: cue + 14, y: header + 6), in: ctx)
            Self.label("Summary", at: CGPoint(x: 14, y: summary + 6), in: ctx)

        case .music:
            // Five-line staves.
            let margin: CGFloat = 48, gap: CGFloat = 7, staffSpacing: CGFloat = 66
            ctx.setStrokeColor(Self.ink.cgColor)
            ctx.setLineWidth(0.6)
            var top: CGFloat = 70
            while top + gap * 4 < bounds.maxY - 40 {
                for i in 0..<5 {
                    let y = top + CGFloat(i) * gap
                    ctx.move(to: CGPoint(x: margin, y: y)); ctx.addLine(to: CGPoint(x: bounds.maxX - margin, y: y))
                }
                ctx.move(to: CGPoint(x: margin, y: top)); ctx.addLine(to: CGPoint(x: margin, y: top + gap * 4))
                ctx.move(to: CGPoint(x: bounds.maxX - margin, y: top)); ctx.addLine(to: CGPoint(x: bounds.maxX - margin, y: top + gap * 4))
                top += staffSpacing
            }
            ctx.strokePath()

        case .planner:
            // "Week of" header, then one band per day with a couple of writing lines.
            let top: CGFloat = 80, bottom = bounds.maxY - 30, margin: CGFloat = 36
            Self.label("Week of", at: CGPoint(x: margin, y: 34), in: ctx, size: 16)
            Self.line(in: ctx, from: CGPoint(x: margin + 70, y: 52), to: CGPoint(x: bounds.maxX - margin, y: 52), color: Self.ink, width: 0.8)
            let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            let band = (bottom - top) / CGFloat(days.count)
            for (i, day) in days.enumerated() {
                let y = top + CGFloat(i) * band
                Self.line(in: ctx, from: CGPoint(x: margin, y: y), to: CGPoint(x: bounds.maxX - margin, y: y), color: Self.ink, width: 1)
                Self.label(day, at: CGPoint(x: margin, y: y + 6), in: ctx)
                Self.ruledLines(in: ctx, from: y + 44, to: y + band - 6, x: margin...(bounds.maxX - margin), spacing: 24)
            }
            Self.line(in: ctx, from: CGPoint(x: margin, y: bottom), to: CGPoint(x: bounds.maxX - margin, y: bottom), color: Self.ink, width: 1)
        }
    }

    private static func ruledLines(in ctx: CGContext, from top: CGFloat, to bottom: CGFloat, x: ClosedRange<CGFloat>, spacing: CGFloat) {
        guard top < bottom else { return }
        ctx.setStrokeColor(rule.cgColor)
        ctx.setLineWidth(0.6)
        for y in stride(from: top, through: bottom, by: spacing) {
            ctx.move(to: CGPoint(x: x.lowerBound, y: y)); ctx.addLine(to: CGPoint(x: x.upperBound, y: y))
        }
        ctx.strokePath()
    }

    private static func line(in ctx: CGContext, from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.move(to: a); ctx.addLine(to: b)
        ctx.strokePath()
    }

    private static func label(_ text: String, at point: CGPoint, in ctx: CGContext, size: CGFloat = 11) {
        UIGraphicsPushContext(ctx)
        (text as NSString).draw(at: point, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: ink,
        ])
        UIGraphicsPopContext()
    }
}

/// A page saved by the user with "Save as Template": a single-page PDF in the app's own storage.
struct CustomTemplate: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    func makePage() -> PDFPage? { PDFDocument(url: url)?.page(at: 0) }
}

/// Anything a new page or notebook can be made from.
enum PageSource {
    case builtIn(PageTemplate)
    case custom(CustomTemplate)

    var title: String {
        switch self {
        case let .builtIn(template): template.title
        case let .custom(template): template.name
        }
    }

    /// Custom templates keep their own page size; built-ins use `size` (usually the current page's).
    func makePage(size: CGSize) -> PDFPage? {
        switch self {
        case let .builtIn(template): template.makePage(size: size)
        case let .custom(template): template.makePage()
        }
    }

    /// Writes a one-page notebook to a temporary file for the document browser to move into place.
    func makeNotebookFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Untitled Notebook.pdf")
        switch self {
        case let .builtIn(template):
            try template.pdfData().write(to: url)
        case let .custom(template):
            try FileManager.default.copyItem(at: template.url, to: url)
        }
        return url
    }
}

/// The user's saved templates, stored as PDFs in Application Support (on this device only).
final class TemplateLibrary {
    static let shared = TemplateLibrary()

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("Templates", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func all() -> [CustomTemplate] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
            .map(CustomTemplate.init(url:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func save(_ data: Data, named name: String) throws -> CustomTemplate {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Template" : cleaned
        var url = directory.appendingPathComponent(base).appendingPathExtension("pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension("pdf")
            counter += 1
        }
        try data.write(to: url, options: .atomic)
        return CustomTemplate(url: url)
    }

    func delete(_ template: CustomTemplate) throws {
        try FileManager.default.removeItem(at: template.url)
    }
}
