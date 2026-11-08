import Combine
import CoreGraphics
import Foundation
import UIKit

/// The five measurements the Phase 19 row names. A kind states how many snapped
/// world points it consumes and how its one number is defined, so the session
/// and the label cannot disagree about what was measured.
enum FFMeasurementKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case distance
    case angle
    case radius
    case diameter
    case ringInnerDiameter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .distance: "Distance"
        case .angle: "Angle"
        case .radius: "Radius"
        case .diameter: "Diameter"
        case .ringInnerDiameter: "Ring inner Ø"
        }
    }

    /// The compact form the measurement card prints on its chips.
    var shortLabel: String {
        switch self {
        case .distance: "Dist"
        case .angle: "Angle"
        case .radius: "Radius"
        case .diameter: "Ø"
        case .ringInnerDiameter: "Ring Ø"
        }
    }

    var systemImage: String {
        switch self {
        case .distance: "ruler"
        case .angle: "angle"
        case .radius: "circle"
        case .diameter: "circle.dashed"
        case .ringInnerDiameter: "circle.circle"
        }
    }

    /// Distance takes two points; the angle and the three circle measurements
    /// take three. Both counts are exact, not a maximum: a measurement commits
    /// as soon as the last point lands.
    var pointCount: Int {
        switch self {
        case .distance: 2
        case .angle, .radius, .diameter, .ringInnerDiameter: 3
        }
    }

    var isAngular: Bool { self == .angle }
}

/// One snapped measurement point and where the snap came from. The provenance
/// is shown in the card so a jeweller can see that a value came from a vertex
/// rather than from a free tap.
struct FFMeasurementPoint: Equatable, Sendable {
    var position: Vec3
    var snap: FFSnapKind?

    init(position: Vec3, snap: FFSnapKind? = nil) {
        self.position = position
        self.snap = snap
    }

    init(_ snapPoint: FFSnapPoint) {
        self.init(position: snapPoint.position, snap: snapPoint.kind)
    }
}

/// A committed measurement. Values are millimetres for lengths and degrees for
/// angles; the display unit is applied only when the value becomes a string.
struct FFMeasurement: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: FFMeasurementKind
    var points: [FFMeasurementPoint]

    init(id: UUID = UUID(), kind: FFMeasurementKind, points: [FFMeasurementPoint]) {
        self.id = id
        self.kind = kind
        self.points = points
    }

    var isComplete: Bool { points.count == kind.pointCount }

    /// The measured number, or `nil` while the measurement is incomplete or
    /// degenerate (two coincident points, three collinear points).
    var value: Double? {
        guard isComplete else { return nil }
        switch kind {
        case .distance:
            guard points.count >= 2 else { return nil }
            let distance = (points[1].position - points[0].position).length
            return distance.isFinite ? distance : nil
        case .angle:
            return Self.angle(points[0].position, points[1].position, points[2].position)
        case .radius, .diameter, .ringInnerDiameter:
            guard let radius = Self.circumradius(
                points[0].position,
                points[1].position,
                points[2].position
            ) else { return nil }
            return kind == .radius ? radius : radius * 2
        }
    }

    /// The value as a person reads it in the requested unit. Angle is the only
    /// kind that is not a length, so it stays in degrees in both unit modes.
    func displayText(_ unit: FFLengthUnit) -> String {
        guard let value else { return "—" }
        switch kind {
        case .angle:
            return FFPrecision.angleString(degrees: value)
        case .distance:
            return FFPrecision.lengthString(millimetres: value, unit: unit)
        case .radius:
            return "R " + FFPrecision.lengthString(millimetres: value, unit: unit)
        case .diameter:
            return "Ø " + FFPrecision.lengthString(millimetres: value, unit: unit)
        case .ringInnerDiameter:
            // The inner diameter is what a jeweller quotes, and the US size is
            // the trade label derived from it (Phase 11's conversion). The US
            // size has its own coarser, documented precision.
            let diameter = FFPrecision.lengthString(millimetres: value, unit: unit)
            let us = FFRingSize(innerDiameterMM: value).usSize
            return "Ø \(diameter) · US "
                + FFPrecision.fixed(us, decimals: FFPrecision.usRingSizeDecimals)
        }
    }

    /// Angle at `vertex` between the rays to `a` and `b`, in degrees. A
    /// coincident point leaves the angle undefined rather than returning 90°.
    static func angle(_ a: Vec3, _ vertex: Vec3, _ b: Vec3) -> Double? {
        let first = a - vertex
        let second = b - vertex
        let firstLength = first.length
        let secondLength = second.length
        guard firstLength > FFTolerance.measurement,
              secondLength > FFTolerance.measurement
        else { return nil }
        let cosine = FFMath.clamp(
            first.dot(second) / (firstLength * secondLength),
            to: -1...1
        )
        let degrees = acos(cosine) * 180 / .pi
        return degrees.isFinite ? degrees : nil
    }

    /// Circumradius of the circle through three points, from the triangle's
    /// side lengths and twice its area. Collinear points have no circle.
    static func circumradius(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double? {
        let ab = b - a
        let ac = c - a
        let bc = c - b
        let twiceArea = ab.cross(ac).length
        guard twiceArea > FFTolerance.measurement else { return nil }
        let radius = ab.length * ac.length * bc.length / (2 * twiceArea)
        guard radius.isFinite, radius > 0 else { return nil }
        return radius
    }
}

/// A committed measurement in file form. Phase 19 stored measurements only in
/// the pane session; Phase 23 promotes them to document annotations, so the
/// save file owns the value and the undo stack owns the commit. Points are
/// plain triples and snap provenance is the kind's raw value, keeping the file
/// independent of the kernel types.
struct FFMeasurementAnnotation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: FFMeasurementKind
    var points: [FFPoint3]
    /// One entry per point; `nil` is a point the snap engine did not label.
    var snaps: [String?]

    init(_ measurement: FFMeasurement) {
        self.id = measurement.id
        self.kind = measurement.kind
        self.points = measurement.points.map { FFPoint3($0.position) }
        self.snaps = measurement.points.map { $0.snap?.rawValue }
    }

    var measurement: FFMeasurement {
        let restored = zip(points, snaps).map { pair -> FFMeasurementPoint in
            let (point, snap) = pair
            return FFMeasurementPoint(
                position: point.vector,
                snap: snap.flatMap(FFSnapKind.init(rawValue:))
            )
        }
        return FFMeasurement(id: id, kind: kind, points: restored)
    }
}

/// A measurement's on-screen chip: the text, the face it is drawn at, and the
/// rectangle it occupies. The rectangle is already clamped inside the viewport,
/// which is what the row's "unclipped at 3 zoom levels" asks for: the anchor
/// moves with the zoom, the label never leaves the frame.
struct FFMeasurementLabel: Equatable {
    let text: String
    let fontSize: CGFloat
    let rect: CGRect
}

enum FFMeasurementLabelLayout {
    /// 11 pt is above the row's 9 pt floor and still small enough not to cover
    /// the geometry it annotates.
    static let fontSize: CGFloat = 11
    static let minimumFontSize: CGFloat = 9
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 4
    static let margin: CGFloat = 6
    /// The chip sits above its anchor so it does not cover the measured points.
    static let gap: CGFloat = 10

    static func label(text: String, anchor: Vec2, viewport: Vec2) -> FFMeasurementLabel? {
        guard viewport.x > 0, viewport.y > 0,
              anchor.x.isFinite, anchor.y.isFinite
        else { return nil }
        let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let width = ceil(measured.width) + horizontalPadding * 2
        let height = ceil(measured.height) + verticalPadding * 2
        guard width.isFinite, height.isFinite else { return nil }

        var x = CGFloat(anchor.x) - width / 2
        var y = CGFloat(anchor.y) - height - gap
        // A viewport narrower than the chip pins to the top-left margin rather
        // than inverting the clamp.
        let maxX = max(margin, CGFloat(viewport.x) - width - margin)
        let maxY = max(margin, CGFloat(viewport.y) - height - margin)
        x = min(max(x, margin), maxX)
        y = min(max(y, margin), maxY)
        return FFMeasurementLabel(
            text: text,
            fontSize: fontSize,
            rect: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}

/// Turns a viewport tap into the point the tool measures between. A point is
/// taken only when Phase 16's snapping engine finds a candidate within finger
/// tolerance, so every measurement sits on real geometry rather than on a free
/// tap that merely looks close.
enum FFMeasurementSnap {
    static let fingerTolerance: Double = 12

    static func point(
        at tap: Vec2,
        scene: FFViewportScene,
        camera: FFCamera,
        viewport: Vec2,
        tolerance: Double = FFMeasurementSnap.fingerTolerance
    ) -> FFMeasurementPoint? {
        guard viewport.x > FFMath.eps, viewport.y > FFMath.eps,
              tap.x.isFinite, tap.y.isFinite, tolerance > 0
        else { return nil }
        let geometry = FFSnapGeometry.features(
            of: scene,
            selectedIDs: Set(scene.nodes.filter(\.isVisible).map(\.id))
        )
        guard let result = FFSnapResolver.resolve(
            hover: tap,
            reference: nil,
            geometry: geometry,
            camera: camera,
            viewport: viewport,
            tolerance: tolerance
        ) else { return nil }
        return FFMeasurementPoint(position: result.best.position, snap: result.best.kind)
    }
}

/// The live measurement tool. It owns the draft points and the committed list;
/// the document is untouched, exactly like the gumball session, because the row
/// asks for the tool and its labels, not for saved annotations.
final class FFMeasurementSession: ObservableObject {
    @Published private(set) var measurements: [FFMeasurement] = []
    @Published private(set) var draft: [FFMeasurementPoint] = []
    @Published var kind: FFMeasurementKind = .distance

    var latest: FFMeasurement? { measurements.last }

    var draftValue: Double? {
        FFMeasurement(kind: kind, points: draft).value
    }

    /// Switching kind abandons an unfinished measurement; a committed one is
    /// already its own record and stays.
    func select(_ kind: FFMeasurementKind) {
        guard self.kind != kind else { return }
        self.kind = kind
        draft = []
    }

    /// Adds one snapped world point. Returns the committed measurement when the
    /// point was the last the kind needs; degenerate completions are dropped
    /// rather than shown as a dash.
    @discardableResult
    func add(_ point: FFSnapPoint) -> FFMeasurement? {
        add(FFMeasurementPoint(point))
    }

    @discardableResult
    func add(_ point: FFMeasurementPoint) -> FFMeasurement? {
        draft.append(point)
        guard draft.count >= kind.pointCount else { return nil }
        let measurement = FFMeasurement(kind: kind, points: Array(draft.prefix(kind.pointCount)))
        draft = []
        guard measurement.value != nil else { return nil }
        measurements.append(measurement)
        return measurement
    }

    func cancelDraft() {
        draft = []
    }

    func clear() {
        draft = []
        measurements = []
    }

    /// Mirrors the document's annotations into this tool session. The document
    /// is the owner; this copy exists so the Phase 19 session API and its
    /// tests keep describing the same committed list the viewport renders.
    func replaceCommitted(_ measurements: [FFMeasurement]) {
        self.measurements = measurements
    }
}
