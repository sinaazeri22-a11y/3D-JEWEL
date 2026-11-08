import Foundation

/// A polynomial Bézier curve of arbitrary degree in the 2-D sketch plane.
struct Bezier2D: Equatable, Sendable {
    let controlPoints: [Vec2]

    init?(_ controlPoints: [Vec2]) {
        guard controlPoints.count >= 2 else { return nil }
        guard controlPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        self.controlPoints = controlPoints
    }

    private init(validated controlPoints: [Vec2]) {
        self.controlPoints = controlPoints
    }

    var degree: Int { controlPoints.count - 1 }
    var start: Vec2 { controlPoints[0] }
    var end: Vec2 { controlPoints[controlPoints.count - 1] }

    func point(at t: Double) -> Vec2 {
        Self.evaluate(controlPoints, at: FFMath.clamp(t, to: 0...1))
    }

    func derivative(at t: Double) -> Vec2 {
        let n = Double(degree)
        let differences = (0..<(controlPoints.count - 1)).map { index in
            (controlPoints[index + 1] - controlPoints[index]) * n
        }
        return Self.evaluate(differences, at: FFMath.clamp(t, to: 0...1))
    }

    func secondDerivative(at t: Double) -> Vec2 {
        guard degree >= 2 else { return .zero }
        let n = Double(degree)
        let scale = n * (n - 1)
        let differences: [Vec2] = (0..<(controlPoints.count - 2)).map { index -> Vec2 in
            let current = controlPoints[index]
            let next = controlPoints[index + 1]
            let following = controlPoints[index + 2]
            let difference = following - next * 2.0 + current
            return difference * scale
        }
        return Self.evaluate(differences, at: FFMath.clamp(t, to: 0...1))
    }

    /// De Casteljau split. The two returned curves both use `[0, 1]` as their
    /// parameter interval; the second is a retimed copy of the right side.
    func split(at t: Double) -> (Bezier2D, Bezier2D) {
        let t = FFMath.clamp(t, to: 0...1)
        var levels = [controlPoints]
        while let level = levels.last, level.count > 1 {
            var next: [Vec2] = []
            next.reserveCapacity(level.count - 1)
            for index in 0..<(level.count - 1) {
                next.append(level[index].lerp(to: level[index + 1], t: t))
            }
            levels.append(next)
        }

        let left = levels.map { $0[0] }
        let right = levels.map { $0[$0.count - 1] }.reversed()
        return (
            Bezier2D(validated: left),
            Bezier2D(validated: Array(right))
        )
    }

    func reversed() -> Bezier2D {
        Bezier2D(validated: Array(controlPoints.reversed()))
    }

    func transformed(by matrix: Mat3) -> Bezier2D {
        Bezier2D(validated: controlPoints.map { $0.transformed(by: matrix) })
    }

    private static func evaluate(_ points: [Vec2], at t: Double) -> Vec2 {
        guard points.count > 1 else { return points[0] }
        var level = points
        while level.count > 1 {
            var next: [Vec2] = []
            next.reserveCapacity(level.count - 1)
            for index in 0..<(level.count - 1) {
                next.append(level[index].lerp(to: level[index + 1], t: t))
            }
            level = next
        }
        return level[0]
    }
}

/// A clamped NURBS curve of arbitrary degree in the 2-D sketch plane.
///
/// The knot vector is normalised to the parameter interval `[0, 1]` and must
/// be clamped: the first `degree + 1` knots are zero and the last `degree + 1`
/// knots are one. Weights are positive, which keeps the rational denominator
/// away from zero for every parameter value.
struct NURBSCurve2D: Equatable, Sendable {
    let degree: Int
    let controlPoints: [Vec2]
    let weights: [Double]
    let knots: [Double]

    init?(
        degree: Int,
        controlPoints: [Vec2],
        weights providedWeights: [Double]? = nil,
        knots providedKnots: [Double]? = nil
    ) {
        guard degree >= 1, controlPoints.count >= degree + 1 else { return nil }
        guard controlPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }

        let resolvedWeights = providedWeights ?? [Double](repeating: 1, count: controlPoints.count)
        guard resolvedWeights.count == controlPoints.count else { return nil }
        guard resolvedWeights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }

        let rawKnots = providedKnots ?? Self.defaultKnots(
            degree: degree,
            pointCount: controlPoints.count
        )
        let lastControlIndex = controlPoints.count - 1
        guard rawKnots.count == controlPoints.count + degree + 1 else { return nil }
        guard rawKnots.allSatisfy({ $0.isFinite }) else { return nil }
        guard zip(rawKnots, rawKnots.dropFirst()).allSatisfy({ pair in pair.0 <= pair.1 }) else {
            return nil
        }

        let domainStart = rawKnots[degree]
        let domainEnd = rawKnots[lastControlIndex + 1]
        guard domainEnd > domainStart + FFMath.eps else { return nil }

        let normalized = rawKnots.map { ($0 - domainStart) / (domainEnd - domainStart) }
        guard normalized[0...degree].allSatisfy({ abs($0) <= 1e-12 }) else { return nil }
        guard normalized[(lastControlIndex + 1)...].allSatisfy({ abs($0 - 1) <= 1e-12 }) else {
            return nil
        }

        self.degree = degree
        self.controlPoints = controlPoints
        self.weights = resolvedWeights
        self.knots = normalized
    }

    var start: Vec2 { controlPoints[0] }
    var end: Vec2 { controlPoints[controlPoints.count - 1] }

    func point(at t: Double) -> Vec2 {
        let u = FFMath.clamp(t, to: 0...1)
        if u <= 0 { return start }
        if u >= 1 { return end }

        let spanIndex = span(at: u)
        let basis = basisFunctions(span: spanIndex, at: u)
        var x = 0.0
        var y = 0.0
        var denominator = 0.0

        for index in 0...degree {
            let controlIndex = spanIndex - degree + index
            let contribution = basis[index]
            let weight = weights[controlIndex]
            x += contribution * weight * controlPoints[controlIndex].x
            y += contribution * weight * controlPoints[controlIndex].y
            denominator += contribution * weight
        }

        guard abs(denominator) > FFMath.eps else { return start }
        return Vec2(x: x / denominator, y: y / denominator)
    }

    func derivative(at t: Double) -> Vec2 {
        let u = FFMath.clamp(t, to: 0...1)
        if u <= 0 { return endpointDerivative(atStart: true) }
        if u >= 1 { return endpointDerivative(atStart: false) }
        return euclideanDerivative(at: u)
    }

    func secondDerivative(at t: Double) -> Vec2 {
        // A finite difference of the analytic derivative is adequate for the
        // curvature consumers in the next phase and avoids a second rational
        // quotient rule here. The value is explicitly documented as an
        // approximation, not an exact second derivative.
        let u = FFMath.clamp(t, to: 0...1)
        let h = 1e-6
        let lower = max(0, u - h)
        let upper = min(1, u + h)
        guard upper > lower else { return .zero }
        return (derivative(at: upper) - derivative(at: lower)) / (upper - lower)
    }

    /// Split by inserting the parameter knot until its multiplicity reaches
    /// the degree, then extracting the two clamped control polygons. Both
    /// halves are retimed to `[0, 1]`.
    func split(at t: Double) -> (NURBSCurve2D, NURBSCurve2D)? {
        let u = FFMath.clamp(t, to: 0...1)
        guard u > 1e-12, u < 1 - 1e-12 else { return nil }

        var points = homogeneousControlPoints
        var currentKnots = knots
        let multiplicity = currentKnots.reduce(0) { count, knot in
            count + (abs(knot - u) <= 1e-12 ? 1 : 0)
        }
        let insertions = max(0, degree - multiplicity)
        for _ in 0..<insertions {
            let inserted = Self.insertKnot(
                points: points,
                knots: currentKnots,
                degree: degree,
                u: u
            )
            points = inserted.0
            currentKnots = inserted.1
        }

        let lastControlIndex = points.count - 1
        let spanIndex = Self.span(
            in: currentKnots,
            degree: degree,
            lastControlIndex: lastControlIndex,
            u: u
        )
        let splitIndex = spanIndex - degree
        guard splitIndex >= 0, splitIndex < points.count else { return nil }

        let leftPoints = Array(points[0...splitIndex])
        let rightPoints = Array(points[splitIndex...])

        var leftKnots = Array(currentKnots[0...spanIndex])
        leftKnots.append(u)
        var rightKnots = [Double](repeating: u, count: degree + 1)
        rightKnots.append(contentsOf: currentKnots[(spanIndex + 1)...])

        guard
            let left = Self.makeCurve(degree: degree, points: leftPoints, knots: leftKnots),
            let right = Self.makeCurve(degree: degree, points: rightPoints, knots: rightKnots)
        else {
            return nil
        }
        return (left, right)
    }

    func reversed() -> NURBSCurve2D? {
        let reversedPoints = Array(controlPoints.reversed())
        let reversedWeights = Array(weights.reversed())
        let reversedKnots = knots.reversed().map { 1 - $0 }
        return NURBSCurve2D(
            degree: degree,
            controlPoints: reversedPoints,
            weights: reversedWeights,
            knots: reversedKnots
        )
    }

    func transformed(by matrix: Mat3) -> NURBSCurve2D? {
        NURBSCurve2D(
            degree: degree,
            controlPoints: controlPoints.map { $0.transformed(by: matrix) },
            weights: weights,
            knots: knots
        )
    }

    private var homogeneousControlPoints: [Vec4] {
        (0..<controlPoints.count).map { index in
            let weight = weights[index]
            return Vec4(
                x: controlPoints[index].x * weight,
                y: controlPoints[index].y * weight,
                z: 0,
                w: weight
            )
        }
    }

    private func span(at u: Double) -> Int {
        Self.span(
            in: knots,
            degree: degree,
            lastControlIndex: controlPoints.count - 1,
            u: u
        )
    }

    private static func span(
        in knots: [Double],
        degree: Int,
        lastControlIndex: Int,
        u: Double
    ) -> Int {
        if u >= 1 { return lastControlIndex }
        if u <= 0 { return degree }

        var low = degree
        var high = lastControlIndex
        while low < high {
            let middle = (low + high + 1) / 2
            if knots[middle] <= u {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// The non-zero basis functions for one span, in control-point order.
    private func basisFunctions(span spanIndex: Int, at u: Double) -> [Double] {
        var values = [Double](repeating: 0, count: degree + 1)
        var left = [Double](repeating: 0, count: degree + 1)
        var right = [Double](repeating: 0, count: degree + 1)
        values[0] = 1

        if degree >= 1 {
            for order in 1...degree {
                left[order] = u - knots[spanIndex + 1 - order]
                right[order] = knots[spanIndex + order] - u
                var saved = 0.0
                for index in 0..<order {
                    let denominator = right[index + 1] + left[order - index]
                    let temp = denominator > 0 ? values[index] / denominator : 0
                    values[index] = saved + right[index + 1] * temp
                    saved = left[order - index] * temp
                }
                values[order] = saved
            }
        }
        return values
    }

    private func basisValue(index: Int, degree basisDegree: Int, u: Double) -> Double {
        guard index >= 0, index < controlPoints.count, basisDegree >= 0 else { return 0 }
        if basisDegree == 0 {
            if u >= 1 {
                return index == controlPoints.count - 1 ? 1 : 0
            }
            return (knots[index] <= u && u < knots[index + 1]) ? 1 : 0
        }

        let firstDenominator = knots[index + basisDegree] - knots[index]
        let secondDenominator = knots[index + basisDegree + 1] - knots[index + 1]
        var value = 0.0
        if firstDenominator > FFMath.eps {
            value += (u - knots[index]) / firstDenominator
                * basisValue(index: index, degree: basisDegree - 1, u: u)
        }
        if secondDenominator > FFMath.eps {
            value += (knots[index + basisDegree + 1] - u) / secondDenominator
                * basisValue(index: index + 1, degree: basisDegree - 1, u: u)
        }
        return value
    }

    private func homogeneousPoint(at u: Double) -> Vec4 {
        let spanIndex = span(at: u)
        let basis = basisFunctions(span: spanIndex, at: u)
        var x = 0.0
        var y = 0.0
        var denominator = 0.0

        for index in 0...degree {
            let controlIndex = spanIndex - degree + index
            let contribution = basis[index]
            let weight = weights[controlIndex]
            x += contribution * weight * controlPoints[controlIndex].x
            y += contribution * weight * controlPoints[controlIndex].y
            denominator += contribution * weight
        }
        return Vec4(x: x, y: y, z: 0, w: denominator)
    }

    private func homogeneousDerivative(at u: Double) -> Vec4 {
        var dx = 0.0
        var dy = 0.0
        var dw = 0.0

        for index in 0..<controlPoints.count {
            let firstDenominator = knots[index + degree] - knots[index]
            let secondDenominator = knots[index + degree + 1] - knots[index + 1]
            var coefficient = 0.0
            if firstDenominator > FFMath.eps {
                coefficient += Double(degree) / firstDenominator
                    * basisValue(index: index, degree: degree - 1, u: u)
            }
            if secondDenominator > FFMath.eps {
                coefficient -= Double(degree) / secondDenominator
                    * basisValue(index: index + 1, degree: degree - 1, u: u)
            }

            let weight = weights[index]
            dx += coefficient * weight * controlPoints[index].x
            dy += coefficient * weight * controlPoints[index].y
            dw += coefficient * weight
        }
        return Vec4(x: dx, y: dy, z: 0, w: dw)
    }

    private func euclideanDerivative(at u: Double) -> Vec2 {
        let value = homogeneousPoint(at: u)
        let derivative = homogeneousDerivative(at: u)
        guard abs(value.w) > FFMath.eps else { return .zero }
        let point = Vec2(x: value.x / value.w, y: value.y / value.w)
        return Vec2(
            x: (derivative.x - point.x * derivative.w) / value.w,
            y: (derivative.y - point.y * derivative.w) / value.w
        )
    }

    private func endpointDerivative(atStart: Bool) -> Vec2 {
        let lastIndex = controlPoints.count - 1
        let index = atStart ? 0 : lastIndex
        let nextIndex = atStart ? 1 : lastIndex - 1
        let denominator = atStart
            ? knots[degree + 1] - knots[1]
            : knots[lastIndex + degree] - knots[lastIndex]
        guard abs(denominator) > FFMath.eps else { return .zero }

        let weight = weights[index]
        let nextWeight = weights[nextIndex]
        let point = controlPoints[index]
        let nextPoint = controlPoints[nextIndex]
        let scale = Double(degree) / denominator
        let dx = scale * (nextPoint.x * nextWeight - point.x * weight)
        let dy = scale * (nextPoint.y * nextWeight - point.y * weight)
        let dw = scale * (nextWeight - weight)
        return Vec2(
            x: (dx - point.x * dw) / weight,
            y: (dy - point.y * dw) / weight
        )
    }

    private static func insertKnot(
        points: [Vec4],
        knots: [Double],
        degree: Int,
        u: Double
    ) -> ([Vec4], [Double]) {
        let lastControlIndex = points.count - 1
        let spanIndex = span(
            in: knots,
            degree: degree,
            lastControlIndex: lastControlIndex,
            u: u
        )
        var inserted = [Vec4](repeating: .zero, count: points.count + 1)

        for index in 0...(spanIndex - degree) {
            inserted[index] = points[index]
        }
        for index in (spanIndex - degree + 1)...spanIndex {
            let denominator = knots[index + degree] - knots[index]
            let alpha = denominator > FFMath.eps ? (u - knots[index]) / denominator : 0
            inserted[index] = points[index] * alpha + points[index - 1] * (1 - alpha)
        }
        for index in (spanIndex + 1)...(lastControlIndex + 1) {
            inserted[index] = points[index - 1]
        }

        var insertedKnots = Array(knots[0...spanIndex])
        insertedKnots.append(u)
        insertedKnots.append(contentsOf: knots[(spanIndex + 1)...])
        return (inserted, insertedKnots)
    }

    private static func makeCurve(
        degree: Int,
        points: [Vec4],
        knots: [Double]
    ) -> NURBSCurve2D? {
        guard let first = knots.first, let last = knots.last else { return nil }
        guard last > first + FFMath.eps else { return nil }
        let normalized = knots.map { ($0 - first) / (last - first) }
        let controlPoints = points.map { Vec2(x: $0.x / $0.w, y: $0.y / $0.w) }
        let weights = points.map { $0.w }
        return NURBSCurve2D(
            degree: degree,
            controlPoints: controlPoints,
            weights: weights,
            knots: normalized
        )
    }

    private static func defaultKnots(degree: Int, pointCount: Int) -> [Double] {
        let lastControlIndex = pointCount - 1
        var knots = [Double](repeating: 0, count: degree + 1)
        let internalKnots = lastControlIndex - degree
        if internalKnots > 0 {
            for index in 1...internalKnots {
                knots.append(Double(index) / Double(internalKnots + 1))
            }
        }
        knots.append(contentsOf: [Double](repeating: 1, count: degree + 1))
        return knots
    }
}

/// The result of a closest-point query, including the curve parameter.
struct CurveClosestPoint: Equatable, Sendable {
    let point: Vec2
    let parameter: Double
    let distance: Double
}

/// A curve type that the rest of the kernel can consume without caring whether
/// the source is polynomial or rational.
enum Curve2D: Equatable, Sendable {
    case bezier(Bezier2D)
    case nurbs(NURBSCurve2D)

    var start: Vec2 {
        switch self {
        case .bezier(let curve): return curve.start
        case .nurbs(let curve): return curve.start
        }
    }

    var end: Vec2 {
        switch self {
        case .bezier(let curve): return curve.end
        case .nurbs(let curve): return curve.end
        }
    }

    func point(at t: Double) -> Vec2 {
        switch self {
        case .bezier(let curve): return curve.point(at: t)
        case .nurbs(let curve): return curve.point(at: t)
        }
    }

    func derivative(at t: Double) -> Vec2 {
        switch self {
        case .bezier(let curve): return curve.derivative(at: t)
        case .nurbs(let curve): return curve.derivative(at: t)
        }
    }

    func secondDerivative(at t: Double) -> Vec2 {
        switch self {
        case .bezier(let curve): return curve.secondDerivative(at: t)
        case .nurbs(let curve): return curve.secondDerivative(at: t)
        }
    }

    func split(at t: Double) -> (Curve2D, Curve2D)? {
        switch self {
        case .bezier(let curve):
            let pieces = curve.split(at: t)
            return (.bezier(pieces.0), .bezier(pieces.1))
        case .nurbs(let curve):
            guard let pieces = curve.split(at: t) else { return nil }
            return (.nurbs(pieces.0), .nurbs(pieces.1))
        }
    }

    func reversed() -> Curve2D? {
        switch self {
        case .bezier(let curve): return .bezier(curve.reversed())
        case .nurbs(let curve):
            guard let reversed = curve.reversed() else { return nil }
            return .nurbs(reversed)
        }
    }

    func transformed(by matrix: Mat3) -> Curve2D {
        switch self {
        case .bezier(let curve): return .bezier(curve.transformed(by: matrix))
        case .nurbs(let curve):
            guard let transformed = curve.transformed(by: matrix) else { return self }
            return .nurbs(transformed)
        }
    }

    /// Gauss–Legendre integration of the parametric speed. The interval is
    /// split into eight panels before adaptive refinement, which keeps a full
    /// circle and multi-span NURBS curves well inside the 1e-6 acceptance bar.
    func arcLength(from start: Double = 0, to end: Double = 1, tolerance: Double = 1e-10) -> Double {
        let lower = FFMath.clamp(start, to: 0...1)
        let upper = FFMath.clamp(end, to: 0...1)
        guard upper > lower else { return 0 }

        let pieces = 8
        let pieceLength = (upper - lower) / Double(pieces)
        let pieceTolerance = max(tolerance / Double(pieces), 1e-13)
        var total = 0.0
        for index in 0..<pieces {
            let a = lower + Double(index) * pieceLength
            let b = a + pieceLength
            total += GaussLegendre.adaptiveArcLength(
                speed: { self.derivative(at: $0).length },
                from: a,
                to: b,
                tolerance: pieceTolerance,
                depth: 0
            )
        }
        return total
    }

    func closestPoint(to query: Vec2, tolerance: Double = 1e-10) -> CurveClosestPoint {
        let sampleCount = 128
        let step = 1.0 / Double(sampleCount)
        var sampleDistances = [Double](repeating: 0, count: sampleCount + 1)

        for index in 0...sampleCount {
            sampleDistances[index] = squaredDistance(
                query,
                point(at: Double(index) * step)
            )
        }

        var bestParameter = 0.0
        var bestSquaredDistance = sampleDistances[0]
        for index in 1...sampleCount where sampleDistances[index] < bestSquaredDistance {
            bestSquaredDistance = sampleDistances[index]
            bestParameter = Double(index) * step
        }

        var ranges: [(Double, Double)] = []
        if sampleCount > 1 {
            for index in 1..<sampleCount {
                if sampleDistances[index] <= sampleDistances[index - 1]
                    && sampleDistances[index] <= sampleDistances[index + 1]
                {
                    ranges.append((
                        Double(index - 1) * step,
                        Double(index + 1) * step
                    ))
                }
            }
        }
        // The global minimum can sit between an endpoint and the first
        // interior sample. A full-domain golden section is not unimodal on a
        // closed curve, so bracket that boundary interval explicitly.
        if sampleDistances[0] <= sampleDistances[1] {
            ranges.append((0, 2 * step))
        }
        if sampleDistances[sampleCount] <= sampleDistances[sampleCount - 1] {
            ranges.append((1 - 2 * step, 1))
        }
        if ranges.isEmpty { ranges = [(0, 1)] }

        for range in ranges {
            let parameter = minimizeSquaredDistance(
                to: query,
                from: range.0,
                to: range.1,
                tolerance: tolerance
            )
            let distance = squaredDistance(query, point(at: parameter))
            if distance < bestSquaredDistance {
                bestSquaredDistance = distance
                bestParameter = parameter
            }
        }

        return CurveClosestPoint(
            point: point(at: bestParameter),
            parameter: bestParameter,
            distance: bestSquaredDistance.squareRoot()
        )
    }

    func joined(to other: Curve2D, tolerance: Double = FFTolerance.curveJoin) -> CurvePath2D? {
        guard end.distance(to: other.start) <= tolerance else { return nil }
        return CurvePath2D(curves: [self, other])
    }

    private func minimizeSquaredDistance(
        to query: Vec2,
        from low: Double,
        to high: Double,
        tolerance: Double
    ) -> Double {
        var lower = low
        var upper = high
        let ratio = (5.0.squareRoot() - 1) * 0.5
        var first = upper - ratio * (upper - lower)
        var second = lower + ratio * (upper - lower)
        var firstDistance = squaredDistance(query, point(at: first))
        var secondDistance = squaredDistance(query, point(at: second))

        for _ in 0..<80 {
            if firstDistance < secondDistance {
                upper = second
                second = first
                secondDistance = firstDistance
                first = upper - ratio * (upper - lower)
                firstDistance = squaredDistance(query, point(at: first))
            } else {
                lower = first
                first = second
                firstDistance = secondDistance
                second = lower + ratio * (upper - lower)
                secondDistance = squaredDistance(query, point(at: second))
            }
            if upper - lower <= tolerance { break }
        }
        return (lower + upper) * 0.5
    }

    private func squaredDistance(_ lhs: Vec2, _ rhs: Vec2) -> Double {
        (lhs - rhs).lengthSquared
    }
}

/// A connected sequence of curves. The path parameter is distributed evenly
/// across its segments; it is a modelling parameter, not arc length.
struct CurvePath2D: Equatable, Sendable {
    let curves: [Curve2D]

    init?(curves: [Curve2D]) {
        guard !curves.isEmpty else { return nil }
        self.curves = curves
    }

    static func joining(_ curves: [Curve2D], tolerance: Double = FFTolerance.curveJoin) -> CurvePath2D? {
        guard let first = curves.first else { return nil }
        var previous = first
        for curve in curves.dropFirst() {
            guard previous.end.distance(to: curve.start) <= tolerance else { return nil }
            previous = curve
        }
        return CurvePath2D(curves: curves)
    }

    var start: Vec2 { curves[0].start }
    var end: Vec2 { curves[curves.count - 1].end }

    func isClosed(tolerance: Double = FFTolerance.curveJoin) -> Bool {
        start.distance(to: end) <= tolerance
    }

    func point(at t: Double) -> Vec2 {
        let clamped = FFMath.clamp(t, to: 0...1)
        let scaled = clamped * Double(curves.count)
        var index = Int(scaled)
        if index >= curves.count { index = curves.count - 1 }
        let local = scaled - Double(index)
        return curves[index].point(at: local)
    }

    func derivative(at t: Double) -> Vec2 {
        let clamped = FFMath.clamp(t, to: 0...1)
        let scaled = clamped * Double(curves.count)
        var index = Int(scaled)
        if index >= curves.count { index = curves.count - 1 }
        let local = scaled - Double(index)
        return curves[index].derivative(at: local) * Double(curves.count)
    }

    func split(at t: Double) -> (CurvePath2D, CurvePath2D)? {
        let clamped = FFMath.clamp(t, to: 0...1)
        guard clamped > 1e-12, clamped < 1 - 1e-12 else { return nil }

        let scaled = clamped * Double(curves.count)
        let index = min(Int(scaled), curves.count - 1)
        let local = scaled - Double(index)

        if local <= 1e-12 {
            guard index > 0, index < curves.count else { return nil }
            guard
                let left = CurvePath2D(curves: Array(curves[0..<index])),
                let right = CurvePath2D(curves: Array(curves[index...]))
            else {
                return nil
            }
            return (left, right)
        }
        if local >= 1 - 1e-12 {
            let boundary = index + 1
            guard boundary > 0, boundary < curves.count else { return nil }
            guard
                let left = CurvePath2D(curves: Array(curves[0..<boundary])),
                let right = CurvePath2D(curves: Array(curves[boundary...]))
            else {
                return nil
            }
            return (left, right)
        }

        guard let pieces = curves[index].split(at: local) else { return nil }
        var leftCurves = Array(curves[0..<index])
        leftCurves.append(pieces.0)
        var rightCurves = [pieces.1]
        rightCurves.append(contentsOf: curves[(index + 1)...])
        guard
            let left = CurvePath2D(curves: leftCurves),
            let right = CurvePath2D(curves: rightCurves)
        else {
            return nil
        }
        return (left, right)
    }

    func arcLength(tolerance: Double = 1e-10) -> Double {
        let perCurve = max(tolerance / Double(curves.count), 1e-13)
        return curves.reduce(0) { total, curve in
            total + curve.arcLength(tolerance: perCurve)
        }
    }

    func closestPoint(to query: Vec2, tolerance: Double = 1e-10) -> CurveClosestPoint {
        var bestIndex = 0
        var best = curves[0].closestPoint(to: query, tolerance: tolerance)
        for index in 1..<curves.count {
            let candidate = curves[index].closestPoint(to: query, tolerance: tolerance)
            if candidate.distance < best.distance {
                best = candidate
                bestIndex = index
            }
        }
        let parameter = (Double(bestIndex) + best.parameter) / Double(curves.count)
        return CurveClosestPoint(
            point: best.point,
            parameter: parameter,
            distance: best.distance
        )
    }

    func transformed(by matrix: Mat3) -> CurvePath2D {
        CurvePath2D(curves: curves.map { $0.transformed(by: matrix) }) ?? self
    }
}

/// Sixteen-point Gauss–Legendre quadrature plus adaptive panel refinement.
private enum GaussLegendre {
    static let nodes: [Double] = [
        0.09501250983763744,
        0.2816035507792589,
        0.4580167776572274,
        0.6178762444026438,
        0.755404408355003,
        0.8656312023878318,
        0.9445750230732326,
        0.9894009349916499,
    ]

    static let weights: [Double] = [
        0.1894506104550685,
        0.1826034150449236,
        0.1691565193950025,
        0.1495959888165767,
        0.1246289712555339,
        0.0951585116824928,
        0.0622535239386479,
        0.0271524594117541,
    ]

    static func integrate(
        _ function: (Double) -> Double,
        from lower: Double,
        to upper: Double
    ) -> Double {
        let midpoint = (lower + upper) * 0.5
        let halfWidth = (upper - lower) * 0.5
        var sum = 0.0
        for index in 0..<nodes.count {
            let offset = halfWidth * nodes[index]
            sum += weights[index] * (
                function(midpoint - offset) + function(midpoint + offset)
            )
        }
        return halfWidth * sum
    }

    static func adaptiveArcLength(
        speed: (Double) -> Double,
        from lower: Double,
        to upper: Double,
        tolerance: Double,
        depth: Int
    ) -> Double {
        let whole = integrate(speed, from: lower, to: upper)
        let middle = (lower + upper) * 0.5
        let halves = integrate(speed, from: lower, to: middle)
            + integrate(speed, from: middle, to: upper)
        if depth >= 14 || abs(halves - whole) <= tolerance * max(1, abs(halves)) {
            return halves
        }
        return adaptiveArcLength(
            speed: speed,
            from: lower,
            to: middle,
            tolerance: tolerance * 0.5,
            depth: depth + 1
        ) + adaptiveArcLength(
            speed: speed,
            from: middle,
            to: upper,
            tolerance: tolerance * 0.5,
            depth: depth + 1
        )
    }
}

extension Mat3 {
    /// A 2-D affine translation embedded in the homogeneous 3×3 matrix.
    static func translation2D(_ offset: Vec2) -> Mat3 {
        Mat3(
            m00: 1, m01: 0, m02: offset.x,
            m10: 0, m11: 1, m12: offset.y,
            m20: 0, m21: 0, m22: 1
        )
    }

    static func scale2D(x: Double, y: Double) -> Mat3 {
        Mat3(
            m00: x, m01: 0, m02: 0,
            m10: 0, m11: y, m12: 0,
            m20: 0, m21: 0, m22: 1
        )
    }

    static func rotation2D(_ angle: Double) -> Mat3 {
        rotationZ(angle)
    }
}

extension Vec2 {
    /// Applies an affine 2-D transform stored in a homogeneous 3×3 matrix.
    func transformed(by matrix: Mat3) -> Vec2 {
        let transformed = matrix * Vec3(x: x, y: y, z: 1)
        return Vec2(x: transformed.x, y: transformed.y)
    }
}
