import Foundation

// MARK: - System model

/// One straight span of a sketch system: two point indices, nothing else.
///
/// A chain's shared vertices are represented by the two spans naming the same
/// point, which is what makes a coincidence explicit where Phase 51's polyline
/// implied it. That implication is the reason Phase 51's solver could only
/// constrain neighbouring spans of one connected chain.
struct FFSketchSpan: Equatable, Sendable {
    var start: Int
    var end: Int

    init(_ start: Int, _ end: Int) {
        self.start = start
        self.end = end
    }

    var label: String { "\(start + 1)-\(end + 1)" }
}

/// A place a constraint can act on.
///
/// A circle's centre is a first-class anchor because that is what a concentric
/// constraint and a centre-to-point dimension refer to. Phase 51 had no such
/// reference: its variables were a polyline's vertices and nothing else, so a
/// radius or a concentric constraint had no operand to name.
enum FFSketchAnchor: Equatable, Sendable {
    case point(Int)
    case circleCentre(Int)

    /// The index this anchor names, in its own kind's list.
    var index: Int {
        switch self {
        case .point(let index), .circleCentre(let index):
            return index
        }
    }

    /// Whether this anchor is a circle's centre rather than a point.
    var isCentre: Bool {
        if case .circleCentre = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .point(let index): return "point \(index + 1)"
        case .circleCentre(let index): return "circle \(index + 1)'s centre"
        }
    }
}

/// A circle as the system sees it: a centre and a radius.
///
/// The document stores a circle as a `FFCurvePrimitive` plus four exact
/// rational quadratic quarter spans. The solver keeps the two numbers and never
/// the four control points, so moving a circle cannot quietly stop it being
/// circular; the payload is regenerated from these numbers when the solution is
/// written back.
struct FFSketchCircle: Equatable, Sendable {
    var centre: Vec2
    var radius: Double

    init(centre: Vec2, radius: Double) {
        self.centre = centre
        self.radius = radius
    }
}

/// A 2-D sketch as independent geometry: points, straight spans and circles.
///
/// The variable layout is fixed and public so a caller can reason about it:
/// point `i` owns variables `2i` and `2i + 1`, circle `j` owns a three-variable
/// block after every point (centre x, centre y, radius).
struct FFSketchSystem: Equatable, Sendable {
    var points: [Vec2]
    var segments: [FFSketchSpan]
    var circles: [FFSketchCircle]

    init(
        points: [Vec2] = [],
        segments: [FFSketchSpan] = [],
        circles: [FFSketchCircle] = []
    ) {
        self.points = points
        self.segments = segments
        self.circles = circles
    }

    var variableCount: Int { points.count * 2 + circles.count * 3 }

    /// The number of positioned entities the gauge can translate.
    var entityCount: Int { points.count + circles.count }

    func circleVariable(_ index: Int) -> Int { points.count * 2 + index * 3 }

    func anchorVariables(_ anchor: FFSketchAnchor) -> (x: Int, y: Int)? {
        switch anchor {
        case .point(let index):
            guard index >= 0, index < points.count else { return nil }
            return (index * 2, index * 2 + 1)
        case .circleCentre(let index):
            guard index >= 0, index < circles.count else { return nil }
            let base = circleVariable(index)
            return (base, base + 1)
        }
    }

    func anchorPosition(_ anchor: FFSketchAnchor) -> Vec2? {
        switch anchor {
        case .point(let index):
            guard index >= 0, index < points.count else { return nil }
            return points[index]
        case .circleCentre(let index):
            guard index >= 0, index < circles.count else { return nil }
            return circles[index].centre
        }
    }

    func flattened() -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(variableCount)
        for point in points {
            result.append(point.x)
            result.append(point.y)
        }
        for circle in circles {
            result.append(circle.centre.x)
            result.append(circle.centre.y)
            result.append(circle.radius)
        }
        return result
    }

    func rebuilt(from x: [Double]) -> FFSketchSystem {
        var newPoints: [Vec2] = []
        newPoints.reserveCapacity(points.count)
        for index in 0..<points.count {
            newPoints.append(Vec2(x: x[index * 2], y: x[index * 2 + 1]))
        }
        var newCircles: [FFSketchCircle] = []
        newCircles.reserveCapacity(circles.count)
        for index in 0..<circles.count {
            let base = circleVariable(index)
            newCircles.append(FFSketchCircle(
                centre: Vec2(x: x[base], y: x[base + 1]),
                radius: x[base + 2]
            ))
        }
        return FFSketchSystem(points: newPoints, segments: segments, circles: newCircles)
    }

    /// The unit direction and length of one span in a variable vector.
    ///
    /// A zero-length span has no direction, so it is refused rather than given
    /// a made-up one: that refusal is what stops the solver from calling a
    /// collapsed sketch a solution.
    func direction(of segment: Int, in x: [Double]) throws -> (unit: Vec2, length: Double) {
        guard segment >= 0, segment < segments.count else {
            throw FFSketchConstraintError.segmentOutOfRange(segment)
        }
        let span = segments[segment]
        let dx = x[span.end * 2] - x[span.start * 2]
        let dy = x[span.end * 2 + 1] - x[span.start * 2 + 1]
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > FFSketchSystemSolver.minimumSegmentLength else {
            throw FFSketchConstraintError.degenerateSegment(segment)
        }
        return (Vec2(x: dx / length, y: dy / length), length)
    }

    // MARK: - Payload bridging

    /// Reads a Phase 39-51 sketch into the system model.
    ///
    /// A polyline becomes points plus spans, so a chain's shared vertex is one
    /// point named twice instead of two points constrained to meet.
    init(polyline: FFSketchPolyline) {
        self.init(
            points: polyline.vertices,
            segments: (0..<polyline.segmentCount).compactMap { index in
                polyline.endpoints(ofSegment: index).map { FFSketchSpan($0.start, $0.end) }
            }
        )
    }

    func polyline() -> FFSketchPolyline {
        FFSketchPolyline(vertices: points, isClosed: segments.count == points.count && points.count > 1)
    }

    /// Reads a circle primitive into the system model. The four quarter spans
    /// the document stores are regenerated from these two numbers on the way
    /// back, so the payload can never disagree with the primitive.
    init(circle primitive: FFCurvePrimitive) {
        self.init(circles: [
            FFSketchCircle(centre: primitive.center.vector, radius: primitive.radius)
        ])
    }
}

// MARK: - Solution

/// What the system solver did, in the terms a readout needs.
///
/// `conflicts` is empty exactly when every requested constraint holds. When it
/// is not, `system` still carries the shape the accepted prefix produced, so a
/// caller can preview the best effort without writing it.
struct FFSketchSystemSolution: Equatable, Sendable {
    var system: FFSketchSystem
    var iterations: Int
    var residual: Double
    var degreesOfFreedom: Int
    var applied: [FFSketchConstraint]
    var conflicts: [FFSketchConstraint]

    var isSatisfied: Bool { conflicts.isEmpty }
}

// MARK: - Solver

/// Phase 52's solver: damped Gauss-Newton over points, spans and circles, with
/// a gauge rebuilt around the constraint set it is given.
///
/// Phase 51's premise cannot be reused. Its four constraints were all
/// translation- and scale-invariant, so it could project every step back onto a
/// fixed centroid and a fixed RMS radius. `distance` and `radius` are length
/// dimensions: they decide the scale, and a scale projection would fight them.
/// So the gauge here is the symmetry group of the *set*: the two translations
/// always, the uniform scale exactly when no length dimension is present.
/// `equalLength` is not a length dimension (scaling a solution keeps it one),
/// which is why it does not switch the scale gauge off.
///
/// Every direction constraint is stated as a signed angle, not as a sine or
/// cosine of one. A cosine residual has a stationary maximum where two spans are
/// parallel, which is exactly where a drawn chain starts, so a solver crawls
/// there: a local model of this loop measured 15 and 20 iterations on chains
/// that the angle form solves in 5 to 9.
enum FFSketchSystemSolver {
    /// A constraint counts as satisfied below this, in its own unit
    /// (millimetres for lengths, radians for angles).
    static let residualTolerance = 1e-9

    /// Measured budget. A local model of this loop converged in 0 to 14
    /// iterations on its 47 fixtures, so the cap is 20: above the measured
    /// worst case and far inside the cost of the row's 40-fixture sweep.
    ///
    /// The long cases are 6-span chains whose early steps trade one residual
    /// against another (the sum of squares falls while the largest residual
    /// grows), then converge quadratically at the end. That is slow, not stuck:
    /// the same fixture reaches 2.6e-14 at iteration 14 and stays there.
    static let maximumIterations = 20

    static let damping = 1e-10

    /// A span or a circle smaller than this is not geometry. It is the backstop
    /// that stops the solver from calling a collapsed sketch a solution.
    static let minimumSegmentLength = 1e-6
    static let minimumRadius = 1e-6

    static let backtrackingSteps = 12

    static func solve(
        _ system: FFSketchSystem,
        constraints: [FFSketchConstraint]
    ) throws -> FFSketchSystemSolution {
        try validate(system, constraints: constraints)
        let variables = system.variableCount
        let hasLengthDimension = constraints.contains { $0.isLengthDimension }

        let full = attempt(system, constraints: constraints)
        guard full.isSatisfied else {
            // Incremental acceptance: the first constraint that cannot be added
            // to an already-solvable prefix is the one that over-constrains the
            // sketch, in the order the caller asked for them. It is a solver
            // verdict from this geometry, not a proof that no other branch of
            // the solution set exists.
            var applied: [FFSketchConstraint] = []
            var conflict: FFSketchConstraint?
            for constraint in constraints {
                let trial = attempt(system, constraints: applied + [constraint])
                if trial.isSatisfied {
                    applied.append(constraint)
                } else {
                    conflict = constraint
                    break
                }
            }
            guard !applied.isEmpty else {
                return FFSketchSystemSolution(
                    system: system,
                    iterations: 0,
                    residual: 0,
                    degreesOfFreedom: max(0, variables - gaugeDimension(hasLengthDimension)),
                    applied: [],
                    conflicts: conflict.map { [$0] } ?? []
                )
            }
            let accepted = attempt(system, constraints: applied)
            return FFSketchSystemSolution(
                system: accepted.system,
                iterations: accepted.iterations,
                residual: accepted.residual,
                degreesOfFreedom: degreesOfFreedom(
                    accepted.rows,
                    variables: variables,
                    hasLengthDimension: hasLengthDimension
                ),
                applied: applied,
                conflicts: conflict.map { [$0] } ?? []
            )
        }
        return FFSketchSystemSolution(
            system: full.system,
            iterations: full.iterations,
            residual: full.residual,
            degreesOfFreedom: degreesOfFreedom(
                full.rows,
                variables: variables,
                hasLengthDimension: hasLengthDimension
            ),
            applied: constraints,
            conflicts: []
        )
    }

    // MARK: - Structure

    private static func validate(
        _ system: FFSketchSystem,
        constraints: [FFSketchConstraint]
    ) throws {
        guard !constraints.isEmpty else { throw FFSketchConstraintError.noConstraints }
        guard system.entityCount > 0 else {
            throw FFSketchConstraintError.systemHasNoGeometry
        }
        for segment in system.segments {
            for endpoint in [segment.start, segment.end]
            where endpoint < 0 || endpoint >= system.points.count {
                throw FFSketchConstraintError.pointOutOfRange(endpoint < 0 ? 0 : endpoint)
            }
        }
        for constraint in constraints {
            try validate(system, constraint: constraint)
        }
    }

    private static func validate(
        _ system: FFSketchSystem,
        constraint: FFSketchConstraint
    ) throws {
        switch constraint {
        case .coincident(let first, let second):
            try check(system, anchor: first)
            try check(system, anchor: second)
            guard first != second else {
                throw FFSketchConstraintError.anchorRepeatsItself(first.label)
            }
        case .distance(let first, let second, let value):
            try check(system, anchor: first)
            try check(system, anchor: second)
            guard first != second else {
                throw FFSketchConstraintError.anchorRepeatsItself(first.label)
            }
            guard value.isFinite, value > 0 else {
                throw FFSketchConstraintError.nonPositiveDimension("A distance")
            }
        case .radius(let index, let value):
            guard index >= 0, index < system.circles.count else {
                throw FFSketchConstraintError.circleOutOfRange(index)
            }
            guard value.isFinite, value > 0 else {
                throw FFSketchConstraintError.nonPositiveDimension("A radius")
            }
        case .perpendicular(let first, let second),
             .parallel(let first, let second),
             .concentric(let first, let second):
            if case .concentric = constraint {
                for index in [first, second] where index < 0 || index >= system.circles.count {
                    throw FFSketchConstraintError.circleOutOfRange(index)
                }
            } else {
                for index in [first, second] where index < 0 || index >= system.segments.count {
                    throw FFSketchConstraintError.segmentOutOfRange(index)
                }
            }
            guard first != second else {
                throw FFSketchConstraintError.segmentRepeatsItself(constraint.label)
            }
        case .angle(let first, let second, let degrees):
            for index in [first, second] where index < 0 || index >= system.segments.count {
                throw FFSketchConstraintError.segmentOutOfRange(index)
            }
            guard first != second else {
                throw FFSketchConstraintError.segmentRepeatsItself(constraint.label)
            }
            guard degrees.isFinite, abs(degrees) > 0, abs(degrees) < 360 else {
                throw FFSketchConstraintError.angleOutOfRange(degrees.isFinite ? degrees : 0)
            }
        case .horizontal(let segment), .vertical(let segment):
            guard segment >= 0, segment < system.segments.count else {
                throw FFSketchConstraintError.segmentOutOfRange(segment)
            }
        case .equalLength(let first, let second):
            for index in [first, second] where index < 0 || index >= system.segments.count {
                throw FFSketchConstraintError.segmentOutOfRange(index)
            }
            guard first != second else {
                throw FFSketchConstraintError.segmentRepeatsItself(constraint.label)
            }
        case .tangent(let first, let second):
            for index in [first, second] where index < 0 || index >= system.segments.count {
                throw FFSketchConstraintError.segmentOutOfRange(index)
            }
            guard first != second else {
                throw FFSketchConstraintError.segmentRepeatsItself(constraint.label)
            }
            guard system.segments[first].end == system.segments[second].start else {
                throw FFSketchConstraintError.tangentNeedsNeighbour(first, second)
            }
        }
    }

    private static func check(_ system: FFSketchSystem, anchor: FFSketchAnchor) throws {
        guard system.anchorVariables(anchor) != nil else {
            throw FFSketchConstraintError.anchorOutOfRange(anchor.label)
        }
    }

    // MARK: - One attempt

    private struct Term {
        var variable: Int
        var value: Double
    }

    private struct Row {
        var residual: Double
        var terms: [Term]
    }

    /// How a pair of directions is compared.
    private enum AngleMode {
        /// Signed, with a half turn kept distinct (tangency).
        case directed(Double)
        /// Signed and folded onto `(-90, +90]` (parallel, perpendicular).
        case folded(Double)
        /// The angle the two lines meet at, `0...90`, sign-free.
        case lineAngle(Double)
    }

    private struct Attempt {
        var system: FFSketchSystem
        var iterations: Int
        var residual: Double
        var rows: [Row]
        var isSatisfied: Bool
    }

    private static func attempt(
        _ system: FFSketchSystem,
        constraints: [FFSketchConstraint]
    ) -> Attempt {
        let hasLengthDimension = constraints.contains { $0.isLengthDimension }
        let variables = system.variableCount

        var x: [Double]
        let centre: Vec2
        let metric: Double
        do {
            let gauge = try gauge(of: system)
            centre = gauge.centre
            metric = gauge.metric
            x = try projected(
                system.flattened(),
                system: system,
                centre: centre,
                metric: metric,
                fixesScale: !hasLengthDimension
            )
        } catch {
            return Attempt(
                system: system,
                iterations: 0,
                residual: .infinity,
                rows: [],
                isSatisfied: false
            )
        }

        var iterations = 0
        var residual = Double.infinity
        var rows: [Row] = []
        var collapsed = false

        while true {
            guard let evaluation = try? evaluate(system, x: x, constraints: constraints) else {
                collapsed = true
                break
            }
            rows = evaluation
            var worst = 0.0
            for row in rows { worst = max(worst, abs(row.residual)) }
            residual = worst
            if worst <= residualTolerance || iterations >= maximumIterations { break }

            var matrix = [[Double]](
                repeating: [Double](repeating: 0, count: variables),
                count: variables
            )
            var gradient = [Double](repeating: 0, count: variables)
            for row in rows {
                for term in row.terms {
                    gradient[term.variable] += term.value * row.residual
                }
                for first in row.terms {
                    for second in row.terms {
                        matrix[first.variable][second.variable] += first.value * second.value
                    }
                }
            }
            for index in 0..<variables { matrix[index][index] += damping }
            guard let step = FFSketchConstraintSolver.solveLinear(
                matrix,
                rhs: gradient.map { -$0 }
            ) else { break }

            var meritBefore = 0.0
            for row in rows { meritBefore += row.residual * row.residual }

            var scale = 1.0
            var accepted = false
            for _ in 0..<backtrackingSteps {
                var stepped = x
                for index in 0..<variables {
                    stepped[index] += scale * step[index]
                }
                guard let trial = try? projected(
                    stepped,
                    system: system,
                    centre: centre,
                    metric: metric,
                    fixesScale: !hasLengthDimension
                ) else { break }
                if let trialRows = try? evaluate(system, x: trial, constraints: constraints) {
                    var merit = 0.0
                    for row in trialRows { merit += row.residual * row.residual }
                    if merit <= meritBefore {
                        x = trial
                        accepted = true
                        break
                    }
                }
                scale *= 0.5
            }
            if !accepted { break }
            iterations += 1
            var largest: Double = 0
            for value in step { largest = max(largest, abs(scale * value)) }
            if largest <= 1e-13 { break }
        }

        let solved = system.rebuilt(from: x)
        var valid = !collapsed
        for segment in 0..<solved.segments.count {
            let span = solved.segments[segment]
            let length = solved.points[span.start].distance(to: solved.points[span.end])
            if !(length >= minimumSegmentLength) { valid = false }
        }
        for circle in solved.circles {
            if !(circle.radius.isFinite && circle.radius >= minimumRadius) { valid = false }
        }
        return Attempt(
            system: solved,
            iterations: iterations,
            residual: residual,
            rows: rows,
            isSatisfied: residual <= residualTolerance && valid
        )
    }

    // MARK: - Residuals

    private static func evaluate(
        _ system: FFSketchSystem,
        x: [Double],
        constraints: [FFSketchConstraint]
    ) throws -> [Row] {
        var rows: [Row] = []

        func requireAnchor(_ anchor: FFSketchAnchor) throws -> (x: Int, y: Int) {
            guard let variables = system.anchorVariables(anchor) else {
                throw FFSketchConstraintError.anchorOutOfRange(anchor.label)
            }
            return variables
        }

        func direction(_ segment: Int) throws -> (unit: Vec2, length: Double) {
            try system.direction(of: segment, in: x)
        }

        /// The derivative of a residual that lives on a span's unit direction,
        /// expanded to the span's two endpoints.
        func directionTerms(
            _ segment: Int,
            _ gradient: Vec2
        ) throws -> [Term] {
            let span = system.segments[segment]
            let state = try direction(segment)
            let u = state.unit
            let cross = Vec2(
                x: (1 - u.x * u.x) * gradient.x - u.x * u.y * gradient.y,
                y: -u.x * u.y * gradient.x + (1 - u.y * u.y) * gradient.y
            )
            let scaled = cross / state.length
            return [
                Term(variable: span.start * 2, value: -scaled.x),
                Term(variable: span.start * 2 + 1, value: -scaled.y),
                Term(variable: span.end * 2, value: scaled.x),
                Term(variable: span.end * 2 + 1, value: scaled.y),
            ]
        }

        /// The derivative of a residual that lives on the span's chord itself
        /// (its length or one component of it), expanded to the endpoints.
        func vectorTerms(_ segment: Int, _ gradient: Vec2) -> [Term] {
            let span = system.segments[segment]
            return [
                Term(variable: span.start * 2, value: -gradient.x),
                Term(variable: span.start * 2 + 1, value: -gradient.y),
                Term(variable: span.end * 2, value: gradient.x),
                Term(variable: span.end * 2 + 1, value: gradient.y),
            ]
        }

        /// A row for one of the four direction relations, in radians.
        ///
        /// `r` is the angle *from* u *to* v, so rotating u by +e lowers r by e
        /// and rotating v by +e raises it: dr/du = -perp(u), dr/dv = +perp(v).
        /// Each mode only rescales that derivative by a piecewise-constant sign,
        /// which is why one expansion serves all four.
        func directionPairRow(
            _ first: Int,
            _ second: Int,
            mode: AngleMode
        ) throws -> Row {
            let u = try direction(first).unit
            let v = try direction(second).unit
            let sine = u.cross(v)
            let cosine = u.dot(v)
            let angle = atan2(sine, cosine)

            var residual: Double
            var sign = 1.0
            switch mode {
            case .directed(let target):
                // A half turn is a distinct state, not an equivalent one.
                residual = wrapAngle(angle - target)
            case .folded(let target):
                residual = foldAngle(wrapAngle(angle - target))
            case .lineAngle(let target):
                // Undirected in the line sense: a signed turn of +60 and of
                // -60 put the two lines at the same 60 degrees, and a typed 120
                // is the same relation as 60. Fold first, then compare the
                // magnitude, which is the angle the two lines actually meet at.
                let folded = foldAngle(wrapAngle(angle))
                let lineTarget = target > Double.pi / 2 ? Double.pi - target : target
                residual = abs(folded) - lineTarget
                sign = folded < 0 ? -1 : 1
            }

            let toStart = Vec2(x: sign * u.y, y: -sign * u.x)
            let toEnd = Vec2(x: -sign * v.y, y: sign * v.x)
            var terms = try directionTerms(first, toStart)
            terms.append(contentsOf: try directionTerms(second, toEnd))
            return Row(residual: residual, terms: terms)
        }

        for constraint in constraints {
            switch constraint {
            case .coincident(let first, let second):
                let a = try requireAnchor(first)
                let b = try requireAnchor(second)
                rows.append(Row(
                    residual: x[a.x] - x[b.x],
                    terms: [Term(variable: a.x, value: 1), Term(variable: b.x, value: -1)]
                ))
                rows.append(Row(
                    residual: x[a.y] - x[b.y],
                    terms: [Term(variable: a.y, value: 1), Term(variable: b.y, value: -1)]
                ))
            case .distance(let first, let second, let value):
                let a = try requireAnchor(first)
                let b = try requireAnchor(second)
                let dx = x[a.x] - x[b.x]
                let dy = x[a.y] - x[b.y]
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > minimumSegmentLength else {
                    throw FFSketchConstraintError.anchorRepeatsItself("Those two anchors")
                }
                let ux = dx / length
                let uy = dy / length
                rows.append(Row(
                    residual: length - value,
                    terms: [
                        Term(variable: a.x, value: ux),
                        Term(variable: a.y, value: uy),
                        Term(variable: b.x, value: -ux),
                        Term(variable: b.y, value: -uy),
                    ]
                ))
            case .radius(let index, let value):
                guard index >= 0, index < system.circles.count else {
                    throw FFSketchConstraintError.circleOutOfRange(index)
                }
                let base = system.circleVariable(index)
                rows.append(Row(
                    residual: x[base + 2] - value,
                    terms: [Term(variable: base + 2, value: 1)]
                ))
            case .concentric(let first, let second):
                let a = system.circleVariable(first)
                let b = system.circleVariable(second)
                rows.append(Row(
                    residual: x[a] - x[b],
                    terms: [Term(variable: a, value: 1), Term(variable: b, value: -1)]
                ))
                rows.append(Row(
                    residual: x[a + 1] - x[b + 1],
                    terms: [Term(variable: a + 1, value: 1), Term(variable: b + 1, value: -1)]
                ))
            case .perpendicular(let first, let second):
                rows.append(try directionPairRow(first, second, mode: .folded(.pi / 2)))
            case .parallel(let first, let second):
                rows.append(try directionPairRow(first, second, mode: .folded(0)))
            case .angle(let first, let second, let degrees):
                let radians = degrees * Double.pi / 180
                rows.append(try directionPairRow(first, second, mode: .lineAngle(radians)))
            case .tangent(let first, let second):
                // Directed: a half turn is a fold, not a tangent, so this one
                // is neither folded nor reduced to a line angle.
                rows.append(try directionPairRow(first, second, mode: .directed(0)))
            case .horizontal(let segment), .vertical(let segment):
                let u = try direction(segment).unit
                let target = constraint.isHorizontal ? 0.0 : Double.pi / 2
                var residual = atan2(u.y, u.x) - target
                residual = foldAngle(wrapAngle(residual))
                rows.append(Row(
                    residual: residual,
                    terms: try directionTerms(segment, Vec2(x: -u.y, y: u.x))
                ))
            case .equalLength(let first, let second):
                let a = try direction(first)
                let b = try direction(second)
                var terms = vectorTerms(first, a.unit)
                terms.append(contentsOf: vectorTerms(second, Vec2(x: -b.unit.x, y: -b.unit.y)))
                rows.append(Row(residual: a.length - b.length, terms: terms))
            }
        }
        return rows
    }

    // MARK: - Diagnostics

    /// One dense row per residual: its value and its analytic gradient.
    ///
    /// The solver reads sparse terms; this is the same evaluation widened so a
    /// test (or a future residual readout) can compare the analytic Jacobian
    /// against central differences of the residuals themselves. It is not used
    /// on the solve path.
    static func residualRows(
        _ system: FFSketchSystem,
        constraints: [FFSketchConstraint]
    ) throws -> [(residual: Double, gradient: [Double])] {
        let rows = try evaluate(system, x: system.flattened(), constraints: constraints)
        let variables = system.variableCount
        return rows.map { row in
            var gradient = [Double](repeating: 0, count: variables)
            for term in row.terms { gradient[term.variable] += term.value }
            return (row.residual, gradient)
        }
    }

    // MARK: - Angle helpers

    /// Brings an angle into `(-pi, pi]`.
    static func wrapAngle(_ angle: Double) -> Double {
        guard angle.isFinite else { return angle }
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value <= -Double.pi { value += 2 * .pi }
        return value
    }

    /// Brings an angle into `(-pi/2, pi/2]`.
    ///
    /// Parallel and perpendicular are *undirected* relations: a span pointing
    /// one way and one pointing the other way are still parallel, and an angle
    /// of +90 and -90 are the same right angle. Folding removes that sign
    /// ambiguity, and it also removes the stationary point a sine residual has
    /// at the antipode.
    static func foldAngle(_ angle: Double) -> Double {
        guard angle.isFinite else { return angle }
        var value = angle
        while value > .pi / 2 { value -= .pi }
        while value <= -Double.pi / 2 { value += .pi }
        return value
    }

    // MARK: - Gauge

    /// The centroid and RMS size of every positioned entity.
    ///
    /// A circle contributes its radius to the size metric as well as its
    /// centre, so scaling a circle uniformly scales its whole contribution and
    /// the metric is homogeneous of degree one in the scale factor.
    private static func gauge(of system: FFSketchSystem) throws -> (centre: Vec2, metric: Double) {
        let count = system.entityCount
        guard count > 0 else { throw FFSketchConstraintError.systemHasNoGeometry }
        var sum = Vec2.zero
        for point in system.points { sum = sum + point }
        for circle in system.circles { sum = sum + circle.centre }
        let centre = sum / Double(count)
        var moment = 0.0
        for point in system.points { moment += (point - centre).lengthSquared }
        for circle in system.circles {
            moment += (circle.centre - centre).lengthSquared
            moment += circle.radius * circle.radius
        }
        let metric = (moment / Double(count)).squareRoot()
        guard metric.isFinite, metric > minimumSegmentLength else {
            throw FFSketchConstraintError.coincidentSketch
        }
        return (centre, metric)
    }

    /// Applies the gauge: translation always, uniform scale only when the
    /// constraint set has no length dimension.
    ///
    /// Neither projection changes any residual: every constraint here is
    /// translation-invariant, and when the scale projection runs the set has no
    /// length dimension, so every residual is scale-invariant too.
    private static func projected(
        _ x: [Double],
        system: FFSketchSystem,
        centre: Vec2,
        metric: Double,
        fixesScale: Bool
    ) throws -> [Double] {
        let count = system.entityCount
        guard count > 0 else { return x }
        var result = x
        var sum = Vec2.zero
        for index in 0..<system.points.count {
            sum = sum + Vec2(x: result[index * 2], y: result[index * 2 + 1])
        }
        for index in 0..<system.circles.count {
            let base = system.circleVariable(index)
            sum = sum + Vec2(x: result[base], y: result[base + 1])
        }
        let current = sum / Double(count)
        let shift = current - centre
        for index in 0..<system.points.count {
            result[index * 2] -= shift.x
            result[index * 2 + 1] -= shift.y
        }
        for index in 0..<system.circles.count {
            let base = system.circleVariable(index)
            result[base] -= shift.x
            result[base + 1] -= shift.y
        }

        guard fixesScale else { return result }

        var moment = 0.0
        for index in 0..<system.points.count {
            let px = result[index * 2] - centre.x
            let py = result[index * 2 + 1] - centre.y
            moment += px * px + py * py
        }
        for index in 0..<system.circles.count {
            let base = system.circleVariable(index)
            let px = result[base] - centre.x
            let py = result[base + 1] - centre.y
            moment += px * px + py * py
            moment += result[base + 2] * result[base + 2]
        }
        let currentMetric = (moment / Double(count)).squareRoot()
        guard currentMetric.isFinite, currentMetric > 1e-12 else {
            throw FFSketchConstraintError.coincidentSketch
        }
        let scale = metric / currentMetric
        for index in 0..<system.points.count {
            result[index * 2] = centre.x + (result[index * 2] - centre.x) * scale
            result[index * 2 + 1] = centre.y + (result[index * 2 + 1] - centre.y) * scale
        }
        for index in 0..<system.circles.count {
            let base = system.circleVariable(index)
            result[base] = centre.x + (result[base] - centre.x) * scale
            result[base + 1] = centre.y + (result[base + 1] - centre.y) * scale
            result[base + 2] *= scale
        }
        return result
    }

    /// How many degrees of freedom the gauge removes.
    ///
    /// Two translations always. The uniform scale only while it is a symmetry of
    /// the set, which is exactly while the set carries no length dimension.
    private static func gaugeDimension(_ hasLengthDimension: Bool) -> Int {
        hasLengthDimension ? 2 : 3
    }

    private static func degreesOfFreedom(
        _ rows: [Row],
        variables: Int,
        hasLengthDimension: Bool
    ) -> Int {
        var basis: [[Double]] = []
        for row in rows {
            var vector = [Double](repeating: 0, count: variables)
            for term in row.terms { vector[term.variable] += term.value }
            var length = 0.0
            for value in vector { length += value * value }
            length = length.squareRoot()
            guard length > 1e-300 else { continue }
            for index in 0..<variables { vector[index] /= length }
            for axis in basis {
                var projection = 0.0
                for index in 0..<variables { projection += vector[index] * axis[index] }
                for index in 0..<variables { vector[index] -= projection * axis[index] }
            }
            var remainder = 0.0
            for value in vector { remainder += value * value }
            remainder = remainder.squareRoot()
            if remainder > 1e-9 {
                for index in 0..<variables { vector[index] /= remainder }
                basis.append(vector)
            }
        }
        return max(0, variables - gaugeDimension(hasLengthDimension) - basis.count)
    }
}

extension FFSketchConstraint {
    /// Whether this constraint fixes the sketch's scale.
    ///
    /// Distance and radius are length dimensions: scaling the sketch changes the
    /// number they compare against. Everything else — including equal length,
    /// which compares two lengths — is homogeneous, so scaling a solution keeps
    /// it a solution and the uniform scale is still a symmetry.
    var isLengthDimension: Bool {
        switch self {
        case .distance, .radius: return true
        default: return false
        }
    }

    var isHorizontal: Bool {
        if case .horizontal = self { return true }
        return false
    }
}
