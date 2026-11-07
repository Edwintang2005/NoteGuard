import UIKit
import PDFKit

/// Paper styles for new notebooks and inserted pages. The pattern is real PDF page content
/// (not ink), so the eraser never touches it and other apps show it too.
enum PageTemplate: String, CaseIterable, Identifiable {
    case blank, lined, grid, dotted

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .blank: "doc"
        case .lined: "line.3.horizontal"
        case .grid: "squareshape.split.3x3"
        case .dotted: "circle.grid.3x3"
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

    /// Writes a one-page notebook to a temporary file for the document browser to move into place.
    func makeNotebookFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Untitled Notebook.pdf")
        try pdfData().write(to: url)
        return url
    }

    private func draw(in ctx: CGContext, bounds: CGRect) {
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(bounds)
        let rule = UIColor(red: 0.62, green: 0.75, blue: 0.90, alpha: 1)

        switch self {
        case .blank:
            break

        case .lined:
            let spacing: CGFloat = 26
            ctx.setStrokeColor(rule.cgColor)
            ctx.setLineWidth(0.6)
            var y: CGFloat = 80
            while y < bounds.maxY - 30 {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += spacing
            }
            ctx.strokePath()
            ctx.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.45).cgColor)
            ctx.move(to: CGPoint(x: 64, y: 0))
            ctx.addLine(to: CGPoint(x: 64, y: bounds.maxY))
            ctx.strokePath()

        case .grid:
            let spacing: CGFloat = 20
            ctx.setStrokeColor(rule.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(0.4)
            var x = spacing
            while x < bounds.maxX {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
                x += spacing
            }
            var y = spacing
            while y < bounds.maxY {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += spacing
            }
            ctx.strokePath()

        case .dotted:
            let spacing: CGFloat = 20, r: CGFloat = 0.9
            ctx.setFillColor(UIColor(white: 0.6, alpha: 1).cgColor)
            var y = spacing
            while y < bounds.maxY {
                var x = spacing
                while x < bounds.maxX {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}
