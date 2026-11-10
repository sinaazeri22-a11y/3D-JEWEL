import Foundation

/// The three Phase 40 arc constructions, in the order a tool offers them.
/// The fillet preview is not a fourth mode: it is a construction of its own
/// because it derives its arc from two legs and a radius, not from three taps.
enum FFArcMode: String, CaseIterable, Identifiable, Sendable {
    case threePoint
    case centerStartEnd
    case tangent

    var id: String { rawValue }

    /// Every construction is defined by three points: the points themselves
    /// differ, but the draft can say how many taps remain without a mode switch.
    var pointCount: Int { 3 }

    var title: String {
        switch self {
        case .threePoint: return "3-point arc"
        case .centerStartEnd: return "Centre · start · end"
        case .tangent: return "Tangent arc"
        }
    }

    var hint: String {
        switch self {
        case .threePoint:
            return "Tap the start, a point on the arc, then the end"
        case .centerStartEnd:
            return "Tap the centre, the start, then the end bearing"
        case .tangent:
            return "Tap the start, a point along the tangent, then the end"
        }
    }
}

/// The live arc draft. It owns only transient tool state; a finished arc is an
/// ordinary curve node committed by the session, so undo, the journal and
/// autosave need no arc branch.
struct FFArcDraft: Equatable, Sendable {
    private(set) var mode: FFArcMode = .threePoint
    private(set) var points: [Vec2] = []
    private(set) var arc: FFArc2D?

    init() {}

    var isActive: Bool { !points.isEmpty }
    var isComplete: Bool { arc != nil }
    var pointCount: Int { mode.pointCount }

    /// World-space preview of the constructed arc, ready for a view to draw.
    /// Empty until the construction is complete.
    var preview: [Vec3] {
        arc.map { FFArcTool.previewPoints(for: $0) } ?? []
    }

    mutating func begin(mode: FFArcMode) {
        self.mode = mode
        points = []
        arc = nil
    }

    mutating func cancel() {
        self = FFArcDraft()
    }

    /// Adds one point. Returns true when that point completed the construction.
    /// A refused construction removes its point again, so the user can retap
    /// rather than being stuck with a draft that can never finish.
    @discardableResult
    mutating func add(_ point: Vec2) throws -> Bool {
        guard points.count < mode.pointCount else { return isComplete }
        if let last = points.last, last.distance(to: point) <= FFTolerance.curveJoin {
            throw FFArcError.coincidentPoints
        }
        points.append(point)
        guard points.count == mode.pointCount else { return false }
        do {
            arc = try Self.construct(mode: mode, points: points)
            return true
        } catch {
            points.removeLast()
            throw error
        }
    }

    /// The construction, separated from the draft so a caller can build the
    /// same arc from three known points without owning tool state.
    static func construct(mode: FFArcMode, points: [Vec2]) throws -> FFArc2D {
        guard points.count == mode.pointCount else { throw FFArcError.notEnoughPoints }
        switch mode {
        case .threePoint:
            return try FFArc2D.through(points[0], points[1], points[2])
        case .centerStartEnd:
            return try FFArc2D.centerStartEnd(
                center: points[0],
                start: points[1],
                end: points[2]
            )
        case .tangent:
            return try FFArc2D.tangent(
                start: points[0],
                tangent: points[1] - points[0],
                end: points[2]
            )
        }
    }

    func payload() throws -> FFCurvePayload {
        guard let arc else { throw FFArcError.notEnoughPoints }
        return FFArcTool.payload(for: arc)
    }
}

/// Turns exact arcs into the curve payload the document already stores.
///
/// A circular arc of sweep below 180° is exactly a rational quadratic Bézier
/// with control points at the two endpoints and the intersection of their
/// tangents, and weights `1, cos(sweep/2), 1`. Splitting a longer arc into
/// spans of at most 90° keeps that weight positive and well conditioned and is
/// still exact, so an arc costs no format change and no tessellation error.
enum FFArcTool {
    static let maximumSegmentSweep = Double.pi / 2

    static func segments(for arc: FFArc2D) -> [FFCurveSegment] {
        let count = max(1, Int(ceil(abs(arc.sweep) / maximumSegmentSweep - 1e-12)))
        let step = arc.sweep / Double(count)
        var result: [FFCurveSegment] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let startAngle = arc.startAngle + step * Double(index)
            let endAngle = startAngle + step
            let half = step / 2

            let startPoint = arc.center
                + Vec2(x: cos(startAngle), y: sin(startAngle)) * arc.radius
            let endPoint = arc.center
                + Vec2(x: cos(endAngle), y: sin(endAngle)) * arc.radius
            // The tangent intersection is the same formula for both sweep
            // signs: a negative `half` reverses the tangent offset with it.
            let tangent = Vec2(x: -sin(startAngle), y: cos(startAngle))
            let controlPoint = startPoint + tangent * (arc.radius * tan(half))
            let weight = cos(half)

            result.append(FFCurveSegment(
                kind: .nurbs,
                controlPoints: [FFPoint2(startPoint), FFPoint2(controlPoint), FFPoint2(endPoint)],
                weights: [1, weight, 1],
                degree: 2,
                knots: [0, 0, 0, 1, 1, 1]
            ))
        }
        return result
    }

    static func payload(for arc: FFArc2D) -> FFCurvePayload {
        FFCurvePayload(segments: segments(for: arc), isClosed: arc.isClosed)
    }

    /// Points for a view preview. This is display sampling only: the committed
    /// payload stays exact and the sampler never feeds back into it.
    static func previewPoints(for arc: FFArc2D, samples: Int = 48) -> [Vec3] {
        let count = max(2, samples)
        return (0...count).map { index in
            let point = arc.point(atFraction: Double(index) / Double(count))
            return Vec3(x: point.x, y: point.y, z: 0)
        }
    }
}
