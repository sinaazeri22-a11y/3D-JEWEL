import Foundation

/// Which end of a curve a cleanup acts on. `removing` and `at` name the end a
/// trim cuts away; `extend` names the end that grows.
enum FFCurveEnd: String, CaseIterable, Equatable, Sendable {
    case start
    case end

    var label: String {
        switch self {
        case .start: "start"
        case .end: "end"
        }
    }

    /// The local parameter of this end inside one span.
    var parameter: Double {
        switch self {
        case .start: 0
        case .end: 1
        }
    }
}

/// How smoothly two spans meet at a seam. `g2` implies `g1`, which implies
/// `g0`; the value is ordered so a caller can ask for "at least G1".
enum FFCurveContinuity: Int, Comparable, Equatable, Sendable {
    case g0 = 0
    case g1 = 1
    case g2 = 2

    static func < (lhs: FFCurveContinuity, rhs: FFCurveContinuity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .g0: "G0"
        case .g1: "G1"
        case .g2: "G2"
        }
    }
}

/// Why a cleanup operation was refused. Every case carries a sentence because
/// the only feedback a pencil gets is what the editor says.
enum FFCurveCleanupError: Error, Equatable, LocalizedError, Sendable {
    case noSegment(Int)
    case emptyCurve
    case invalidCurve(segment: Int)
    case closedCurve
    case alreadyClosed
    case trimPointOffCurve(distance: Double)
    case trimAtEndpoint
    case cannotTrim(segment: Int)
    case extensionDistance
    case noEndTangent(segment: Int)
    case splitPointOffCurve(distance: Double)
    case splitAtEndpoint
    case cannotSplit(segment: Int)
    case joinGap(Double)

    var errorDescription: String? {
        switch self {
        case .noSegment(let segment):
            return "The curve has no segment \(segment + 1)"
        case .emptyCurve:
            return "The curve has no spans to clean up"
        case .invalidCurve(let segment):
            return "Segment \(segment + 1) cannot be rebuilt as a curve"
        case .closedCurve:
            return "That curve is closed; open it before trimming, extending or splitting"
        case .alreadyClosed:
            return "That curve is already closed"
        case .trimPointOffCurve(let distance):
            return "The trim point is \(FFPrecision.fixed(distance, decimals: 4)) mm off the curve"
        case .trimAtEndpoint:
            return "A trim point cannot be the curve's own end"
        case .cannotTrim(let segment):
            return "Segment \(segment + 1) cannot be split at that trim point"
        case .extensionDistance:
            return "An extension needs a finite distance greater than zero"
        case .noEndTangent(let segment):
            return "Segment \(segment + 1) has no tangent at that end to extend along"
        case .splitPointOffCurve(let distance):
            return "The split point is \(FFPrecision.fixed(distance, decimals: 4)) mm off the curve"
        case .splitAtEndpoint:
            return "A split point cannot be the curve's own end"
        case .cannotSplit(let segment):
            return "Segment \(segment + 1) cannot be split at that point"
        case .joinGap(let gap):
            return "The curves end \(FFPrecision.fixed(gap, decimals: 4)) mm apart and cannot be joined"
        }
    }
}

/// The measurement behind a join. `tangentAngle` is the unsigned angle between
/// the arriving and departing unit tangents in radians, and
/// `curvatureDifference` is the absolute difference of the signed curvatures.
struct FFCurveJoinReport: Equatable, Sendable {
    var continuity: FFCurveContinuity
    var gap: Double
    var tangentAngle: Double
    var curvatureDifference: Double

    /// The sentence an editor shows after a join. It names the continuity the
    /// measurement actually supports, not the continuity the operation hoped
    /// for.
    var summary: String {
        let bend = FFPrecision.fixed(FFMath.degrees(tangentAngle), decimals: 3)
        let separation = FFPrecision.fixed(gap, decimals: 6)
        return "\(continuity.label) · gap \(separation) mm · bend \(bend)°"
    }
}

/// A join's result plus the two orientation decisions it made. A caller that
/// wants one curve reads `payload`; a caller that wants to explain the seam
/// reads `report`.
struct FFCurveJoinOutcome: Equatable, Sendable {
    var payload: FFCurvePayload
    var report: FFCurveJoinReport
    var reversedFirst: Bool
    var reversedSecond: Bool
}

/// What one duplicate-removal pass changed. Counts are the operations the pass
/// actually performed, so a caller can tell "nothing to remove" from "removed
/// six points".
struct FFCurveDuplicateReport: Equatable, Sendable {
    var payload: FFCurvePayload
    var removedPoints: Int
    var removedSpans: Int

    var hasChanges: Bool { removedPoints > 0 || removedSpans > 0 }

    var summary: String {
        let points = removedPoints == 1 ? "1 duplicate point" : "\(removedPoints) duplicate points"
        let spans = removedSpans == 1 ? "1 empty span" : "\(removedSpans) empty spans"
        return "Removed \(points) · \(spans)"
    }
}

enum FFCurveCleanup {
    /// Measures the seam between two spans. The join tolerance decides whether
    /// the ends are coincident; the tangent and curvature tolerances decide
    /// which continuity label the seam earns. A zero-length tangent can never
    /// earn more than G0, because a direction does not exist to compare.
    static func continuity(
        atEndOf first: FFCurveSegment,
        andStartOf second: FFCurveSegment,
        gap: Double,
        tangentTolerance: Double = 1e-6,
        curvatureTolerance: Double = 1e-6
    ) throws -> FFCurveJoinReport {
        guard let arriving = first.curve else { throw FFCurveCleanupError.invalidCurve(segment: 0) }
        guard let departing = second.curve else { throw FFCurveCleanupError.invalidCurve(segment: 1) }

        let arrivingTangent = arriving.derivative(at: 1)
        let departingTangent = departing.derivative(at: 0)
        var bend = Double.pi
        var continuity = FFCurveContinuity.g0
        var curvatureDifference = 0.0

        if arrivingTangent.length > FFMath.eps, departingTangent.length > FFMath.eps {
            let arrivingUnit = arrivingTangent / arrivingTangent.length
            let departingUnit = departingTangent / departingTangent.length
            let cosine = FFMath.clamp(
                arrivingUnit.x * departingUnit.x + arrivingUnit.y * departingUnit.y,
                to: -1...1
            )
            bend = acos(cosine)
            if bend <= tangentTolerance {
                let arrivingCurvature = signedCurvature(
                    arriving,
                    at: 1,
                    derivative: arrivingTangent
                )
                let departingCurvature = signedCurvature(
                    departing,
                    at: 0,
                    derivative: departingTangent
                )
                curvatureDifference = abs(arrivingCurvature - departingCurvature)
                continuity = curvatureDifference <= curvatureTolerance ? .g2 : .g1
            }
        }

        return FFCurveJoinReport(
            continuity: continuity,
            gap: gap,
            tangentAngle: bend,
            curvatureDifference: curvatureDifference
        )
    }

    /// The 2-D similarity that maps `source`'s local plane into `destination`'s
    /// local plane, or nil when the two planes are not the same plane at the
    /// same scale. A uniform scale, a rotation and a translation all map a
    /// Bézier or NURBS curve's control points exactly, which is what lets a
    /// join move one payload into the other's space without re-fitting it. An
    /// out-of-plane tilt, a non-uniform scale or a shear has no such map.
    static func planarTransform(from source: Mat4, to destination: Mat4) -> Mat3? {
        guard let inverse = destination.inverse() else { return nil }
        let relative = inverse * source

        let origin = relative.transformedPoint(Vec3(x: 0, y: 0, z: 0))
        let xAxis = relative.transformedVector(Vec3(x: 1, y: 0, z: 0))
        let yAxis = relative.transformedVector(Vec3(x: 0, y: 1, z: 0))
        let magnitude = max(max(xAxis.length, yAxis.length), 1)
        let tolerance = 1e-9 * magnitude

        guard abs(origin.z) <= tolerance,
              abs(xAxis.z) <= tolerance,
              abs(yAxis.z) <= tolerance,
              abs(xAxis.length - yAxis.length) <= tolerance,
              abs(xAxis.x * yAxis.x + xAxis.y * yAxis.y) <= tolerance * magnitude,
              xAxis.length > FFMath.eps
        else { return nil }

        return Mat3(
            m00: xAxis.x, m01: yAxis.x, m02: origin.x,
            m10: xAxis.y, m11: yAxis.y, m12: origin.y,
            m20: 0, m21: 0, m22: 1
        )
    }

    private static func signedCurvature(
        _ curve: Curve2D,
        at parameter: Double,
        derivative: Vec2
    ) -> Double {
        let speed = derivative.length
        guard speed > FFMath.eps else { return 0 }
        let second = curve.secondDerivative(at: parameter)
        return derivative.cross(second) / (speed * speed * speed)
    }
}

extension FFCurvePayload {
    // MARK: - Reverse

    /// Reverses every span and their order, so the path is traversed the other
    /// way. Bézier control points reverse exactly and a NURBS span reverses its
    /// knots about one, so this is a re-parameterisation, not an approximation.
    func reversed() -> FFCurvePayload? {
        var result: [FFCurveSegment] = []
        result.reserveCapacity(segments.count)
        for segment in segments.reversed() {
            guard let curve = segment.curve?.reversed() else { return nil }
            result.append(FFCurveSegment(curve))
        }
        return FFCurvePayload(segments: result, isClosed: isClosed)
    }

    // MARK: - Trim

    /// Shortens an open path to `point` by cutting one end away. `point` is a
    /// cutter: it must lie on the end span, and the surviving endpoint is the
    /// curve's own point at the resolved parameter so the trimmed curve stays
    /// exactly on the original geometry. Trimming the middle of a span is a
    /// split, not a trim, and is refused by construction.
    @discardableResult
    mutating func trim(
        at point: Vec2,
        removing side: FFCurveEnd,
        tolerance: Double = 1e-4
    ) throws -> Vec2 {
        guard !segments.isEmpty else { throw FFCurveCleanupError.emptyCurve }
        guard !isClosed else { throw FFCurveCleanupError.closedCurve }

        let index = side == .start ? 0 : segments.count - 1
        guard let curve = segments[index].curve else {
            throw FFCurveCleanupError.invalidCurve(segment: index)
        }
        let closest = curve.closestPoint(to: point)
        guard closest.distance <= tolerance else {
            throw FFCurveCleanupError.trimPointOffCurve(distance: closest.distance)
        }
        guard closest.parameter > 1e-9, closest.parameter < 1 - 1e-9 else {
            throw FFCurveCleanupError.trimAtEndpoint
        }
        guard let pieces = curve.split(at: closest.parameter) else {
            throw FFCurveCleanupError.cannotTrim(segment: index)
        }

        switch side {
        case .start:
            segments[0] = FFCurveSegment(pieces.1)
            return pieces.1.start
        case .end:
            segments[index] = FFCurveSegment(pieces.0)
            return pieces.0.end
        }
    }

    // MARK: - Extend

    /// Grows one end by `distance` millimetres along the tangent it leaves
    /// with. The extension is a straight span, which is exact for a curve whose
    /// shape is not being continued analytically; a zero tangent has no
    /// direction and is refused instead of inventing one.
    @discardableResult
    mutating func extend(at end: FFCurveEnd, by distance: Double) throws -> Vec2 {
        guard !segments.isEmpty else { throw FFCurveCleanupError.emptyCurve }
        guard !isClosed else { throw FFCurveCleanupError.closedCurve }
        guard distance.isFinite, distance > 0 else {
            throw FFCurveCleanupError.extensionDistance
        }

        let index = end == .start ? 0 : segments.count - 1
        guard let curve = segments[index].curve else {
            throw FFCurveCleanupError.invalidCurve(segment: index)
        }
        let tangent = curve.derivative(at: end.parameter)
        guard tangent.length > FFMath.eps, let direction = tangent.normalized() else {
            throw FFCurveCleanupError.noEndTangent(segment: index)
        }

        switch end {
        case .end:
            let tip = curve.end + direction * distance
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(curve.end), FFPoint2(tip)]
            ))
            return tip
        case .start:
            let tip = curve.start - direction * distance
            segments.insert(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(tip), FFPoint2(curve.start)]
            ), at: 0)
            return tip
        }
    }

    // MARK: - Split

    /// Splits an open path into two open paths at one span's parameter. The
    /// span is split exactly (De Casteljau for a Bézier, knot insertion for a
    /// NURBS span), so the two new endpoints are the same curve point and the
    /// halves still lie on the original.
    func split(
        segment index: Int,
        at parameter: Double
    ) throws -> (left: FFCurvePayload, right: FFCurvePayload) {
        guard segments.indices.contains(index) else {
            throw FFCurveCleanupError.noSegment(index)
        }
        guard !isClosed else { throw FFCurveCleanupError.closedCurve }
        guard parameter > 1e-9, parameter < 1 - 1e-9 else {
            throw FFCurveCleanupError.splitAtEndpoint
        }
        guard let curve = segments[index].curve, let pieces = curve.split(at: parameter) else {
            throw FFCurveCleanupError.cannotSplit(segment: index)
        }

        let left = FFCurvePayload(
            segments: Array(segments[0..<index]) + [FFCurveSegment(pieces.0)]
        )
        let right = FFCurvePayload(
            segments: [FFCurveSegment(pieces.1)] + Array(segments[(index + 1)...])
        )
        return (left, right)
    }

    /// Splits at a point that lies on the curve, reporting the parameter the
    /// point resolved to. A point off the curve is refused with its distance.
    func split(
        segment index: Int,
        at point: Vec2,
        tolerance: Double = 1e-4
    ) throws -> (left: FFCurvePayload, right: FFCurvePayload, parameter: Double) {
        guard segments.indices.contains(index) else {
            throw FFCurveCleanupError.noSegment(index)
        }
        guard let curve = segments[index].curve else {
            throw FFCurveCleanupError.invalidCurve(segment: index)
        }
        let closest = curve.closestPoint(to: point)
        guard closest.distance <= tolerance else {
            throw FFCurveCleanupError.splitPointOffCurve(distance: closest.distance)
        }
        let pieces = try split(segment: index, at: closest.parameter)
        return (pieces.left, pieces.right, closest.parameter)
    }

    // MARK: - Join

    /// Joins two open paths into one, reversing either path when that is what
    /// brings the ends together. The chosen orientation is the one with the
    /// smallest gap; a gap beyond `tolerance` refuses the join instead of
    /// pulling the curves toward each other. The report names the continuity
    /// the seam actually has.
    func joined(
        with other: FFCurvePayload,
        tolerance: Double = FFTolerance.curveJoin
    ) throws -> FFCurveJoinOutcome {
        guard !segments.isEmpty, !other.segments.isEmpty else {
            throw FFCurveCleanupError.emptyCurve
        }
        guard !isClosed, !other.isClosed else {
            throw FFCurveCleanupError.closedCurve
        }
        guard let reversedSelf = reversed(), let reversedOther = other.reversed() else {
            throw FFCurveCleanupError.invalidCurve(segment: 0)
        }

        let candidates: [(FFCurvePayload, FFCurvePayload, Bool, Bool)] = [
            (self, other, false, false),
            (self, reversedOther, false, true),
            (reversedSelf, other, true, false),
            (reversedSelf, reversedOther, true, true),
        ]

        var bestGap = Double.infinity
        var bestIndex = 0
        for (index, candidate) in candidates.enumerated() {
            guard let arriving = candidate.0.segments.last?.curve,
                  let departing = candidate.1.segments.first?.curve
            else { throw FFCurveCleanupError.invalidCurve(segment: 0) }
            let gap = arriving.end.distance(to: departing.start)
            if gap < bestGap {
                bestGap = gap
                bestIndex = index
            }
        }
        guard bestGap <= tolerance else {
            throw FFCurveCleanupError.joinGap(bestGap)
        }

        let chosen = candidates[bestIndex]
        guard let arriving = chosen.0.segments.last,
              let departing = chosen.1.segments.first
        else { throw FFCurveCleanupError.invalidCurve(segment: 0) }

        let report = try FFCurveCleanup.continuity(
            atEndOf: arriving,
            andStartOf: departing,
            gap: bestGap
        )
        let payload = FFCurvePayload(segments: chosen.0.segments + chosen.1.segments)
        guard payload.path(tolerance: tolerance) != nil else {
            throw FFCurveCleanupError.joinGap(bestGap)
        }
        return FFCurveJoinOutcome(
            payload: payload,
            report: report,
            reversedFirst: chosen.2,
            reversedSecond: chosen.3
        )
    }

    // MARK: - Close

    /// Closes an open path. When the ends already meet within `tolerance` the
    /// intent flag is the only change; otherwise one straight span from the end
    /// to the start is appended. Returns whether geometry was added.
    @discardableResult
    mutating func close(tolerance: Double = FFTolerance.curveJoin) throws -> Bool {
        guard !segments.isEmpty else { throw FFCurveCleanupError.emptyCurve }
        guard !isClosed else { throw FFCurveCleanupError.alreadyClosed }
        guard let start = segments.first?.curve?.start, let end = segments.last?.curve?.end else {
            throw FFCurveCleanupError.invalidCurve(segment: segments.count - 1)
        }

        isClosed = true
        guard end.distance(to: start) > tolerance else { return false }
        segments.append(FFCurveSegment(
            kind: .bezier,
            controlPoints: [FFPoint2(end), FFPoint2(start)]
        ))
        return true
    }

    // MARK: - Remove duplicates

    /// Removes data that carries no geometry: a span whose control points are
    /// all the same point, a span that repeats its predecessor exactly, and a
    /// repeated vertex inside a polyline span. Those three are exact — the
    /// drawn point set does not change — so the result is a cleanup rather than
    /// a silent reshape. A repeated control point inside a higher-degree span
    /// is deliberately left alone: removing it would change the curve, and this
    /// operation does not approximate.
    func removingDuplicates(
        tolerance: Double = FFTolerance.curveJoin
    ) -> FFCurveDuplicateReport {
        var kept: [FFCurveSegment] = []
        var removedPoints = 0
        var removedSpans = 0

        for segment in segments {
            guard let firstPoint = segment.controlPoints.first?.vector else {
                removedSpans += 1
                continue
            }
            let isDegenerate = segment.controlPoints.allSatisfy {
                $0.vector.distance(to: firstPoint) <= tolerance
            }
            if isDegenerate {
                removedSpans += 1
                continue
            }
            if let previous = kept.last, segment.matchesGeometry(of: previous, tolerance: tolerance) {
                removedSpans += 1
                continue
            }
            guard segment.isPolyline else {
                kept.append(segment)
                continue
            }

            var points: [FFPoint2] = []
            var weights: [Double] = []
            for (index, point) in segment.controlPoints.enumerated() {
                if let last = points.last, last.vector.distance(to: point.vector) <= tolerance {
                    removedPoints += 1
                    continue
                }
                points.append(point)
                if segment.weights.indices.contains(index) {
                    weights.append(segment.weights[index])
                }
            }

            var reduced = segment
            reduced.controlPoints = points
            if segment.kind == .nurbs {
                reduced.weights = weights
                reduced.knots = FFCurvePayload.clampedKnots(
                    degree: segment.degree,
                    pointCount: points.count
                )
            }
            kept.append(reduced)
        }

        guard !kept.isEmpty else {
            return FFCurveDuplicateReport(payload: self, removedPoints: 0, removedSpans: 0)
        }
        return FFCurveDuplicateReport(
            payload: FFCurvePayload(segments: kept, isClosed: isClosed),
            removedPoints: removedPoints,
            removedSpans: removedSpans
        )
    }

    // MARK: - Placement

    /// Maps every control point through a planar affine transform. A uniform
    /// scale, a rotation and a translation commute with the rational basis
    /// functions, so weights and knots stay exactly as they were.
    func transformed(by matrix: Mat3) -> FFCurvePayload? {
        var result = self
        for index in result.segments.indices {
            result.segments[index].controlPoints = result.segments[index].controlPoints.map {
                let mapped = $0.vector.transformed(by: matrix)
                return FFPoint2(mapped)
            }
            guard result.segments[index].controlPoints.allSatisfy({
                $0.x.isFinite && $0.y.isFinite
            }) else { return nil }
        }
        return result
    }
}

private extension FFCurveSegment {
    /// A degree-one span is a polyline: a repeated vertex adds no geometry, so
    /// dropping it is exact.
    var isPolyline: Bool {
        switch kind {
        case .bezier:
            return controlPoints.count == 2
        case .nurbs:
            return degree == 1 && controlPoints.count >= 2
        }
    }

    /// Structural equality of the stored geometry, used to recognise a span
    /// that repeats its predecessor. Knots are compared with a fixed epsilon
    /// because two identical spans may have been retimed by a split.
    func matchesGeometry(of other: FFCurveSegment, tolerance: Double) -> Bool {
        guard controlPoints.count == other.controlPoints.count,
              weights.count == other.weights.count,
              zip(weights, other.weights).allSatisfy({ abs($0 - $1) <= tolerance })
        else { return false }
        guard zip(controlPoints, other.controlPoints).allSatisfy({
            $0.vector.distance(to: $1.vector) <= tolerance
        }) else { return false }
        if kind == .nurbs || other.kind == .nurbs {
            guard kind == other.kind,
                  degree == other.degree,
                  knots.count == other.knots.count,
                  zip(knots, other.knots).allSatisfy({ abs($0 - $1) <= 1e-9 })
            else { return false }
        }
        return true
    }
}
