import Foundation

/// An exact circular arc in the document's sketch plane.
///
/// `startAngle` is the bearing of the start point in radians, measured from +X
/// counter-clockwise; `sweep` is signed and positive counter-clockwise. The arc
/// is a piece of exact geometry, not a sampled polyline: the tool layer encodes
/// it as rational quadratic NURBS, which the existing curve payload already
/// carries, so no document field, schema revision or format version changes.
struct FFArc2D: Equatable, Sendable {
    var center: Vec2
    var radius: Double
    var startAngle: Double
    var sweep: Double

    static let fullTurn = 2 * Double.pi

    /// Validates the defining values so an arc that could not be drawn or
    /// encoded cannot exist. Constructors below are the only intended callers;
    /// every one of them checks its own input first.
    init(center: Vec2, radius: Double, startAngle: Double, sweep: Double) throws {
        guard center.x.isFinite, center.y.isFinite, startAngle.isFinite, sweep.isFinite else {
            throw FFArcError.emptySweep
        }
        guard radius.isFinite, radius > FFMath.eps else {
            throw FFArcError.degenerateRadius
        }
        guard abs(sweep) > 1e-12, abs(sweep) <= Self.fullTurn + 1e-9 else {
            throw FFArcError.emptySweep
        }
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.sweep = sweep
    }

    var isClosed: Bool {
        abs(abs(sweep) - Self.fullTurn) <= 1e-12
    }

    var start: Vec2 { point(atFraction: 0) }
    var end: Vec2 { point(atFraction: 1) }
    var mid: Vec2 { point(atFraction: 0.5) }

    var sweepDegrees: Double { sweep * 180 / Double.pi }

    var arcLength: Double { abs(sweep) * radius }

    /// A point on the arc. `t` is clamped, so a renderer asking for the end
    /// point gets the end point rather than an extrapolation.
    func point(atFraction t: Double) -> Vec2 {
        let u = FFMath.clamp(t, to: 0...1)
        let angle = startAngle + sweep * u
        return center + Vec2(x: cos(angle), y: sin(angle)) * radius
    }

    // MARK: - Constructions

    /// The circle through three points, traversed from `start` through `through`
    /// to `end`. The middle point decides which of the two arcs is meant, so the
    /// result is the unique arc that actually passes through all three.
    static func through(_ startPoint: Vec2, _ through: Vec2, _ endPoint: Vec2) throws -> FFArc2D {
        guard isFinite(startPoint), isFinite(through), isFinite(endPoint) else {
            throw FFArcError.coincidentPoints
        }
        let first = through - startPoint
        let second = endPoint - startPoint
        guard first.length > FFTolerance.curveJoin,
              second.length > FFTolerance.curveJoin,
              (endPoint - through).length > FFTolerance.curveJoin
        else { throw FFArcError.coincidentPoints }

        let area = first.cross(second)
        guard abs(area) > 1e-12 * max(1, first.length * second.length) else {
            throw FFArcError.collinearPoints
        }

        let denominator = 2 * (
            startPoint.x * (through.y - endPoint.y)
            + through.x * (endPoint.y - startPoint.y)
            + endPoint.x * (startPoint.y - through.y)
        )
        guard abs(denominator) > Double.leastNormalMagnitude else {
            throw FFArcError.collinearPoints
        }

        let startSquared = startPoint.x * startPoint.x + startPoint.y * startPoint.y
        let throughSquared = through.x * through.x + through.y * through.y
        let endSquared = endPoint.x * endPoint.x + endPoint.y * endPoint.y
        let center = Vec2(
            x: (
                startSquared * (through.y - endPoint.y)
                + throughSquared * (endPoint.y - startPoint.y)
                + endSquared * (startPoint.y - through.y)
            ) / denominator,
            y: (
                startSquared * (endPoint.x - through.x)
                + throughSquared * (startPoint.x - endPoint.x)
                + endSquared * (through.x - startPoint.x)
            ) / denominator
        )
        guard isFinite(center) else { throw FFArcError.collinearPoints }

        let radius = (startPoint - center).length
        guard radius.isFinite, radius > FFMath.eps else { throw FFArcError.degenerateRadius }

        let startAngle = atan2(startPoint.y - center.y, startPoint.x - center.x)
        let throughAngle = atan2(through.y - center.y, through.x - center.x)
        let endAngle = atan2(endPoint.y - center.y, endPoint.x - center.x)
        let throughTurn = Self.normalisedTurn(throughAngle - startAngle)
        let endTurn = Self.normalisedTurn(endAngle - startAngle)
        let sweep = throughTurn <= endTurn ? endTurn : endTurn - Self.fullTurn
        guard abs(sweep) > 1e-12 else { throw FFArcError.emptySweep }
        return try FFArc2D(center: center, radius: radius, startAngle: startAngle, sweep: sweep)
    }

    /// The arc of the circle centred at `center` that starts at `start` and
    /// ends at the bearing of `end`. The radius is fixed by `start`, so `end`
    /// is projected onto that circle: the stored endpoint is always exactly on
    /// the arc. The shorter of the two possible sweeps is chosen, which is the
    /// arc a person means when both points are visible.
    static func centerStartEnd(center: Vec2, start: Vec2, end: Vec2) throws -> FFArc2D {
        guard isFinite(center), isFinite(start), isFinite(end) else {
            throw FFArcError.coincidentPoints
        }
        let radius = (start - center).length
        guard radius > FFMath.eps else { throw FFArcError.degenerateRadius }
        let endVector = end - center
        guard endVector.length > FFMath.eps else { throw FFArcError.emptySweep }

        let startAngle = atan2(start.y - center.y, start.x - center.x)
        let endAngle = atan2(endVector.y, endVector.x)
        var sweep = (endAngle - startAngle).truncatingRemainder(dividingBy: Self.fullTurn)
        if sweep <= -Double.pi { sweep += Self.fullTurn }
        if sweep > Double.pi { sweep -= Self.fullTurn }
        guard abs(sweep) > 1e-12 else { throw FFArcError.emptySweep }
        return try FFArc2D(center: center, radius: radius, startAngle: startAngle, sweep: sweep)
    }

    /// The unique circular arc that leaves `start` along `tangent` and reaches
    /// `end`. A positive tangent circle is traversed counter-clockwise and a
    /// negative one clockwise, so the initial tangent is always the direction
    /// the caller supplied. An end point on the tangent line has no such
    /// circle and is refused.
    static func tangent(start: Vec2, tangent: Vec2, end: Vec2) throws -> FFArc2D {
        guard isFinite(start), isFinite(tangent), isFinite(end) else {
            throw FFArcError.coincidentPoints
        }
        guard let direction = tangent.normalized() else { throw FFArcError.noTangentCircle }
        let chord = end - start
        guard chord.length > FFTolerance.curveJoin else { throw FFArcError.coincidentPoints }

        // The centre lies on the normal through the start point. Solving
        // |chord - signedRadius * normal| = |signedRadius| gives the signed
        // radius; its sign says which way round the circle the arc runs.
        let normal = Vec2(x: -direction.y, y: direction.x)
        let denominator = 2 * chord.dot(normal)
        guard abs(denominator) > 1e-12 * max(1, chord.length) else {
            throw FFArcError.noTangentCircle
        }
        let signedRadius = chord.lengthSquared / denominator
        guard signedRadius.isFinite, abs(signedRadius) > FFMath.eps else {
            throw FFArcError.noTangentCircle
        }

        let center = start + normal * signedRadius
        let radius = abs(signedRadius)
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        let endAngle = atan2(end.y - center.y, end.x - center.x)
        let forward = Self.normalisedTurn(endAngle - startAngle)
        let backward = Self.normalisedTurn(startAngle - endAngle)
        let sweep = signedRadius > 0 ? forward : -backward
        guard abs(sweep) > 1e-12, abs(sweep) < Self.fullTurn - 1e-12 else {
            throw FFArcError.emptySweep
        }
        return try FFArc2D(center: center, radius: radius, startAngle: startAngle, sweep: sweep)
    }

    /// The fillet arc preview for two legs meeting at `corner`. `first` and
    /// `second` are points along the legs; their directions decide the corner
    /// angle and their lengths bound how large a radius can fit. The returned
    /// arc's endpoints are the tangency points, so a preview can draw the
    /// trimmed corner without a second calculation.
    static func fillet(corner: Vec2, first: Vec2, second: Vec2, radius: Double) throws -> FFArc2D {
        guard isFinite(corner), isFinite(first), isFinite(second),
              radius.isFinite, radius > FFMath.eps
        else { throw FFArcError.degenerateRadius }

        let firstLeg = first - corner
        let secondLeg = second - corner
        guard firstLeg.length > FFTolerance.curveJoin,
              secondLeg.length > FFTolerance.curveJoin
        else { throw FFArcError.coincidentPoints }
        guard let firstDirection = firstLeg.normalized(),
              let secondDirection = secondLeg.normalized()
        else { throw FFArcError.coincidentPoints }

        let cosine = FFMath.clamp(firstDirection.dot(secondDirection), to: -1...1)
        let angle = acos(cosine)
        guard angle > 1e-9, angle < Double.pi - 1e-9 else { throw FFArcError.parallelLegs }

        let tangentDistance = radius / tan(angle / 2)
        guard tangentDistance.isFinite, tangentDistance > FFMath.eps else {
            throw FFArcError.degenerateRadius
        }
        guard tangentDistance <= firstLeg.length + 1e-9,
              tangentDistance <= secondLeg.length + 1e-9
        else { throw FFArcError.filletExceedsLeg }

        guard let bisector = (firstDirection + secondDirection).normalized() else {
            throw FFArcError.parallelLegs
        }
        let center = corner + bisector * (radius / sin(angle / 2))
        let startPoint = corner + firstDirection * tangentDistance
        let turn = firstDirection.cross(secondDirection)
        guard abs(turn) > 1e-12 else { throw FFArcError.parallelLegs }
        let sweep = (turn > 0 ? -1.0 : 1.0) * (Double.pi - angle)
        let startAngle = atan2(startPoint.y - center.y, startPoint.x - center.x)
        return try FFArc2D(center: center, radius: radius, startAngle: startAngle, sweep: sweep)
    }

    // MARK: - Helpers

    private static func isFinite(_ point: Vec2) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func normalisedTurn(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: Self.fullTurn)
        if value < 0 { value += fullTurn }
        return value
    }
}

/// Why an arc could not be constructed. Every case carries a sentence so a
/// refused tap explains itself instead of silently doing nothing.
enum FFArcError: Error, Equatable, LocalizedError {
    case coincidentPoints
    case collinearPoints
    case degenerateRadius
    case emptySweep
    case noTangentCircle
    case parallelLegs
    case filletExceedsLeg
    case notEnoughPoints

    var errorDescription: String? {
        switch self {
        case .coincidentPoints:
            return "An arc needs distinct points"
        case .collinearPoints:
            return "Three collinear points do not define an arc"
        case .degenerateRadius:
            return "An arc radius must be greater than zero"
        case .emptySweep:
            return "Those points do not sweep an arc"
        case .noTangentCircle:
            return "A tangent arc needs an end point that is not on the tangent line"
        case .parallelLegs:
            return "A fillet needs two legs that meet at an angle"
        case .filletExceedsLeg:
            return "That fillet radius does not fit inside both legs"
        case .notEnoughPoints:
            return "An arc needs three points"
        }
    }
}
