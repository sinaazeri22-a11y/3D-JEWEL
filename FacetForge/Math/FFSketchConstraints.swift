import Foundation

/// One constraint a sketch can carry in Phase 51's solver.
///
/// The four kinds are exactly the row's four. Horizontal and vertical are stated
/// on one segment, equal length compares two segments' lengths, and tangency
/// joins two neighbouring segments at their shared vertex.
///
/// Tangency means the second span *continues* the first: the signed turn angle
/// there is zero. A half turn also makes the directions parallel but folds the
/// sketch back over itself, so it is not a tangent.
///
/// Every kind is translation- and scale-invariant. That premise is what the
/// solver's gauge is built on: these constraints reshape a sketch, they never
/// translate or resize it. Without a gauge their solution set is a cone through
/// the origin — the zero configuration satisfies all of them — and a plain
/// Gauss-Newton step slides a rectangle toward that apex, which a local model
/// measured as a 10 mm rectangle collapsing to a 0.007 mm square.
enum FFSketchConstraint: Equatable, Sendable {
    case horizontal(segment: Int)
    case vertical(segment: Int)
    case equalLength(first: Int, second: Int)
    case tangent(first: Int, second: Int)

    /// A sentence a readout or a refusal can carry.
    var label: String {
        switch self {
        case .horizontal(let segment):
            return "Horizontal on segment \(segment)"
        case .vertical(let segment):
            return "Vertical on segment \(segment)"
        case .equalLength(let first, let second):
            return "Equal length on segments \(first) and \(second)"
        case .tangent(let first, let second):
            return "Tangent on segments \(first) and \(second)"
        }
    }
}

/// Why a constraint set could not even be attempted.
///
/// These are structural refusals, distinct from a solved-but-unsatisfied
/// system: a bad index, a segment that is not a straight span, a tangency
/// between segments that do not share a vertex, a sketch whose points all
/// coincide. Each has its own sentence so a refusal never hides behind a
/// generic message.
enum FFSketchConstraintError: Error, Equatable, LocalizedError {
    case segmentOutOfRange(Int)
    case segmentNotStraight(Int)
    case chainNotContiguous(Int)
    case tangentNeedsNeighbour(Int, Int)
    case coincidentSketch
    case noConstraints

    var errorDescription: String? {
        switch self {
        case .segmentOutOfRange(let index):
            return "Segment \(index + 1) is not part of that curve"
        case .segmentNotStraight(let index):
            return "Segment \(index + 1) is not a straight span, so it has no chord to constrain"
        case .chainNotContiguous(let index):
            return "Segment \(index + 1) does not start where the one before it ended"
        case .tangentNeedsNeighbour(let first, let second):
            return "Segments \(first) and \(second) do not share a vertex, so they have no joint to make tangent"
        case .coincidentSketch:
            return "Every point of that sketch is in the same place, so there is no shape to constrain"
        case .noConstraints:
            return "Choose at least one constraint"
        }
    }
}

/// A sketch as the solver sees it: the vertices and whether the chain closes.
///
/// A straight two-point Bézier span is the only segment Phase 39-50 writes, so
/// the solver's variables are its vertices and nothing else. A payload with an
/// arc, a spline or a break in the chain is refused with a sentence rather than
/// silently constrained on its control points.
struct FFSketchPolyline: Equatable, Sendable {
    var vertices: [Vec2]
    var isClosed: Bool

    var segmentCount: Int {
        guard vertices.count > 1 else { return 0 }
        return isClosed ? vertices.count : vertices.count - 1
    }

    /// The two vertex indices a segment joins. The closing segment of a closed
    /// chain ends at vertex zero.
    func endpoints(ofSegment index: Int) -> (start: Int, end: Int)? {
        guard index >= 0, index < segmentCount else { return nil }
        return (index, (index + 1) % vertices.count)
    }

    init(payload: FFCurvePayload) throws {
        guard !payload.segments.isEmpty else {
            throw FFSketchConstraintError.segmentOutOfRange(0)
        }
        for (index, segment) in payload.segments.enumerated() {
            guard segment.kind == .bezier,
                  segment.controlPoints.count == 2,
                  segment.weights.isEmpty,
                  segment.knots.isEmpty
            else {
                throw FFSketchConstraintError.segmentNotStraight(index)
            }
        }
        var points: [Vec2] = [payload.segments[0].controlPoints[0].vector]
        points.append(contentsOf: payload.segments.map { $0.controlPoints[1].vector })
        for index in 1..<payload.segments.count {
            let previousEnd = payload.segments[index - 1].controlPoints[1].vector
            let start = payload.segments[index].controlPoints[0].vector
            guard previousEnd.distance(to: start) <= FFTolerance.curveJoin else {
                throw FFSketchConstraintError.chainNotContiguous(index)
            }
        }
        if payload.isClosed {
            let lastEnd = payload.segments[payload.segments.count - 1].controlPoints[1].vector
            guard lastEnd.distance(to: points[0]) <= FFTolerance.curveJoin else {
                throw FFSketchConstraintError.chainNotContiguous(payload.segments.count - 1)
            }
            points.removeLast()
        }
        vertices = points
        isClosed = payload.isClosed
    }

    init(vertices: [Vec2], isClosed: Bool) {
        self.vertices = vertices
        self.isClosed = isClosed
    }

    /// The payload this vertex list writes back to. Every segment is the same
    /// straight two-point span the payload arrived with, so a constrained sketch
    /// stays an ordinary curve and no document field or format byte changes.
    func payload() -> FFCurvePayload {
        var segments: [FFCurveSegment] = []
        for index in 0..<segmentCount {
            guard let ends = endpoints(ofSegment: index) else { break }
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [
                    FFPoint2(vertices[ends.start]),
                    FFPoint2(vertices[ends.end]),
                ]
            ))
        }
        return FFCurvePayload(segments: segments, isClosed: isClosed)
    }
}

/// What the solver did, in the terms a readout needs.
///
/// `conflicts` is empty exactly when every requested constraint holds. When it
/// is not, `polyline` still carries a usable shape — the one the accepted
/// prefix produced — so a caller can preview the best effort without writing it.
struct FFSketchConstraintSolution: Equatable, Sendable {
    var polyline: FFSketchPolyline
    var iterations: Int
    var residual: Double
    var degreesOfFreedom: Int
    var applied: [FFSketchConstraint]
    var conflicts: [FFSketchConstraint]

    var isSatisfied: Bool { conflicts.isEmpty }
}

/// Phase 51's solver: damped Gauss-Newton on the constraint residuals, with a
/// hard gauge and an incremental over-constraint report.
///
/// The tolerances are matched to the producing method, not to ideal geometry.
/// A local model of this exact loop measured residuals between 1e-16 and 8e-10
/// and at most 4 iterations on its 15 fixtures and 24 generated chains, so a
/// converged geometry is asserted at 1e-9 and the iteration budget at 9: above
/// the measured noise and inside the 4-minute-safe cost the row names.
///
/// Residuals carry their own units: millimetres for span offsets and length
/// differences, radians for the tangent's turn angle. One tolerance covers both
/// because both are the same kind of claim: a deviation far below any geometry
/// the interface displays (0.001 mm) or any angle it shows (0.01°).
enum FFSketchConstraintSolver {
    /// A constraint counts as satisfied below this, in its own unit.
    static let residualTolerance = 1e-9

    /// The row's "< 10 iterations", with one spare so a converged solution is
    /// never reported as a failure at exactly the boundary.
    static let maximumIterations = 9

    /// Tikhonov damping on the normal equations. It is what keeps a
    /// rank-deficient system (one horizontal constraint on a long chain) solvable
    /// and it pins the under-determined degrees of freedom near their start.
    static let damping = 1e-10

    /// A segment shorter than this is not geometry. It is the backstop that
    /// stops the solver from claiming success on a collapsed sketch, and it is
    /// what makes a genuinely impossible set like "vertical and horizontal made
    /// tangent" report a conflict instead of a zero-length answer.
    static let minimumSegmentLength = 1e-6

    /// How far a step may be scaled down while searching for a decrease.
    static let backtrackingSteps = 12

    static func solve(
        _ polyline: FFSketchPolyline,
        constraints: [FFSketchConstraint]
    ) throws -> FFSketchConstraintSolution {
        try validate(polyline, constraints: constraints)
        let total = polyline.vertices.count * 2
        let full = attempt(polyline, constraints: constraints)
        guard full.isSatisfied else {
            // Incremental acceptance. A constraint is added only when the set so
            // far still has a solution, so the first one that does not is the
            // constraint that over-constrains the sketch. This is the order the
            // caller added them in, which is the order a user adds them in.
            //
            // Reported as a *solver verdict*, not a proof: with scale-invariant
            // constraints some systems have a valid solution on a branch this
            // loop never reaches, and the report says which constraint could not
            // be accepted from this geometry rather than claiming that no
            // solution exists at all.
            var applied: [FFSketchConstraint] = []
            var conflict: FFSketchConstraint?
            for constraint in constraints {
                let trial = attempt(polyline, constraints: applied + [constraint])
                if trial.isSatisfied {
                    applied.append(constraint)
                } else {
                    conflict = constraint
                    break
                }
            }
            // With nothing accepted there is nothing to write, so the sketch the
            // caller gets back is the one it passed in, not the collapsed shape
            // the refused attempt wandered to.
            guard !applied.isEmpty else {
                return FFSketchConstraintSolution(
                    polyline: polyline,
                    iterations: 0,
                    residual: 0,
                    degreesOfFreedom: max(0, total - 3),
                    applied: [],
                    conflicts: conflict.map { [$0] } ?? []
                )
            }
            let accepted = attempt(polyline, constraints: applied)
            return FFSketchConstraintSolution(
                polyline: FFSketchPolyline(
                    vertices: accepted.points,
                    isClosed: polyline.isClosed
                ),
                iterations: accepted.iterations,
                residual: accepted.residual,
                degreesOfFreedom: degreesOfFreedom(accepted.rows, variables: total),
                applied: applied,
                conflicts: conflict.map { [$0] } ?? []
            )
        }
        return FFSketchConstraintSolution(
            polyline: FFSketchPolyline(vertices: full.points, isClosed: polyline.isClosed),
            iterations: full.iterations,
            residual: full.residual,
            degreesOfFreedom: degreesOfFreedom(full.rows, variables: total),
            applied: constraints,
            conflicts: []
        )
    }

    // MARK: - Structure

    private static func validate(
        _ polyline: FFSketchPolyline,
        constraints: [FFSketchConstraint]
    ) throws {
        guard !constraints.isEmpty else { throw FFSketchConstraintError.noConstraints }
        guard polyline.segmentCount > 0 else {
            throw FFSketchConstraintError.segmentOutOfRange(0)
        }
        for constraint in constraints {
            switch constraint {
            case .horizontal(let segment), .vertical(let segment):
                guard segment >= 0, segment < polyline.segmentCount else {
                    throw FFSketchConstraintError.segmentOutOfRange(segment)
                }
            case .equalLength(let first, let second):
                for index in [first, second] where index < 0 || index >= polyline.segmentCount {
                    throw FFSketchConstraintError.segmentOutOfRange(index)
                }
            case .tangent(let first, let second):
                for index in [first, second] where index < 0 || index >= polyline.segmentCount {
                    throw FFSketchConstraintError.segmentOutOfRange(index)
                }
                let endsFirst = polyline.endpoints(ofSegment: first)
                let endsSecond = polyline.endpoints(ofSegment: second)
                guard endsFirst?.end == endsSecond?.start else {
                    throw FFSketchConstraintError.tangentNeedsNeighbour(first, second)
                }
            }
        }
    }

    // MARK: - One attempt

    private struct Term {
        var variable: Int
        var value: Double
    }

    private struct Attempt {
        var points: [Vec2]
        var iterations: Int
        var residual: Double
        var rows: [[Term]]
        var isSatisfied: Bool
    }

    private static func attempt(
        _ polyline: FFSketchPolyline,
        constraints: [FFSketchConstraint]
    ) -> Attempt {
        let count = polyline.vertices.count
        let variables = count * 2
        let centre = centroid(polyline.vertices)
        let radius = rmsRadius(polyline.vertices, centre: centre)
        guard radius > minimumSegmentLength else {
            return Attempt(
                points: polyline.vertices,
                iterations: 0,
                residual: .infinity,
                rows: [],
                isSatisfied: false
            )
        }

        var x = flatten(polyline.vertices)
        x = project(x, points: count, centre: centre, radius: radius)
        var iterations = 0
        var residual = Double.infinity
        var rows: [[Term]] = []
        var collapsed = false

        while true {
            guard let evaluated = evaluate(x, polyline: polyline, constraints: constraints) else {
                collapsed = true
                break
            }
            rows = evaluated.rows
            let worst = evaluated.residuals.map { abs($0) }.max() ?? 0
            residual = worst
            if worst <= residualTolerance || iterations >= maximumIterations { break }

            var matrix = [[Double]](repeating: [Double](repeating: 0, count: variables), count: variables)
            var gradient = [Double](repeating: 0, count: variables)
            for (index, row) in rows.enumerated() {
                for term in row {
                    gradient[term.variable] += term.value * evaluated.residuals[index]
                }
                for first in row {
                    for second in row {
                        matrix[first.variable][second.variable] += first.value * second.value
                    }
                }
            }
            for index in 0..<variables { matrix[index][index] += damping }
            guard let step = solveLinear(matrix, rhs: gradient.map { -$0 }) else { break }

            let meritBefore = merit(evaluated.residuals)
            var scale = 1.0
            var accepted = false
            for _ in 0..<backtrackingSteps {
                var stepped = x
                for index in 0..<variables {
                    stepped[index] += scale * step[index]
                }
                let trial = project(
                    stepped,
                    points: count,
                    centre: centre,
                    radius: radius
                )
                if let trialEvaluation = evaluate(trial, polyline: polyline, constraints: constraints),
                   merit(trialEvaluation.residuals) <= meritBefore {
                    x = trial
                    accepted = true
                    break
                }
                scale *= 0.5
            }
            if !accepted { break }
            iterations += 1
            if step.map({ abs(scale * $0) }).max() ?? 0 <= 1e-13 { break }
        }

        let points = points(from: x, count: count)
        let lengths = segmentLengths(points, isClosed: polyline.isClosed)
        let isValid = !collapsed
            && !lengths.isEmpty
            && lengths.allSatisfy { $0 >= minimumSegmentLength }
        return Attempt(
            points: points,
            iterations: iterations,
            residual: residual,
            rows: rows,
            isSatisfied: residual <= residualTolerance && isValid
        )
    }

    private struct Evaluation {
        var residuals: [Double]
        var rows: [[Term]]
    }

    /// Every residual and its analytic derivatives. Returns nil when a segment
    /// has collapsed, because a direction and a length have no derivative there.
    private static func evaluate(
        _ x: [Double],
        polyline: FFSketchPolyline,
        constraints: [FFSketchConstraint]
    ) -> Evaluation? {
        let points = points(from: x, count: polyline.vertices.count)
        var residuals: [Double] = []
        var rows: [[Term]] = []

        for constraint in constraints {
            switch constraint {
            case .horizontal(let segment):
                guard let ends = polyline.endpoints(ofSegment: segment) else { return nil }
                residuals.append(points[ends.end].y - points[ends.start].y)
                rows.append([
                    Term(variable: ends.start * 2 + 1, value: -1),
                    Term(variable: ends.end * 2 + 1, value: 1),
                ])
            case .vertical(let segment):
                guard let ends = polyline.endpoints(ofSegment: segment) else { return nil }
                residuals.append(points[ends.end].x - points[ends.start].x)
                rows.append([
                    Term(variable: ends.start * 2, value: -1),
                    Term(variable: ends.end * 2, value: 1),
                ])
            case .equalLength(let first, let second):
                guard let a = polyline.endpoints(ofSegment: first),
                      let b = polyline.endpoints(ofSegment: second)
                else { return nil }
                let firstSpan = points[a.end] - points[a.start]
                let secondSpan = points[b.end] - points[b.start]
                let firstLength = firstSpan.length
                let secondLength = secondSpan.length
                guard firstLength > 0, secondLength > 0 else { return nil }
                let firstUnit = firstSpan / firstLength
                let secondUnit = secondSpan / secondLength
                residuals.append(firstLength - secondLength)
                rows.append([
                    Term(variable: a.start * 2, value: -firstUnit.x),
                    Term(variable: a.start * 2 + 1, value: -firstUnit.y),
                    Term(variable: a.end * 2, value: firstUnit.x),
                    Term(variable: a.end * 2 + 1, value: firstUnit.y),
                    Term(variable: b.start * 2, value: secondUnit.x),
                    Term(variable: b.start * 2 + 1, value: secondUnit.y),
                    Term(variable: b.end * 2, value: -secondUnit.x),
                    Term(variable: b.end * 2 + 1, value: -secondUnit.y),
                ])
            case .tangent(let first, let second):
                // The signed turn angle atan2(sin, cos), in radians.
                //
                // sin alone also vanishes at a half turn, where the second span
                // doubles back over the first. That is a fold, not a tangent,
                // and a local model of this loop landed on it for three of eight
                // generated chains until the residual became the angle, which is
                // zero only where the second span continues the first.
                guard let a = polyline.endpoints(ofSegment: first),
                      let b = polyline.endpoints(ofSegment: second),
                      a.end == b.start
                else { return nil }
                let joint = a.end
                let tail = b.end
                let span = points[joint] - points[a.start]
                let leaving = points[tail] - points[joint]
                let firstLength = span.length
                let secondLength = leaving.length
                guard firstLength > 0, secondLength > 0 else { return nil }
                let u = span / firstLength
                let v = leaving / secondLength
                let sine = u.cross(v)
                let cosine = u.dot(v)
                let angle = atan2(sine, cosine)

                // theta = atan2(c, d) with c = u x v, d = u . v, so
                // d(theta) = d * dc - c * dd. Each of c and d is a function of
                // both unit directions, and each unit direction's derivative is
                // (I - u u^T) / |segment|. The joint carries both dependencies,
                // which is why its row is the negated sum of the other two.
                let crossRowStart = Vec2(
                    x: (sine * u.x - v.y) / firstLength,
                    y: (sine * u.y + v.x) / firstLength
                )
                let crossRowTail = Vec2(
                    x: (-u.y - sine * v.x) / secondLength,
                    y: (u.x - sine * v.y) / secondLength
                )
                let dotRowStart = Vec2(
                    x: -(v.x - cosine * u.x) / firstLength,
                    y: -(v.y - cosine * u.y) / firstLength
                )
                let dotRowTail = Vec2(
                    x: (u.x - cosine * v.x) / secondLength,
                    y: (u.y - cosine * v.y) / secondLength
                )

                residuals.append(angle)
                rows.append([
                    Term(
                        variable: a.start * 2,
                        value: cosine * crossRowStart.x - sine * dotRowStart.x
                    ),
                    Term(
                        variable: a.start * 2 + 1,
                        value: cosine * crossRowStart.y - sine * dotRowStart.y
                    ),
                    Term(
                        variable: joint * 2,
                        value: -cosine * (crossRowStart.x + crossRowTail.x)
                            + sine * (dotRowStart.x + dotRowTail.x)
                    ),
                    Term(
                        variable: joint * 2 + 1,
                        value: -cosine * (crossRowStart.y + crossRowTail.y)
                            + sine * (dotRowStart.y + dotRowTail.y)
                    ),
                    Term(
                        variable: tail * 2,
                        value: cosine * crossRowTail.x - sine * dotRowTail.x
                    ),
                    Term(
                        variable: tail * 2 + 1,
                        value: cosine * crossRowTail.y - sine * dotRowTail.y
                    ),
                ])
            }
        }
        return Evaluation(residuals: residuals, rows: rows)
    }

    // MARK: - Gauge

    private static func centroid(_ points: [Vec2]) -> Vec2 {
        guard !points.isEmpty else { return .zero }
        let total = points.reduce(Vec2.zero) { $0 + $1 }
        return total / Double(points.count)
    }

    private static func rmsRadius(_ points: [Vec2], centre: Vec2) -> Double {
        guard !points.isEmpty else { return 0 }
        let moment = points.reduce(0.0) { $0 + ($1 - centre).lengthSquared }
        return (moment / Double(points.count)).squareRoot()
    }

    /// Translates the sketch back to the gauge centroid and rescales it to the
    /// gauge radius. This is the hard gauge: the constraints are scale- and
    /// translation-invariant, so without it every system has a degenerate answer
    /// at the origin and the solver would find it.
    private static func project(
        _ x: [Double],
        points count: Int,
        centre: Vec2,
        radius: Double
    ) -> [Double] {
        guard count > 0 else { return x }
        var sumX = 0.0
        var sumY = 0.0
        for index in 0..<count {
            sumX += x[index * 2]
            sumY += x[index * 2 + 1]
        }
        let currentCentre = Vec2(x: sumX / Double(count), y: sumY / Double(count))
        var moment = 0.0
        for index in 0..<count {
            let dx = x[index * 2] - currentCentre.x
            let dy = x[index * 2 + 1] - currentCentre.y
            moment += dx * dx + dy * dy
        }
        let current = (moment / Double(count)).squareRoot()
        let scale = current > 1e-300 ? radius / current : 1.0
        var result = [Double](repeating: 0, count: x.count)
        for index in 0..<count {
            result[index * 2] = centre.x + (x[index * 2] - currentCentre.x) * scale
            result[index * 2 + 1] = centre.y + (x[index * 2 + 1] - currentCentre.y) * scale
        }
        return result
    }

    // MARK: - Linear algebra

    private static func flatten(_ points: [Vec2]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(points.count * 2)
        for point in points {
            result.append(point.x)
            result.append(point.y)
        }
        return result
    }

    private static func points(from x: [Double], count: Int) -> [Vec2] {
        (0..<count).map { Vec2(x: x[$0 * 2], y: x[$0 * 2 + 1]) }
    }

    private static func segmentLengths(_ points: [Vec2], isClosed: Bool) -> [Double] {
        var lengths: [Double] = []
        let chain = FFSketchPolyline(vertices: points, isClosed: isClosed)
        for index in 0..<chain.segmentCount {
            guard let ends = chain.endpoints(ofSegment: index) else { break }
            lengths.append(points[ends.start].distance(to: points[ends.end]))
        }
        return lengths
    }

    private static func merit(_ residuals: [Double]) -> Double {
        residuals.reduce(0) { $0 + $1 * $1 }
    }

    /// Gaussian elimination with partial pivoting on the normal equations.
    private static func solveLinear(_ matrix: [[Double]], rhs: [Double]) -> [Double]? {
        let n = rhs.count
        guard matrix.count == n else { return nil }
        var augmented = matrix
        for index in 0..<n { augmented[index].append(rhs[index]) }
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(augmented[row][column]) > abs(augmented[pivot][column]) {
                pivot = row
            }
            guard abs(augmented[pivot][column]) > 1e-300 else { return nil }
            if pivot != column { augmented.swapAt(pivot, column) }
            let value = augmented[column][column]
            for index in column...(n) { augmented[column][index] /= value }
            for row in 0..<n where row != column {
                let factor = augmented[row][column]
                guard factor != 0 else { continue }
                for index in column...(n) {
                    augmented[row][index] -= factor * augmented[column][index]
                }
            }
        }
        return (0..<n).map { augmented[$0][n] }
    }

    /// The sketch's remaining shape freedom, as a dimension.
    ///
    /// The independent rows are found by Gram-Schmidt on unit rows; rows have
    /// different units, so each is normalised before the dependency test, and a
    /// row is dependent when its component outside the span so far is below
    /// `1e-9` relative to its own length.
    ///
    /// Three is then subtracted for the gauge. The constraints cannot see a
    /// translation (two dimensions) or a uniform scale (one), so those three are
    /// always in the null space and a naive `variables - rank` would report a
    /// rigid square as having three freedoms. The premise is the same one the
    /// solver relies on: every Phase 51 constraint is translation- and
    /// scale-invariant. A constraint that pinned an absolute position would
    /// break this count as well as the gauge.
    private static func degreesOfFreedom(_ rows: [[Term]], variables: Int) -> Int {
        var basis: [[Double]] = []
        for row in rows {
            var vector = [Double](repeating: 0, count: variables)
            for term in row { vector[term.variable] += term.value }
            let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard length > 1e-300 else { continue }
            vector = vector.map { $0 / length }
            for axis in basis {
                var projection = 0.0
                for index in 0..<variables {
                    projection += vector[index] * axis[index]
                }
                for index in 0..<variables {
                    vector[index] -= projection * axis[index]
                }
            }
            let remainder = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if remainder > 1e-9 {
                basis.append(vector.map { $0 / remainder })
            }
        }
        return max(0, variables - 3 - basis.count)
    }
}
