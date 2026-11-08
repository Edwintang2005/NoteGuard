import Testing
import Foundation
import CoreGraphics
@testable import NoteGuard

@Suite("Dead zones")
struct DeadZoneTests {
    let screen = CGSize(width: 1000, height: 1000)

    @Test func rectangleBlocksInsideAndPaddingOnly() {
        let zone = DeadZoneShape(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        #expect(zone.contains(CGPoint(x: 150, y: 150), screenSize: screen, padding: 0))
        #expect(!zone.contains(CGPoint(x: 305, y: 150), screenSize: screen, padding: 0))
        #expect(zone.contains(CGPoint(x: 305, y: 150), screenSize: screen, padding: 8))
        #expect(!zone.contains(CGPoint(x: 330, y: 150), screenSize: screen, padding: 8))
    }

    @Test func ellipseExcludesItsBoundingBoxCorners() {
        let zone = DeadZoneShape(kind: .ellipse, normalizedRect: CGRect(x: 0, y: 0, width: 0.4, height: 0.4))
        #expect(zone.contains(CGPoint(x: 200, y: 200), screenSize: screen, padding: 0))
        #expect(!zone.contains(CGPoint(x: 10, y: 10), screenSize: screen, padding: 0))
    }

    @Test func freehandUsesItsOutlineNotItsBox() {
        // An L shape: the notch at the top right is inside the bounding box but outside the zone.
        let points = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.2, y: 0.3),
                      CGPoint(x: 0.4, y: 0.3), CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.1, y: 0.4)]
        let zone = DeadZoneShape(kind: .freehand, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
                                 normalizedPoints: points)
        #expect(zone.contains(CGPoint(x: 150, y: 350), screenSize: screen, padding: 0))
        #expect(!zone.contains(CGPoint(x: 350, y: 150), screenSize: screen, padding: 0))
    }

    @Test func zonesSavedBeforeFreehandExistedStillDecode() throws {
        // Version 1 had no normalizedPoints key.
        let json = #"{"id":"6E1B0D6A-4E0B-4C3B-9A49-1E8D5A2C9F11","kind":"rectangle","normalizedRect":[[0.1,0.2],[0.3,0.4]]}"#
        let zone = try JSONDecoder().decode(DeadZoneShape.self, from: Data(json.utf8))
        #expect(zone.kind == .rectangle)
        #expect(zone.normalizedPoints == nil)
        #expect(zone.normalizedRect == CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    }

    @Test func normaliseRoundTrips() {
        let rect = CGRect(x: 120, y: 40, width: 300, height: 90)
        let n = DeadZoneShape.normalize(rect, in: screen)
        #expect(DeadZoneShape(kind: .rectangle, normalizedRect: n).rect(in: screen) == rect)
    }
}
