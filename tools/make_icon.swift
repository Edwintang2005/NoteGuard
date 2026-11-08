// Renders the NoteGuard app icon ("kintsugi seam"): a crack in dark glass that turns into a line of
// handwriting, mended in gold. 1024×1024, opaque (App Store icons must have no alpha).
//
//   swift tools/make_icon.swift NoteGuard/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "NoteGuard/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

let c = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
c.translateBy(x: 0, y: S); c.scaleBy(x: 1, y: -1) // top-left origin

// Dark glass with a faint sheen.
c.drawLinearGradient(gradient([color(0x232838), color(0x0D0F17)]), start: P(0, 0), end: P(0, S), options: [])
c.drawRadialGradient(gradient([color(0xFFFFFF, 0.07), color(0xFFFFFF, 0)]),
                     startCenter: P(300, 220), startRadius: 0, endCenter: P(300, 220), endRadius: 620, options: [])

let gold = gradient([color(0xFBE29A), color(0xC8892B)])
func goldStroke(_ path: CGPath, width: CGFloat, alpha: CGFloat = 1) {
    c.saveGState()
    c.setAlpha(alpha)
    c.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4))
    c.clip()
    c.drawLinearGradient(gold, start: P(150, 900), end: P(880, 250),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

// Hairline side cracks near the corner.
let branches = CGMutablePath()
branches.move(to: P(232, 818)); branches.addLine(to: P(150, 790)); branches.addLine(to: P(96, 812))
branches.move(to: P(300, 712)); branches.addLine(to: P(350, 770)); branches.addLine(to: P(420, 790))
branches.move(to: P(205, 770)); branches.addLine(to: P(160, 700))
goldStroke(branches, width: 9, alpha: 0.55)

// Main seam: jagged crack → flowing cursive stroke.
let seam = CGMutablePath()
seam.move(to: P(118, 930))
seam.addLine(to: P(232, 818))
seam.addLine(to: P(205, 770))
seam.addLine(to: P(300, 712))
seam.addLine(to: P(285, 655))
seam.addLine(to: P(372, 600))
seam.addCurve(to: P(520, 470), control1: P(430, 565), control2: P(470, 520))
seam.addCurve(to: P(560, 330), control1: P(575, 415), control2: P(600, 345))
seam.addCurve(to: P(530, 470), control1: P(520, 318), control2: P(495, 420))
seam.addCurve(to: P(700, 420), control1: P(565, 520), control2: P(650, 480))
seam.addCurve(to: P(895, 215), control1: P(760, 350), control2: P(820, 255))

// Soft glow (a plain shadowed stroke; a clipped gradient would cut the glow off square), then gold.
c.saveGState()
c.setShadow(offset: .zero, blur: 46, color: color(0xF5C35A, 0.6))
c.addPath(seam)
c.setStrokeColor(color(0xE2AE4C)); c.setLineWidth(40); c.setLineCap(.round); c.setLineJoin(.round)
c.strokePath()
c.restoreGState()
goldStroke(seam, width: 40)

let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, c.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest), "failed to write \(out.path)")
print("wrote \(out.path)")
