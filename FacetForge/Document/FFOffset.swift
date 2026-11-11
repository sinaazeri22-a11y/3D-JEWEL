import Foundation

/// How an offset treats a corner where two source spans meet at an angle.
/// `round` sweeps a radius-|distance| arc about the shared vertex, which is the
/// boundary of the offset region at a convex corner. `miter` extends both offset
/// legs to their intersection while the miter length stays inside `limit` times
/// the offset distance, and falls back to round beyond it, so a sharp spike can
/// never shoot far off the curve. The fallback is deliberate and reported by the
/// corner count, not silently ignored.
enum FFOffsetCorner: Equatable, Sendable {
    case round
    case miter(limit: Double)

    static let defaultMiterLimit = 2.0

    var label: String {
        switch self {
        case .round: "Round"
        case .miter: "Miter"
        }
    }

    /// A miter limit below one has no meaning, and a non-finite limit would
    /// disable the guard, so both resolve to the documented default.
    var miterLimit: Double {
        switch self {
        case .round:
            return 0
        case .miter(let limit):
            guard limit.isFinite else { return Self.defaultMiterLimit }
            return max(1, limit)
        }
    }
}

/// Why an offset was refused. Every case carries a sentence because a refused
/// offset must explain itself rather than return a broken curve.
enum FFOffsetError: Error, Equatable, LocalizedError, Sendable {
    case emptyCurve
    case distance(Double)
    case tolerance(Double)
    case degenerateTangent(segment: Int)
    case tooManyPoints(segment: Int)
    case collapsedOffset
    case uncleanOffset(Int)

    var errorDescription: String? {
        switch self {
        case .emptyCurve:
            return "The curve has no spans to offset"
        case .distance(let value):
            return "An offset needs a finite, non-zero distance (got \(FFPrecision.fixed(value, decimals: 4)) mm)"
        case .tolerance(let value):
            return "An offset tolerance must be finite and greater than zero (got \(FFPrecision.fixed(value, decimals: 6)) mm)"
        case .degenerateTangent(let segment):
            return "Segment \(segment + 1) has no tangent to offset along"
        case .tooManyPoints(let segment):
            return "Segment \(segment + 1) needs more points than an offset may use; loosen the tolerance"
        case .collapsedOffset:
            return "The offset collapsed; the distance is larger than the curve's own feature size"
        case .uncleanOffset(let count):
            let crossings = count == 1 ? "1 crossing" : "\(count) crossings"
            return "The offset still crosses itself at \(crossings); reduce the distance"
        }
    }
}

/// What one offset changed, in numbers a panel can show. `removedPoints` counts
/// every raw offset point dropped by the feature-size filter or the loop
/// remover, so "nothing was cleaned" and "the fold was trimmed away" are
/// distinguishable.
struct FFOffsetReport: Equatable, Sendable {
    var pointCount: Int
    var cornerCount: Int
    var removedPoints: Int
    var removedLoops: Int
    var isClosed: Bool

    var summary: String {
        let points = pointCount == 1 ? "1 point" : "\(pointCount) points"
        let corners = cornerCount == 1 ? "1 corner" : "\(cornerCount) corners"
        guard removedPoints > 0 || removedLoops > 0 else {
            return "\(points) · \(corners)"
        }
        return "\(points) · \(corners) · trimmed \(removedPoints + removedLoops)"
    }
}

/// A finished offset: the payload to commit and the report that explains it.
struct FFOffsetResult: Equatable, Sendable {
    var payload: FFCurvePayload
    var report: FFOffsetReport
}

/// Self-intersection evidence for an offset result. Kept beside the offset so a
/// caller can prove the "leaves no self-intersections" property instead of
/// trusting the refusal gate, and so the scanner itself can be tested against a
/// shape that does cross.
enum FFOffsetDiagnostics {
    /// The vertex sequence of a polyline payload, or nil when a span is not a
    /// two-point Bézier. Offset output is always a polyline, so a nil here means
    /// the caller passed some other curve.
    static func vertices(of payload: FFCurvePayload) -> [Vec2]? {
        guard !payload.segments.isEmpty else { return nil }
        var result: [Vec2] = []
        for (index, segment) in payload.segments.enumerated() {
            guard segment.kind == .bezier,
                  segment.controlPoints.count == 2
            else { return nil }
            if index == 0 {
                result.append(segment.controlPoints[0].vector)
            }
            result.append(segment.controlPoints[1].vector)
        }
        return result
    }

    /// Segment-index pairs that cross properly, ignoring shared endpoints and
    /// the closing segment's shared vertex. Collinear overlaps are not counted:
    /// they carry no crossing point to splice, and a polyline offset does not
    /// produce them.
    static func selfIntersections(in points: [Vec2], isClosed: Bool) -> [(Int, Int)] {
        let segmentCount = isClosed ? points.count : points.count - 1
        guard segmentCount >= 2 else { return [] }
        var result: [(Int, Int)] = []
        for first in 0..<segmentCount {
            let a = points[first]
            let b = points[(first + 1) % points.count]
            for second in (first + 1)..<segmentCount {
                if second == first + 1 { continue }
                if isClosed, first == 0, second == segmentCount - 1 { continue }
                let c = points[second]
                let d = points[(second + 1) % points.count]
                if crosses(a, b, c, d) {
                    result.append((first, second))
                }
            }
        }
        return result
    }

    static func selfIntersections(in payload: FFCurvePayload) -> [(Int, Int)] {
        guard let points = vertices(of: payload) else { return [] }
        return selfIntersections(in: points, isClosed: payload.isClosed)
    }

    private static func crosses(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let epsilon = 1e-12
        let first = (b - a).cross(c - a)
        let second = (b - a).cross(d - a)
        let third = (d - c).cross(a - c)
        let fourth = (d - c).cross(b - c)
        let straddlesOne = (first > epsilon && second < -epsilon)
            || (first < -epsilon && second > epsilon)
        let straddlesTwo = (third > epsilon && fourth < -epsilon)
            || (third < -epsilon && fourth > epsilon)
        return straddlesOne && straddlesTwo
    }
}

/// A tolerance-driven offset of an `FFCurvePayload`.
///
/// The result is a polyline in the same curve payload the document already
/// stores, so no format or schema byte moves. Every generated vertex lies
/// exactly on the true offset `P(t) + distance · n(t)`; the chords between them
/// are refined until their midpoint misses that true offset by no more than the
/// requested tolerance. That is what makes the minimum distance to the source
/// stay inside the caller's bound rather than approximately near it.
///
/// The offset is computed in the payload's own sketch plane. A node keeps its
/// transform, so the curve the app draws is the 3-D offset of the curve the user
/// drew; a non-planar payload has no offset here because the format has no
/// non-planar curve to offset.
enum FFOffset {
    /// Half the row's 1e-3 mm acceptance, so the measured deviation has room for
    /// the chord's own rounding rather than sitting on the boundary.
    static let tolerance = 5e-4
    /// A hard ceiling on one span's sampling. Exceeding it is a refusal, never a
    /// silent coarsening of the tolerance.
    static let maxPoints = 20_000
    private static let maxDepth = 14

    /// Offsets a payload by a signed distance. A positive distance offsets to the
    /// left of the direction of travel, a negative one to the right, which is the
    /// same convention the curve kernel's normals use.
    static func offset(
        _ payload: FFCurvePayload,
        by distance: Double,
        corner: FFOffsetCorner = .round,
        tolerance: Double = FFOffset.tolerance
    ) throws -> FFOffsetResult {
        guard !payload.segments.isEmpty else { throw FFOffsetError.emptyCurve }
        guard distance.isFinite, distance != 0 else {
            throw FFOffsetError.distance(distance)
        }
        guard tolerance.isFinite, tolerance > 0 else {
            throw FFOffsetError.tolerance(tolerance)
        }

        var curves: [Curve2D] = []
        curves.reserveCapacity(payload.segments.count)
        for segment in payload.segments {
            guard let curve = segment.curve else { throw FFOffsetError.emptyCurve }
            curves.append(curve)
        }

        var spanned: [[Vec2]] = []
        spanned.reserveCapacity(curves.count)
        for (index, curve) in curves.enumerated() {
            spanned.append(try sampledPoints(
                of: curve,
                distance: distance,
                tolerance: tolerance,
                segment: index
            ))
        }

        var points = spanned[0]
        var cornerCount = 0
        if curves.count > 1 {
            for index in 1..<curves.count {
                let added = try cornerPoints(
                    arriving: points[points.count - 1],
                    departing: spanned[index][0],
                    vertex: curves[index - 1].end,
                    arrivingDirection: curves[index - 1].derivative(at: 1),
                    departingDirection: curves[index].derivative(at: 0),
                    distance: distance,
                    corner: corner,
                    tolerance: tolerance
                )
                if !added.isEmpty { cornerCount += 1 }
                points.append(contentsOf: added)
                // A fill stops short of the departing point: an arc's interior
                // points end one chord before it, and a miter or inner
                // intersection lies on the outgoing leg. Dropping the departing
                // point here would splice the last corner sample straight to the
                // span's far end, cutting the corner across the band.
                if added.isEmpty {
                    points.append(contentsOf: spanned[index].dropFirst())
                } else {
                    points.append(contentsOf: spanned[index])
                }
            }
        }

        if payload.isClosed {
            let added = try cornerPoints(
                arriving: points[points.count - 1],
                departing: points[0],
                vertex: curves[curves.count - 1].end,
                arrivingDirection: curves[curves.count - 1].derivative(at: 1),
                departingDirection: curves[0].derivative(at: 0),
                distance: distance,
                corner: corner,
                tolerance: tolerance
            )
            if !added.isEmpty { cornerCount += 1 }
            points.append(contentsOf: added)
            // A ring closes only when its last vertex is its first. A payload
            // whose last span already ends on the start point must not gain a
            // zero-length span, which no curve kernel can sample.
            if let first = points.first, let last = points.last,
               last.distance(to: first) > 1e-12 {
                points.append(first)
            }
        }

        let rawCount = points.count
        points = filtered(points, curves: curves, distance: distance, tolerance: tolerance)
        guard points.count >= 2 else {
            throw FFOffsetError.collapsedOffset
        }
        if payload.isClosed {
            // Filtering can remove the ring's own seam pair, so the closing edge
            // is restored explicitly rather than left implied by coordinates that
            // no longer exist.
            if let first = points.first, let last = points.last,
               last.distance(to: first) > 1e-12 {
                points.append(first)
            }
            guard points.count >= 4 else { throw FFOffsetError.collapsedOffset }
        }

        var removedLoops = 0
        if !payload.isClosed {
            let cleaned = removingLoops(points)
            points = cleaned.points
            removedLoops = cleaned.removals
            guard points.count >= 2 else { throw FFOffsetError.collapsedOffset }
        }

        let crossings = FFOffsetDiagnostics.selfIntersections(
            in: points,
            isClosed: payload.isClosed
        )
        guard crossings.isEmpty else {
            throw FFOffsetError.uncleanOffset(crossings.count)
        }

        var segments: [FFCurveSegment] = []
        segments.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(points[index - 1]), FFPoint2(points[index])]
            ))
        }

        let report = FFOffsetReport(
            pointCount: points.count,
            cornerCount: cornerCount,
            removedPoints: max(0, rawCount - points.count),
            removedLoops: removedLoops,
            isClosed: payload.isClosed
        )
        return FFOffsetResult(
            payload: FFCurvePayload(segments: segments, isClosed: payload.isClosed),
            report: report
        )
    }

    // MARK: - Sampling

    /// The true offset point at a parameter: the curve point moved along its unit
    /// left normal by `distance`. Nil when the tangent has no direction, which is
    /// a cusp rather than an offset.
    private static func offsetPoint(
        of curve: Curve2D,
        at parameter: Double,
        distance: Double,
        segment: Int
    ) throws -> Vec2 {
        let tangent = curve.derivative(at: parameter)
        guard tangent.length > FFMath.eps,
              let direction = tangent.normalized()
        else {
            throw FFOffsetError.degenerateTangent(segment: segment)
        }
        let normal = Vec2(x: -direction.y, y: direction.x)
        return curve.point(at: parameter) + normal * distance
    }

    private static func sampledPoints(
        of curve: Curve2D,
        distance: Double,
        tolerance: Double,
        segment: Int
    ) throws -> [Vec2] {
        let start = try offsetPoint(of: curve, at: 0, distance: distance, segment: segment)
        let end = try offsetPoint(of: curve, at: 1, distance: distance, segment: segment)
        var points: [Vec2] = [start]
        try subdivide(
            curve,
            from: 0,
            to: 1,
            fromPoint: start,
            toPoint: end,
            depth: 0,
            distance: distance,
            tolerance: tolerance,
            segment: segment,
            points: &points
        )
        return points
    }

    /// Halves the interval while the chord misses the true offset by more than
    /// the tolerance. The chord is accepted only when its middle, its first
    /// quarter and its third quarter all sit within tolerance of the true offset
    /// at the matching parameter; one midpoint is not enough to catch an
    /// inflection, where the midpoint sits on the chord while the span bulges.
    private static func subdivide(
        _ curve: Curve2D,
        from start: Double,
        to end: Double,
        fromPoint startPoint: Vec2,
        toPoint endPoint: Vec2,
        depth: Int,
        distance: Double,
        tolerance: Double,
        segment: Int,
        points: inout [Vec2]
    ) throws {
        let middle = (start + end) * 0.5
        let trueMiddle = try offsetPoint(of: curve, at: middle, distance: distance, segment: segment)
        let chordMiddle = (startPoint + endPoint) * 0.5
        // A midpoint alone accepts a whole S-shaped span whose midpoint happens
        // to sit on its chord while the curve bulges on both sides of it. The
        // quarter parameters are the cheapest second and third opinion, and they
        // are the same parameters the offset's distance proof probes.
        let quarter = (start + middle) * 0.5
        let threeQuarter = (middle + end) * 0.5
        let trueQuarter = try offsetPoint(of: curve, at: quarter, distance: distance, segment: segment)
        let trueThreeQuarter = try offsetPoint(
            of: curve,
            at: threeQuarter,
            distance: distance,
            segment: segment
        )
        let firstHalfMiss = trueQuarter.distance(to: (startPoint + trueMiddle) * 0.5)
        let secondHalfMiss = trueThreeQuarter.distance(to: (trueMiddle + endPoint) * 0.5)
        let missesTheOffset = trueMiddle.distance(to: chordMiddle) > tolerance
            || firstHalfMiss > tolerance
            || secondHalfMiss > tolerance
        if missesTheOffset, depth < maxDepth {
            try subdivide(
                curve,
                from: start,
                to: middle,
                fromPoint: startPoint,
                toPoint: trueMiddle,
                depth: depth + 1,
                distance: distance,
                tolerance: tolerance,
                segment: segment,
                points: &points
            )
            try subdivide(
                curve,
                from: middle,
                to: end,
                fromPoint: trueMiddle,
                toPoint: endPoint,
                depth: depth + 1,
                distance: distance,
                tolerance: tolerance,
                segment: segment,
                points: &points
            )
        } else {
            points.append(endPoint)
            guard points.count <= maxPoints else {
                throw FFOffsetError.tooManyPoints(segment: segment)
            }
        }
    }

    // MARK: - Corners

    /// The points between two offset spans at a join. An empty result means the
    /// spans already meet, which is a tangent-continuous join and needs no corner.
    private static func cornerPoints(
        arriving: Vec2,
        departing: Vec2,
        vertex: Vec2,
        arrivingDirection: Vec2,
        departingDirection: Vec2,
        distance: Double,
        corner: FFOffsetCorner,
        tolerance: Double
    ) throws -> [Vec2] {
        guard arriving.distance(to: departing) > tolerance else { return [] }
        let radius = abs(distance)
        // The two sides of a corner are not the same shape. Offsetting towards
        // the inside of the turn gives a corner whose two legs cross; the only
        // point on both is their intersection, and the raw leg ends lie on the
        // source itself, so the feature-size filter removes them and the
        // intersection is what survives. Offsetting towards the outside gives a
        // gap, which round or miter fills. Getting this backwards puts an arc
        // inside the offset band, closer to the source than the distance asked
        // for, which is exactly what the acceptance measures.
        let turn = arrivingDirection.cross(departingDirection)
        let side: Double = distance > 0 ? 1 : -1
        if turn * side > 0, let inner = miterPoint(
            arriving: arriving,
            departing: departing,
            arrivingDirection: arrivingDirection,
            departingDirection: departingDirection
        ) {
            return [inner]
        }
        switch corner {
        case .round:
            return arcPoints(
                from: arriving,
                to: departing,
                centre: vertex,
                radius: radius,
                tolerance: tolerance
            )
        case .miter:
            if let miter = miterPoint(
                arriving: arriving,
                departing: departing,
                arrivingDirection: arrivingDirection,
                departingDirection: departingDirection
            ), miter.distance(to: vertex) <= corner.miterLimit * radius {
                return [miter]
            }
            return arcPoints(
                from: arriving,
                to: departing,
                centre: vertex,
                radius: radius,
                tolerance: tolerance
            )
        }
    }

    /// The arc about the shared vertex, from the arriving offset point to the
    /// departing one, always the short way round. Its chord count follows the
    /// same chord tolerance as the spans, so a rounded corner is no coarser than
    /// the curve it joins.
    private static func arcPoints(
        from arriving: Vec2,
        to departing: Vec2,
        centre: Vec2,
        radius: Double,
        tolerance: Double
    ) -> [Vec2] {
        guard radius > FFMath.eps else { return [] }
        let startAngle = atan2(arriving.y - centre.y, arriving.x - centre.x)
        let endAngle = atan2(departing.y - centre.y, departing.x - centre.x)
        var sweep = endAngle - startAngle
        while sweep > Double.pi { sweep -= 2 * Double.pi }
        while sweep < -Double.pi { sweep += 2 * Double.pi }
        guard abs(sweep) > 1e-12 else { return [] }

        let step = maxChordAngle(radius: radius, tolerance: tolerance)
        let count = max(1, Int((abs(sweep) / step).rounded(.up)))
        var result: [Vec2] = []
        result.reserveCapacity(max(0, count - 1))
        if count > 1 {
            for index in 1..<count {
                let angle = startAngle + sweep * Double(index) / Double(count)
                result.append(Vec2(
                    x: centre.x + radius * cos(angle),
                    y: centre.y + radius * sin(angle)
                ))
            }
        }
        return result
    }

    /// The largest central angle whose chord misses the arc by no more than the
    /// tolerance, with a floor so a tiny tolerance cannot ask for endless points.
    private static func maxChordAngle(radius: Double, tolerance: Double) -> Double {
        guard radius > tolerance else { return Double.pi / 2 }
        let cosine = FFMath.clamp(1 - tolerance / radius, to: -1...1)
        return max(1e-3, 2 * acos(cosine))
    }

    /// The intersection of the two offset legs. For a polyline corner this is the
    /// exact miter point; for a curved span it is the miter of the end tangents,
    /// which is the same construction a drafting offset uses.
    private static func miterPoint(
        arriving: Vec2,
        departing: Vec2,
        arrivingDirection: Vec2,
        departingDirection: Vec2
    ) -> Vec2? {
        guard let first = arrivingDirection.normalized(),
              let second = departingDirection.normalized()
        else { return nil }
        let denominator = first.cross(second)
        guard abs(denominator) > 1e-9 else { return nil }
        let offset = departing - arriving
        let travel = offset.cross(second) / denominator
        guard travel.isFinite else { return nil }
        return arriving + first * travel
    }

    // MARK: - Spike cleanup

    /// Drops raw offset points that fall inside the source's own band. When the
    /// offset distance exceeds the local feature size, the offset turns back on
    /// itself; those inverted points are closer to the source than the distance
    /// asked for, so they are not on the offset boundary at all.
    private static func filtered(
        _ points: [Vec2],
        curves: [Curve2D],
        distance: Double,
        tolerance: Double
    ) -> [Vec2] {
        let threshold = abs(distance) - tolerance
        var result: [Vec2] = []
        result.reserveCapacity(points.count)
        for point in points {
            if sourceDistance(point, curves: curves) >= threshold {
                result.append(point)
            }
        }
        return result
    }

    private static func sourceDistance(_ point: Vec2, curves: [Curve2D]) -> Double {
        var best = Double.infinity
        for curve in curves {
            let candidate = curve.closestPoint(to: point).distance
            if candidate < best { best = candidate }
        }
        return best
    }

    /// Removes crossings by splicing the polyline at each one. Every pass drops
    /// at least one vertex, so the loop terminates; the cap is a second guard
    /// against a pathological sequence rather than the termination argument.
    static func removingLoops(_ points: [Vec2]) -> (points: [Vec2], removals: Int) {
        var result = points
        var removals = 0
        var passes = 0
        while result.count > 3, passes < 512 {
            passes += 1
            guard let crossing = firstCrossing(in: result) else { break }
            var spliced = Array(result[0...crossing.first])
            spliced.append(crossing.point)
            if crossing.second + 1 < result.count {
                spliced.append(contentsOf: result[(crossing.second + 1)...])
            }
            result = spliced
            removals += 1
        }
        return (result, removals)
    }

    private static func firstCrossing(
        in points: [Vec2]
    ) -> (first: Int, second: Int, point: Vec2)? {
        guard points.count >= 4 else { return nil }
        for first in 0..<(points.count - 1) {
            let a = points[first]
            let b = points[first + 1]
            guard first + 2 < points.count else { continue }
            for second in (first + 2)..<(points.count - 1) {
                let c = points[second]
                let d = points[second + 1]
                if let crossing = segmentCrossing(a, b, c, d) {
                    return (first, second, crossing)
                }
            }
        }
        return nil
    }

    private static func segmentCrossing(
        _ a: Vec2,
        _ b: Vec2,
        _ c: Vec2,
        _ d: Vec2
    ) -> Vec2? {
        let first = b - a
        let second = d - c
        let denominator = first.cross(second)
        guard abs(denominator) > 1e-12 else { return nil }
        let offset = c - a
        let travel = offset.cross(second) / denominator
        let other = offset.cross(first) / denominator
        let epsilon = 1e-12
        guard travel > epsilon, travel < 1 - epsilon,
              other > epsilon, other < 1 - epsilon
        else { return nil }
        return a + first * travel
    }
}
