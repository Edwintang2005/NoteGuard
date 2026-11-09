import UIKit
import Combine

/// One masked region of the glass: a rectangle, an ellipse, or a freehand outline.
///
/// Geometry is stored in the screen's *fixed* coordinate space (portrait, home button at the
/// bottom), normalised to 0...1. That keeps the zone glued to the physical crack through
/// rotation, Split View and Stage Manager, whatever the app's window happens to be doing.
struct DeadZoneShape: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case rectangle, ellipse, freehand
        var id: String { rawValue }
    }

    var id = UUID()
    var kind: Kind
    /// Bounding box (all kinds).
    var normalizedRect: CGRect
    /// Closed outline for `.freehand`; nil for the other kinds.
    var normalizedPoints: [CGPoint]?

    // MARK: Fixed-space geometry

    func rect(in screenSize: CGSize) -> CGRect {
        CGRect(x: normalizedRect.minX * screenSize.width,
               y: normalizedRect.minY * screenSize.height,
               width: normalizedRect.width * screenSize.width,
               height: normalizedRect.height * screenSize.height)
    }

    func points(in screenSize: CGSize) -> [CGPoint] {
        (normalizedPoints ?? []).map { CGPoint(x: $0.x * screenSize.width, y: $0.y * screenSize.height) }
    }

    /// The outline in fixed-space points.
    func fixedPath(screenSize: CGSize) -> CGPath {
        switch kind {
        case .rectangle: CGPath(rect: rect(in: screenSize), transform: nil)
        case .ellipse: CGPath(ellipseIn: rect(in: screenSize), transform: nil)
        case .freehand: Self.polygon(points(in: screenSize))
        }
    }

    /// Exactly the area the user masked: no margin, so every touch outside the outline counts.
    func contains(_ point: CGPoint, screenSize: CGSize) -> Bool {
        fixedPath(screenSize: screenSize).contains(point)
    }

    /// The outline converted into another coordinate space (e.g. a view), point by point so it
    /// stays exact when the interface is rotated relative to the glass.
    func path(from fixedSpace: UICoordinateSpace, to target: UICoordinateSpace) -> UIBezierPath {
        let size = fixedSpace.bounds.size
        switch kind {
        case .rectangle:
            return UIBezierPath(rect: fixedSpace.convert(rect(in: size), to: target))
        case .ellipse:
            return UIBezierPath(ovalIn: fixedSpace.convert(rect(in: size), to: target))
        case .freehand:
            let local = points(in: size).map { fixedSpace.convert($0, to: target) }
            return UIBezierPath(cgPath: Self.polygon(local))
        }
    }

    // MARK: Helpers

    static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// A band `distance` wide either side of the outline. Only the zone editor uses it, so thin
    /// zones are easy to grab; it never blocks touches.
    static func outlineBand(of path: CGPath, distance: CGFloat) -> CGPath {
        path.copy(strokingWithWidth: distance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    static func normalize(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
               width: rect.width / size.width, height: rect.height / size.height)
    }

    static func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x / size.width, y: point.y / size.height)
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
}

/// The user's dead-zone map plus shield settings, persisted across launches.
final class DeadZoneStore: ObservableObject {
    static let shared = DeadZoneStore()

    @Published var shapes: [DeadZoneShape] = [] { didSet { save() } }
    /// Master switch for the shield.
    @Published var isEnabled = true { didSet { save() } }
    /// Tint the zones on screen and flash each touch that gets blocked.
    @Published var showsZones = true { didSet { save() } }
    /// While the zone editor is open the shield steps aside so zones can be moved and resized.
    @Published var isEditing = false
    @Published private(set) var blockedCount = 0

    /// Fires with the fixed-space location of every blocked touch.
    let blockedTouch = PassthroughSubject<CGPoint, Never>()

    private struct Persisted: Codable {
        var shapes: [DeadZoneShape]
        var isEnabled: Bool
        /// Older versions blocked a margin around each zone. Still decoded, and ignored.
        var padding: Double?
        var showsZones: Bool
    }

    private let defaultsKey = "deadZones.v1"
    private let setupKey = "deadZones.setupShown"
    private var isLoading = false

    /// Whether the first-launch zone setup has been shown on this device. Zones and this flag live
    /// in this device's UserDefaults (not iCloud), since a crack belongs to one particular iPad.
    var hasShownSetup: Bool {
        get { UserDefaults.standard.bool(forKey: setupKey) }
        set { UserDefaults.standard.set(newValue, forKey: setupKey) }
    }

    init() { load() }

    func blocks(fixedPoint: CGPoint, screenSize: CGSize) -> Bool {
        guard isEnabled, !isEditing else { return false }
        return shapes.contains { $0.contains(fixedPoint, screenSize: screenSize) }
    }

    func recordBlocked(at fixedPoint: CGPoint) {
        blockedCount += 1
        blockedTouch.send(fixedPoint)
    }

    func resetBlockedCount() { blockedCount = 0 }

    func updateGeometry(_ id: UUID, normalizedRect: CGRect, normalizedPoints: [CGPoint]?) {
        guard let i = shapes.firstIndex(where: { $0.id == id }) else { return }
        shapes[i].normalizedRect = normalizedRect
        shapes[i].normalizedPoints = normalizedPoints
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        isLoading = true
        shapes = saved.shapes
        isEnabled = saved.isEnabled
        showsZones = saved.showsZones
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Persisted(shapes: shapes, isEnabled: isEnabled, showsZones: showsZones)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
