import UIKit
import PencilKit

/// The currently selected writing tool, shared by the toolbar and every page canvas.
final class InkToolState: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, highlighter, eraser, scroll
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .eraser: "eraser"
            case .scroll: "hand.raised"
            }
        }

        var label: String {
            switch self {
            case .scroll: "Scroll (one finger)"
            default: rawValue.capitalized
            }
        }

        var usesColor: Bool { self == .pen || self == .highlighter }
    }

    static let inks: [UIColor] = [.black, .systemBlue, .systemRed, .systemGreen]

    @Published var tool: Tool = .pen
    @Published var colorIndex = 0

    static func pkTool(_ tool: Tool, colorIndex: Int) -> PKTool {
        let color = inks[colorIndex]
        switch tool {
        case .pen, .scroll: return PKInkingTool(.pen, color: color, width: 3)
        case .highlighter: return PKInkingTool(.marker, color: color, width: 20)
        case .eraser: return PKEraserTool(.vector)
        }
    }
}
