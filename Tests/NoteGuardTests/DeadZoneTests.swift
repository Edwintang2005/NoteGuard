import Testing
import Foundation
import CoreGraphics
@testable import NoteGuard

@Suite("Dead zones")
struct DeadZoneTests {
    let screen = CGSize(width: 1000, height: 1000)

    @Test func rectangleBlocksExactlyItsArea() {
        let zone = DeadZoneShape(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        #expect(zone.contains(CGPoint(x: 150, y: 150), screenSize: screen))
        #expect(zone.contains(CGPoint(x: 299, y: 150), screenSize: screen))
        // One point outside the edge is a valid touch: there's no margin.
        #expect(!zone.contains(CGPoint(x: 301, y: 150), screenSize: screen))
        #expect(!zone.contains(CGPoint(x: 150, y: 99), screenSize: screen))
    }

    @Test func storeIgnoresTheOldPaddingSetting() throws {
        // Older versions saved a padding margin (and blocked touches in it).
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "deadZones.v1")
        defer { defaults.set(previous, forKey: "deadZones.v1") }
        let json = #"{"shapes":[{"id":"6E1B0D6A-4E0B-4C3B-9A49-1E8D5A2C9F11","kind":"rectangle","normalizedRect":[[0.1,0.1],[0.2,0.2]]}],"isEnabled":true,"padding":30,"showsZones":true}"#
        defaults.set(Data(json.utf8), forKey: "deadZones.v1")

        let store = DeadZoneStore()
        #expect(store.shapes.count == 1)
        #expect(store.blocks(fixedPoint: CGPoint(x: 150, y: 150), screenSize: screen))
        #expect(!store.blocks(fixedPoint: CGPoint(x: 305, y: 150), screenSize: screen))
    }

    @Test func ellipseExcludesItsBoundingBoxCorners() {
        let zone = DeadZoneShape(kind: .ellipse, normalizedRect: CGRect(x: 0, y: 0, width: 0.4, height: 0.4))
        #expect(zone.contains(CGPoint(x: 200, y: 200), screenSize: screen))
        #expect(!zone.contains(CGPoint(x: 10, y: 10), screenSize: screen))
    }

    @Test func freehandUsesItsOutlineNotItsBox() {
        // An L shape: the notch at the top right is inside the bounding box but outside the zone.
        let points = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.2, y: 0.3),
                      CGPoint(x: 0.4, y: 0.3), CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.1, y: 0.4)]
        let zone = DeadZoneShape(kind: .freehand, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
                                 normalizedPoints: points)
        #expect(zone.contains(CGPoint(x: 150, y: 350), screenSize: screen))
        #expect(!zone.contains(CGPoint(x: 350, y: 150), screenSize: screen))
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
