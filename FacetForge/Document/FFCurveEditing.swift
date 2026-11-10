import CryptoKit
import Foundation

/// One editable control point inside a curve payload. A segment is an index
/// into `FFCurvePayload.segments`; a point is an index into that segment's
/// control polygon. The reference is plain data so a view can keep a selected
/// handle without owning the curve.
struct FFCurvePointRef: Equatable, Hashable, Sendable {
    var segment: Int
    var point: Int

    init(segment: Int, point: Int) {
        self.segment = segment
        self.point = point
    }
}

/// Why a control-point edit was refused. Every case carries a sentence because
/// the only feedback a pencil gets is what the editor says.
enum FFCurveEditError: Error, Equatable, LocalizedError {
    case noSegment(Int)
    case noPoint(segment: Int, point: Int)
    case endpoint(segment: Int, point: Int)
    case tooFewPoints(segment: Int)
    case invalidWeight
    case invalidPoint
    case notSingleSpan(segment: Int)
    case invalidParameter
    case cannotInsert(segment: Int)
    case invalidCurve(segment: Int)

    var errorDescription: String? {
        switch self {
        case .noSegment(let segment):
            return "The curve has no segment \(segment + 1)"
        case .noPoint(let segment, let point):
            return "Segment \(segment + 1) has no control point \(point + 1)"
        case .endpoint(let segment, let point):
            return "Point \(point + 1) in segment \(segment + 1) is an endpoint and cannot be deleted"
        case .tooFewPoints(let segment):
            return "Segment \(segment + 1) would have too few control points for its degree"
        case .invalidWeight:
            return "A control-point weight must be a finite number greater than zero"
        case .invalidPoint:
            return "That control point has a non-finite coordinate"
        case .notSingleSpan(let segment):
            return "Degree elevation needs one span; segment \(segment + 1) is multi-span"
        case .invalidParameter:
            return "Insertion needs a parameter strictly inside the curve"
        case .cannotInsert(let segment):
            return "A control point cannot be inserted into segment \(segment + 1) at that parameter"
        case .invalidCurve(let segment):
            return "Segment \(segment + 1) cannot be rebuilt as a curve"
        }
    }
}

/// The knot vector as the editor shows it: the normalised clamped values plus
/// their multiplicities. A Bézier segment has no stored knots, so its clamped
/// equivalent is reported instead of an empty vector.
struct FFKnotMultiplicity: Equatable, Sendable {
    var value: Double
    var count: Int
}

struct FFKnotDisplay: Equatable, Sendable {
    var segment: Int
    var degree: Int
    var controlPointCount: Int
    var isRational: Bool
    var knots: [Double]
    var multiplicities: [FFKnotMultiplicity]
}

/// A tangent handle at one end of a span. For a clamped curve the first or last
/// control-polygon leg is the tangent, so the handle tip is the adjacent
/// control point and dragging the tip moves that point. The endpoint itself is
/// not moved by a tangent edit.
struct FFTangentHandle: Equatable, Sendable {
    enum End: String, Equatable, Sendable {
        case start
        case end
    }

    var segment: Int
    var end: End
    var origin: Vec2
    var tip: Vec2
    var controlPoint: FFCurvePointRef

    var direction: Vec2 { tip - origin }
}

/// One sample of a curvature comb. `curvature` is the unsigned analytic
/// curvature `|x'y'' − y'x''| / |x'|³`; `combTip` offsets the curve along its
/// left normal by `curvature × scale` in sketch-plane millimetres. Phase 47
/// owns the full diagnostics surface; this is the measurement Phase 43 needs
/// to prove that a weight edit changes the geometry it claims to change.
struct FFCurvatureSample: Equatable, Sendable {
    var segment: Int
    var parameter: Double
    var point: Vec2
    var normal: Vec2
    var curvature: Double
    var combTip: Vec2
}

enum FFCurveDiagnostics {
    /// Samples every span at the same local parameters. Returns nil when a
    /// segment cannot be rebuilt, so a damaged payload never produces a
    /// plausible-looking comb.
    static func curvatureComb(
        of payload: FFCurvePayload,
        samplesPerSegment: Int = 16,
        scale: Double = 1
    ) -> [FFCurvatureSample]? {
        let samples = max(2, samplesPerSegment)
        let resolvedScale = scale.isFinite ? max(0, scale) : 0
        var result: [FFCurvatureSample] = []

        for (segmentIndex, segment) in payload.segments.enumerated() {
            guard let curve = segment.curve else { return nil }
            for step in 0...samples {
                let t = Double(step) / Double(samples)
                let point = curve.point(at: t)
                let first = curve.derivative(at: t)
                let second = curve.secondDerivative(at: t)
                let speed = first.length
                let curvature = speed > FFMath.eps
                    ? abs(first.cross(second)) / (speed * speed * speed)
                    : 0
                let normal = speed > FFMath.eps
                    ? Vec2(x: -first.y / speed, y: first.x / speed)
                    : .zero
                result.append(FFCurvatureSample(
                    segment: segmentIndex,
                    parameter: t,
                    point: point,
                    normal: normal,
                    curvature: curvature,
                    combTip: point + normal * (curvature * resolvedScale)
                ))
            }
        }
        return result
    }
}

extension FFCurvePayload {
    /// A stable, cross-platform fingerprint of the curve's stored geometry.
    ///
    /// The canonical string quantises lengths to one nanometre before hashing,
    /// so the fingerprint is not sensitive to the last bits of a double and can
    /// be compared across a save, a reload and a re-graded fit. It is a
    /// regression and test seam, not a file checksum.
    var fingerprint: String {
        var parts: [String] = []
        for (index, segment) in segments.enumerated() {
            let points = segment.controlPoints
                .map { "\(Self.quantised($0.vector.x)),\(Self.quantised($0.vector.y))" }
                .joined(separator: ";")
            let weights = segment.weights.map { Self.quantised($0) }.joined(separator: ";")
            let knots = segment.knots.map { Self.quantised($0) }.joined(separator: ";")
            parts.append(
                "\(index):\(segment.kind.rawValue):\(segment.degree):\(points):\(weights):\(knots)"
            )
        }
        let text = parts.joined(separator: "|") + "|closed:\(isClosed)"
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    /// The normalised clamped knot vector for a polynomial curve of this
    /// degree and control-point count.
    static func clampedKnots(degree: Int, pointCount: Int) -> [Double] {
        guard degree >= 1, pointCount >= degree + 1 else { return [] }
        var knots = [Double](repeating: 0, count: degree + 1)
        let interior = pointCount - degree - 1
        if interior > 0 {
            for index in 1...interior {
                knots.append(Double(index) / Double(interior + 1))
            }
        }
        knots.append(contentsOf: [Double](repeating: 1, count: degree + 1))
        return knots
    }

    /// Moves one control point. When the moved point is a segment endpoint that
    /// currently meets its neighbour, the neighbour's matching endpoint follows
    /// it, so a path cannot silently split into two curves.
    mutating func moveControlPoint(_ ref: FFCurvePointRef, to location: Vec2) throws {
        try validate(ref)
        guard location.x.isFinite, location.y.isFinite else { throw FFCurveEditError.invalidPoint }

        let segment = segments[ref.segment]
        let old = segment.controlPoints[ref.point].vector
        segments[ref.segment].controlPoints[ref.point] = FFPoint2(location)

        if ref.point == 0, ref.segment > 0 {
            let previous = ref.segment - 1
            let previousCount = segments[previous].controlPoints.count
            if let last = segments[previous].controlPoints.last,
               last.vector.distance(to: old) <= FFTolerance.curveJoin {
                segments[previous].controlPoints[previousCount - 1] = FFPoint2(location)
            }
        }
        if ref.point == segment.controlPoints.count - 1, ref.segment + 1 < segments.count {
            let next = ref.segment + 1
            if let first = segments[next].controlPoints.first,
               first.vector.distance(to: old) <= FFTolerance.curveJoin {
                segments[next].controlPoints[0] = FFPoint2(location)
            }
        }
    }

    /// Inserts one control point at a parameter without changing the curve.
    /// A Bézier span is first written as its equivalent rational NURBS span,
    /// because a polynomial Bézier cannot carry a knot without a degree change.
    /// The returned reference is the inserted knot's control point.
    @discardableResult
    mutating func insertControlPoint(segment index: Int, at parameter: Double) throws -> FFCurvePointRef {
        guard segments.indices.contains(index) else { throw FFCurveEditError.noSegment(index) }
        guard parameter.isFinite, parameter > 1e-9, parameter < 1 - 1e-9 else {
            throw FFCurveEditError.invalidParameter
        }

        let converted = segments[index].asNURBS()
        guard let curve = converted.nurbsCurve,
              let inserted = curve.insertingKnot(at: parameter)
        else {
            throw FFCurveEditError.cannotInsert(segment: index)
        }
        segments[index] = FFCurveSegment(.nurbs(inserted.curve))
        return FFCurvePointRef(segment: index, point: inserted.index)
    }

    /// Deletes an interior control point. Endpoints are refused because moving
    /// them would break the join to the next span; a span with only its minimum
    /// control points is refused rather than silently lowering its degree.
    mutating func deleteControlPoint(_ ref: FFCurvePointRef) throws {
        try validate(ref)
        let segment = segments[ref.segment]
        let count = segment.controlPoints.count
        guard ref.point > 0, ref.point < count - 1 else {
            throw FFCurveEditError.endpoint(segment: ref.segment, point: ref.point)
        }

        if segment.kind == .nurbs {
            guard count - 1 >= segment.degree + 1 else {
                throw FFCurveEditError.tooFewPoints(segment: ref.segment)
            }
            segments[ref.segment].controlPoints.remove(at: ref.point)
            if segments[ref.segment].weights.count == count {
                segments[ref.segment].weights.remove(at: ref.point)
            }
            segments[ref.segment].knots = Self.clampedKnots(
                degree: segment.degree,
                pointCount: count - 1
            )
        } else {
            guard count - 1 >= 2 else {
                throw FFCurveEditError.tooFewPoints(segment: ref.segment)
            }
            segments[ref.segment].controlPoints.remove(at: ref.point)
        }
    }

    /// Sets one control-point weight. A polynomial Bézier span becomes its
    /// exact rational equivalent first; from then on the payload is NURBS.
    mutating func setWeight(_ ref: FFCurvePointRef, to weight: Double) throws {
        try validate(ref)
        guard weight.isFinite, weight > 0 else { throw FFCurveEditError.invalidWeight }

        if segments[ref.segment].kind == .bezier {
            segments[ref.segment] = segments[ref.segment].asNURBS()
        }
        guard segments[ref.segment].weights.count == segments[ref.segment].controlPoints.count else {
            throw FFCurveEditError.invalidCurve(segment: ref.segment)
        }
        segments[ref.segment].weights[ref.point] = weight
    }

    /// Raises one span's degree by one without changing its shape. A polynomial
    /// Bézier uses the closed-form elevation. A rational NURBS span is elevated
    /// in homogeneous coordinates, which is exact because a single-span clamped
    /// NURBS curve is a rational Bézier curve. Multi-span curves are refused:
    /// their knot vector has to be split and rejoined first, which is Phase 44's
    /// cleanup territory, not a silent approximation here.
    mutating func elevateDegree(segment index: Int) throws {
        guard segments.indices.contains(index) else { throw FFCurveEditError.noSegment(index) }
        let segment = segments[index]

        switch segment.kind {
        case .bezier:
            let points = segment.controlPoints.map(\.vector)
            let elevated = Self.elevate(points)
            segments[index] = FFCurveSegment(
                kind: .bezier,
                controlPoints: elevated.map { FFPoint2($0) }
            )
        case .nurbs:
            guard Self.isSingleSpan(segment) else {
                throw FFCurveEditError.notSingleSpan(segment: index)
            }
            guard segment.weights.count == segment.controlPoints.count,
                  segment.knots.count == segment.controlPoints.count + segment.degree + 1
            else {
                throw FFCurveEditError.invalidCurve(segment: index)
            }
            let homogeneous = zip(segment.controlPoints, segment.weights).map { pair in
                Vec3(x: pair.0.x * pair.1, y: pair.0.y * pair.1, z: pair.1)
            }
            let elevated = Self.elevate(homogeneous)
            guard elevated.allSatisfy({ $0.z.isFinite && $0.z > 0 }) else {
                throw FFCurveEditError.invalidCurve(segment: index)
            }
            let points = elevated.map { Vec2(x: $0.x / $0.z, y: $0.y / $0.z) }
            let weights = elevated.map(\.z)
            let degree = segment.degree + 1
            segments[index] = FFCurveSegment(
                kind: .nurbs,
                controlPoints: points.map { FFPoint2($0) },
                weights: weights,
                degree: degree,
                knots: Self.clampedKnots(degree: degree, pointCount: points.count)
            )
        }
    }

    func knotDisplay(in index: Int) throws -> FFKnotDisplay {
        guard segments.indices.contains(index) else { throw FFCurveEditError.noSegment(index) }
        let segment = segments[index]
        let count = segment.controlPoints.count
        let degree = segment.kind == .bezier ? count - 1 : segment.degree
        guard degree >= 1, count >= degree + 1 else {
            throw FFCurveEditError.invalidCurve(segment: index)
        }

        let knots: [Double]
        let isRational: Bool
        switch segment.kind {
        case .bezier:
            knots = Self.clampedKnots(degree: degree, pointCount: count)
            isRational = false
        case .nurbs:
            guard segment.knots.count == count + degree + 1 else {
                throw FFCurveEditError.invalidCurve(segment: index)
            }
            knots = segment.knots
            isRational = segment.weights.contains { abs($0 - 1) > 1e-12 }
        }

        var multiplicities: [FFKnotMultiplicity] = []
        for knot in knots {
            if let last = multiplicities.last, abs(last.value - knot) <= 1e-12 {
                multiplicities[multiplicities.count - 1].count += 1
            } else {
                multiplicities.append(FFKnotMultiplicity(value: knot, count: 1))
            }
        }

        return FFKnotDisplay(
            segment: index,
            degree: degree,
            controlPointCount: count,
            isRational: isRational,
            knots: knots,
            multiplicities: multiplicities
        )
    }

    func tangentHandles(in index: Int) throws -> [FFTangentHandle] {
        guard segments.indices.contains(index) else { throw FFCurveEditError.noSegment(index) }
        let segment = segments[index]
        let count = segment.controlPoints.count
        guard count >= 3 else { return [] }

        return [
            FFTangentHandle(
                segment: index,
                end: .start,
                origin: segment.controlPoints[0].vector,
                tip: segment.controlPoints[1].vector,
                controlPoint: FFCurvePointRef(segment: index, point: 1)
            ),
            FFTangentHandle(
                segment: index,
                end: .end,
                origin: segment.controlPoints[count - 1].vector,
                tip: segment.controlPoints[count - 2].vector,
                controlPoint: FFCurvePointRef(segment: index, point: count - 2)
            ),
        ]
    }

    func curvatureComb(
        samplesPerSegment: Int = 16,
        scale: Double = 1
    ) -> [FFCurvatureSample]? {
        FFCurveDiagnostics.curvatureComb(
            of: self,
            samplesPerSegment: samplesPerSegment,
            scale: scale
        )
    }

    private func validate(_ ref: FFCurvePointRef) throws {
        guard segments.indices.contains(ref.segment) else {
            throw FFCurveEditError.noSegment(ref.segment)
        }
        guard segments[ref.segment].controlPoints.indices.contains(ref.point) else {
            throw FFCurveEditError.noPoint(segment: ref.segment, point: ref.point)
        }
    }

    private static func isSingleSpan(_ segment: FFCurveSegment) -> Bool {
        let count = segment.controlPoints.count
        let degree = segment.degree
        guard degree >= 1, count >= degree + 1 else { return false }
        guard segment.knots.count == count + degree + 1 else { return false }
        if count == degree + 1 { return true }
        for index in (degree + 1)..<count {
            let knot = segment.knots[index]
            if knot > 1e-12, knot < 1 - 1e-12 { return false }
        }
        return true
    }

    private static func elevate(_ points: [Vec2]) -> [Vec2] {
        guard points.count >= 2 else { return points }
        let lastIndex = points.count - 1
        let denominator = Double(lastIndex + 1)
        var elevated: [Vec2] = [points[0]]
        elevated.reserveCapacity(points.count + 1)
        for index in 1...lastIndex {
            let alpha = Double(index) / denominator
            elevated.append(points[index - 1] * alpha + points[index] * (1 - alpha))
        }
        elevated.append(points[lastIndex])
        return elevated
    }

    private static func elevate(_ points: [Vec3]) -> [Vec3] {
        guard points.count >= 2 else { return points }
        let lastIndex = points.count - 1
        let denominator = Double(lastIndex + 1)
        var elevated: [Vec3] = [points[0]]
        elevated.reserveCapacity(points.count + 1)
        for index in 1...lastIndex {
            let alpha = Double(index) / denominator
            elevated.append(points[index - 1] * alpha + points[index] * (1 - alpha))
        }
        elevated.append(points[lastIndex])
        return elevated
    }

    private static func quantised(_ value: Double) -> String {
        guard value.isFinite else { return value.sign == .minus ? "-inf" : "inf" }
        let scaled = (value * 1_000_000_000).rounded()
        if scaled == 0 { return "0" }
        guard scaled < 9.22e18, scaled > -9.22e18 else { return String(scaled) }
        return String(Int64(scaled))
    }
}

extension FFCurveSegment {
    /// The exact rational NURBS form of a polynomial span: every weight is one
    /// and the knot vector is the clamped default.
    func asNURBS() -> FFCurveSegment {
        guard kind == .bezier else { return self }
        let degree = controlPoints.count - 1
        return FFCurveSegment(
            kind: .nurbs,
            controlPoints: controlPoints,
            weights: [Double](repeating: 1, count: controlPoints.count),
            degree: degree,
            knots: FFCurvePayload.clampedKnots(
                degree: degree,
                pointCount: controlPoints.count
            )
        )
    }

    var nurbsCurve: NURBSCurve2D? {
        guard case .nurbs(let curve)? = curve else { return nil }
        return curve
    }
}

extension FFDocument {
    func curvePayload(forNodeID target: UUID) -> FFCurvePayload? {
        node(withID: target)?.geometry?.curve
    }

    /// Runs one pure payload edit against a curve node. The document is the
    /// only owner of the stored payload; the caller's closure can only reach it
    /// through this method.
    @discardableResult
    mutating func editCurvePayload(
        nodeID: UUID,
        _ edit: (inout FFCurvePayload) throws -> Void
    ) throws -> Bool {
        guard let node = node(withID: nodeID),
              let geometry = node.geometry,
              case .curve(var payload) = geometry
        else { return false }
        try edit(&payload)
        return updateNode(withID: nodeID) { $0.geometry = .curve(payload) }
    }
}
