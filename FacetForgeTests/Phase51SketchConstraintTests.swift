import Foundation
import XCTest
@testable import FacetForge

/// Phase 51's acceptance: a constraint set reshapes a sketch and is removed by
/// one undo, and a set that cannot hold is refused with the offending
/// constraint named rather than with a broken sketch.
///
/// Every expected number here is computed by this file from the fixture's raw
/// coordinates, not read back from the solver:
///
/// - A square whose own RMS radius is `R` has side `R * sqrt(2)` and half
///   diagonal `R`, so the side a converged square must reach is fixed by the
///   fixture's corner coordinates and the solver's scale-preserving gauge, which
///   this file recomputes with `rmsRadius`.
/// - Tangency is the signed turn `atan2(u x v, u . v) = 0`, recomputed from the
///   solved vertices, with `u . v > 0` so a half-turn fold is never accepted.
/// - A horizontal span is `y(end) - y(start) = 0`, again recomputed.
///
/// Tolerances are matched to the producing method. A local model of this exact
/// loop measured residuals of 5.6e-17 to 7.8e-10 and at most 4 iterations on
/// these fixtures and on 24 generated chains, so a converged geometry is
/// asserted at 1e-9 and the iteration budget at the solver's own 9. The square's
/// side is asserted at 1e-9 as well: the model measured it at 1.8e-15 against
/// the bound this file derives, because the gauge preserves the total squared
/// radius at every iterate, so the side is not merely close to `R sqrt(2)` — it
/// is determined by it.
final class Phase51SketchConstraintTests: XCTestCase {
    // MARK: - Fixtures

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    private func line(_ start: Vec2, _ end: Vec2) -> FFCurveSegment {
        FFCurveSegment(
            kind: .bezier,
            controlPoints: [FFPoint2(start), FFPoint2(end)]
        )
    }

    /// Builds a payload whose spans are exactly the ones the sketch tool writes:
    /// a two-point Bézier per span, no weights, no knots.
    private func polyline(_ points: [Vec2], isClosed: Bool = false) -> FFCurvePayload {
        var segments: [FFCurveSegment] = []
        for index in 1..<points.count {
            segments.append(line(points[index - 1], points[index]))
        }
        if isClosed {
            segments.append(line(points[points.count - 1], points[0]))
        }
        return FFCurvePayload(segments: segments, isClosed: isClosed)
    }

    private func solve(
        _ points: [Vec2],
        isClosed: Bool = false,
        _ constraints: [FFSketchConstraint]
    ) throws -> FFSketchConstraintSolution {
        let chain = FFSketchPolyline(vertices: points, isClosed: isClosed)
        return try FFSketchConstraintSolver.solve(chain, constraints: constraints)
    }

    /// The fixture's own RMS radius: `sqrt(sum of squared distances / n)`.
    /// This is the quantity the solver's gauge preserves, so a test can predict
    /// the size of the converged shape from the drawn points alone.
    private func rmsRadius(_ points: [Vec2]) -> Double {
        let centre = points.reduce(Vec2.zero) { $0 + $1 } / Double(points.count)
        let moment = points.reduce(0.0) { $0 + ($1 - centre).lengthSquared }
        return (moment / Double(points.count)).squareRoot()
    }

    private func centroid(_ points: [Vec2]) -> Vec2 {
        points.reduce(Vec2.zero) { $0 + $1 } / Double(points.count)
    }

    private func sideLengths(_ polyline: FFSketchPolyline) -> [Double] {
        (0..<polyline.segmentCount).compactMap { index in
            guard let ends = polyline.endpoints(ofSegment: index) else { return nil }
            return polyline.vertices[ends.start].distance(to: polyline.vertices[ends.end])
        }
    }

    /// The signed turn angle in radians at the joint a tangent acts on, measured
    /// from the solved vertices alone.
    private func turnAngle(
        _ polyline: FFSketchPolyline,
        first a: Int,
        joint b: Int,
        tail c: Int
    ) -> Double {
        guard let u = (polyline.vertices[b] - polyline.vertices[a]).normalized(),
              let v = (polyline.vertices[c] - polyline.vertices[b]).normalized()
        else { return .infinity }
        return atan2(u.cross(v), u.dot(v))
    }

    /// The cosine of that turn. `1` means the second span continues the first,
    /// `-1` means it doubles back over it.
    private func turnCosine(
        _ polyline: FFSketchPolyline,
        first a: Int,
        joint b: Int,
        tail c: Int
    ) -> Double {
        guard let u = (polyline.vertices[b] - polyline.vertices[a]).normalized(),
              let v = (polyline.vertices[c] - polyline.vertices[b]).normalized()
        else { return -1 }
        return u.dot(v)
    }

    /// The rectangle the model measured, drawn four millimetres off square.
    private var offSquareRectangle: [Vec2] {
        [point(0, 0), point(10, 2), point(12, 10), point(1, 8)]
    }

    // MARK: - Convergence to the fixture's own geometry

    func testAnOffSquareRectangleComesOutASquare() throws {
        let fixture = offSquareRectangle
        // Five rows plus the equal sides: four right angles and two equalities
        // make the closed rectangle a square.
        let solution = try solve(
            fixture,
            isClosed: true,
            [
                .horizontal(segment: 0),
                .horizontal(segment: 2),
                .vertical(segment: 1),
                .vertical(segment: 3),
                .equalLength(first: 0, second: 1),
                .equalLength(first: 1, second: 2),
            ]
        )

        XCTAssertTrue(solution.isSatisfied, "\(solution.conflicts)")
        XCTAssertLessThanOrEqual(solution.residual, 1e-9)
        XCTAssertLessThanOrEqual(solution.iterations, 9)
        // A square is rigid.
        XCTAssertEqual(solution.degreesOfFreedom, 0)

        let sides = sideLengths(solution.polyline)
        XCTAssertEqual(sides.count, 4)
        // Bound derived by this file: the gauge preserves the fixture's RMS
        // radius R, and a square with RMS radius R has side R * sqrt(2).
        let expected = rmsRadius(fixture) * Double(2).squareRoot()
        for side in sides {
            XCTAssertEqual(side, expected, accuracy: 1e-9)
        }
        for index in 1..<sides.count {
            XCTAssertEqual(sides[index], sides[0], accuracy: 1e-9)
        }
        XCTAssertEqual(solution.polyline.vertices.count, 4)
    }

    func testTheSolvedShapeKeepsTheFixturesCentreAndScale() throws {
        let fixture = offSquareRectangle
        let solution = try solve(
            fixture,
            isClosed: true,
            [
                .horizontal(segment: 0),
                .horizontal(segment: 2),
                .vertical(segment: 1),
                .vertical(segment: 3),
            ]
        )
        XCTAssertTrue(solution.isSatisfied)
        let before = centroid(fixture)
        let after = centroid(solution.polyline.vertices)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-9)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-9)
        XCTAssertEqual(rmsRadius(solution.polyline.vertices), rmsRadius(fixture), accuracy: 1e-9)
    }

    func testARectangleKeepsOneShapeFreedom() throws {
        let solution = try solve(
            offSquareRectangle,
            isClosed: true,
            [
                .horizontal(segment: 0),
                .horizontal(segment: 2),
                .vertical(segment: 1),
                .vertical(segment: 3),
            ]
        )
        XCTAssertTrue(solution.isSatisfied)
        // Width and height are free; the gauge fixes their common scale, which
        // leaves the ratio.
        XCTAssertEqual(solution.degreesOfFreedom, 1)

        for index in [0, 2] {
            guard let ends = solution.polyline.endpoints(ofSegment: index) else {
                return XCTFail("missing segment \(index)")
            }
            XCTAssertEqual(
                solution.polyline.vertices[ends.end].y,
                solution.polyline.vertices[ends.start].y,
                accuracy: 1e-9
            )
        }
        for index in [1, 3] {
            guard let ends = solution.polyline.endpoints(ofSegment: index) else {
                return XCTFail("missing segment \(index)")
            }
            XCTAssertEqual(
                solution.polyline.vertices[ends.end].x,
                solution.polyline.vertices[ends.start].x,
                accuracy: 1e-9
            )
        }
    }

    func testTangentStraightensTheJointAndKeepsItGoingForward() throws {
        let solution = try solve(
            [point(0, 0), point(10, 0), point(13, 4)],
            [.tangent(first: 0, second: 1)]
        )
        XCTAssertTrue(solution.isSatisfied)
        XCTAssertLessThanOrEqual(solution.residual, 1e-9)
        XCTAssertLessThanOrEqual(solution.iterations, 9)
        XCTAssertEqual(solution.degreesOfFreedom, 2)

        let angle = turnAngle(solution.polyline, first: 0, joint: 1, tail: 2)
        XCTAssertLessThanOrEqual(abs(angle), 1e-9)
        // Continuing, not folding back. A half turn also zeroes the sine of the
        // turn, which is why the solver's residual is the angle itself.
        XCTAssertGreaterThan(turnCosine(solution.polyline, first: 0, joint: 1, tail: 2), 0.9)
        // The three points stay distinct: a tangent must not solve by collapse.
        XCTAssertGreaterThan(sideLengths(solution.polyline).min() ?? 0, 1e-6)
    }

    func testAFoldedStartStraightensInsteadOfStayingFolded() throws {
        // The second span starts pointing back over the first. The constraint is
        // the same zero turn, so the only answers are a continuation (the angle
        // reaches zero) or a refusal; a half turn is not an answer.
        let solution = try solve(
            [point(0, 0), point(10, 0), point(-6, 0.5)],
            [.tangent(first: 0, second: 1)]
        )
        XCTAssertTrue(solution.isSatisfied, "\(solution.conflicts)")
        XCTAssertLessThanOrEqual(abs(turnAngle(solution.polyline, first: 0, joint: 1, tail: 2)), 1e-9)
        XCTAssertGreaterThan(turnCosine(solution.polyline, first: 0, joint: 1, tail: 2), 0.9)
    }

    func testEqualLengthEqualisesTheTwoSpans() throws {
        let solution = try solve(
            [point(0, 0), point(10, 0), point(13, 4)],
            [.equalLength(first: 0, second: 1)]
        )
        XCTAssertTrue(solution.isSatisfied)
        XCTAssertEqual(solution.degreesOfFreedom, 2)
        let sides = sideLengths(solution.polyline)
        XCTAssertEqual(sides.count, 2)
        XCTAssertEqual(sides[0], sides[1], accuracy: 1e-9)
    }

    func testTwoTangentsMakeOneStraightLine() throws {
        let fixture = [point(0, 0), point(10, 3), point(20, -2), point(31, 4)]
        let solution = try solve(
            fixture,
            [.tangent(first: 0, second: 1), .tangent(first: 1, second: 2)]
        )
        XCTAssertTrue(solution.isSatisfied)
        XCTAssertEqual(solution.degreesOfFreedom, 3)
        // Every joint must turn by zero when the chain is one straight line.
        XCTAssertLessThanOrEqual(abs(turnAngle(solution.polyline, first: 0, joint: 1, tail: 2)), 1e-9)
        XCTAssertLessThanOrEqual(abs(turnAngle(solution.polyline, first: 1, joint: 2, tail: 3)), 1e-9)
        // And the middle vertices must actually lie between the outer ones on one
        // line, not merely close to it in angle.
        let bend = turnAngle(solution.polyline, first: 0, joint: 1, tail: 3)
        XCTAssertLessThanOrEqual(abs(bend), 1e-9, "the middle vertex must lie on the same line")
        XCTAssertGreaterThan(turnCosine(solution.polyline, first: 0, joint: 1, tail: 2), 0.9)
    }

    func testARepeatedHorizontalIsAcceptedAndAddsNoFreedom() throws {
        let solution = try solve(
            [point(0, 0), point(10, 3)],
            [.horizontal(segment: 0), .horizontal(segment: 0)]
        )
        XCTAssertTrue(solution.isSatisfied)
        // A two-point span has no shape freedom once its direction is fixed: the
        // gauge already owns its length and position.
        XCTAssertEqual(solution.degreesOfFreedom, 0)
    }

    // MARK: - Over-constraint

    func testAnImpossibleSetNamesTheOffendingConstraint() throws {
        // A vertical first span and a horizontal second span are parallel only
        // if one of them has zero length, so this tangency has no valid answer at
        // all — the conflict is structural, not a branch the solver missed.
        let solution = try solve(
            [point(0, 0), point(0, 10), point(6, 10)],
            [
                .vertical(segment: 0),
                .horizontal(segment: 1),
                .tangent(first: 0, second: 1),
            ]
        )
        XCTAssertFalse(solution.isSatisfied)
        XCTAssertEqual(solution.conflicts, [.tangent(first: 0, second: 1)])
        // The accepted prefix is reported in the order the caller gave it.
        XCTAssertEqual(solution.applied, [.vertical(segment: 0), .horizontal(segment: 1)])
        XCTAssertGreaterThan(sideLengths(solution.polyline).min() ?? 0, 1e-6)
        XCTAssertEqual(solution.polyline.vertices.count, 3)
    }

    func testATangencyImpliedByTwoHorizontalsIsAccepted() throws {
        let solution = try solve(
            [point(0, 0), point(10, 3), point(20, -2)],
            [
                .horizontal(segment: 0),
                .horizontal(segment: 1),
                .tangent(first: 0, second: 1),
            ]
        )
        XCTAssertTrue(solution.isSatisfied)
        XCTAssertEqual(solution.conflicts, [])
        XCTAssertEqual(solution.applied.count, 3)
    }

    // MARK: - Structural refusals

    func testAnArcSpanIsRefusedWithASentence() throws {
        let payload = FFCurvePayload(
            segments: [
                line(point(0, 0), point(10, 0)),
                FFCurveSegment(
                    kind: .bezier,
                    controlPoints: [
                        FFPoint2(point(10, 0)),
                        FFPoint2(point(12, 2)),
                        FFPoint2(point(14, 2)),
                        FFPoint2(point(16, 0)),
                    ]
                ),
            ]
        )
        XCTAssertThrowsError(try FFSketchPolyline(payload: payload)) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Segment 2 is not a straight span, so it has no chord to constrain"
            )
        }
    }

    func testTangencyBetweenNonNeighboursIsRefused() throws {
        let chain = FFSketchPolyline(vertices: offSquareRectangle, isClosed: true)
        XCTAssertThrowsError(
            try FFSketchConstraintSolver.solve(
                chain,
                constraints: [.tangent(first: 0, second: 2)]
            )
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Segments 0 and 2 do not share a vertex, so they have no joint to make tangent"
            )
        }
    }

    func testASegmentIndexOutsideTheChainIsRefused() throws {
        let chain = FFSketchPolyline(vertices: [point(0, 0), point(4, 0)], isClosed: false)
        XCTAssertThrowsError(
            try FFSketchConstraintSolver.solve(chain, constraints: [.vertical(segment: 3)])
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Segment 4 is not part of that curve"
            )
        }
        XCTAssertThrowsError(
            try FFSketchConstraintSolver.solve(chain, constraints: [])
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Choose at least one constraint"
            )
        }
    }

    func testABrokenChainIsRefused() throws {
        let payload = FFCurvePayload(
            segments: [
                line(point(0, 0), point(10, 0)),
                line(point(12, 1), point(20, 1)),
            ]
        )
        XCTAssertThrowsError(try FFSketchPolyline(payload: payload)) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Segment 2 does not start where the one before it ended"
            )
        }
    }

    // MARK: - Determinism and payload shape

    func testSolvingTwiceGivesTheSameSketch() throws {
        let constraints: [FFSketchConstraint] = [
            .horizontal(segment: 0),
            .equalLength(first: 0, second: 1),
        ]
        let first = try solve([point(0, 0), point(10, 0), point(13, 4)], constraints)
        let second = try solve([point(0, 0), point(10, 0), point(13, 4)], constraints)
        XCTAssertEqual(first.polyline.payload().fingerprint, second.polyline.payload().fingerprint)
        XCTAssertEqual(first.iterations, second.iterations)
        XCTAssertEqual(first.residual, second.residual)
    }

    func testAConstrainedSketchIsStillAPlainPolyline() throws {
        let fixture = offSquareRectangle
        let source = polyline(fixture, isClosed: true)
        let chain = try FFSketchPolyline(payload: source)
        let solution = try FFSketchConstraintSolver.solve(
            chain,
            constraints: [.horizontal(segment: 0), .vertical(segment: 1)]
        )
        let written = solution.polyline.payload()
        XCTAssertTrue(written.isClosed)
        XCTAssertEqual(written.segments.count, source.segments.count)
        for segment in written.segments {
            XCTAssertEqual(segment.kind, .bezier)
            XCTAssertEqual(segment.controlPoints.count, 2)
            XCTAssertEqual(segment.weights, [])
            XCTAssertEqual(segment.knots, [])
        }
        XCTAssertEqual(written.fingerprint, solution.polyline.payload().fingerprint)
        // The written payload must rebuild as a curve, not merely encode.
        XCTAssertNotNil(written.path())
    }

    // MARK: - Session ownership

    private func makeSession(_ points: [Vec2], isClosed: Bool = true) -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 51")
        let node = FFNode(
            name: "Constrained sketch",
            geometry: .curve(polyline(points, isClosed: isClosed)),
            layerID: document.currentLayerID,
            curvePrimitive: FFCurvePrimitive(kind: .polygon)
        )
        document.rootNodes = [node]
        return (FFEditorSession(document: document), node.id)
    }

    func testTheConstraintCommandIsOneUndo() throws {
        let (session, nodeID) = makeSession(offSquareRectangle)
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        let changed = session.constrainCurve(
            nodeID: nodeID,
            constraints: [
                .horizontal(segment: 0),
                .horizontal(segment: 2),
                .vertical(segment: 1),
                .vertical(segment: 3),
            ]
        )
        XCTAssertTrue(changed, session.sketchConstraintMessage ?? "no message")
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertNil(session.curveEditMessage)
        XCTAssertNil(session.sketchConstraintMessage)
        let solution = try XCTUnwrap(session.lastSketchConstraintSolution)
        XCTAssertTrue(solution.isSatisfied)
        XCTAssertEqual(solution.degreesOfFreedom, 1)
        XCTAssertTrue(session.documentStatus.hasPrefix("Sketch constrained · 4 constraints · DOF 1"))

        let edited = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertNotEqual(edited.fingerprint, original)
        XCTAssertNil(session.document.node(withID: nodeID)?.curvePrimitive)
        XCTAssertEqual(session.document.rootNodes.count, 1)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            original,
            "one undo must restore the sketch exactly as drawn"
        )
    }

    func testARefusedSetWritesNothing() throws {
        let (session, nodeID) = makeSession(
            [point(0, 0), point(0, 10), point(6, 10)],
            isClosed: false
        )
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        let changed = session.constrainCurve(
            nodeID: nodeID,
            constraints: [
                .vertical(segment: 0),
                .horizontal(segment: 1),
                .tangent(first: 0, second: 1),
            ]
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        let message = try XCTUnwrap(session.sketchConstraintMessage)
        XCTAssertTrue(
            message.hasPrefix("That set over-constrains this sketch at: Tangent on segments 0 and 1"),
            message
        )
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            original
        )
    }

    func testAConstraintOnAnArcCreatesNoHistory() throws {
        var document = FFDocument(name: "Phase 51 arc")
        let node = FFNode(
            name: "Arc sketch",
            geometry: .curve(
                FFCurvePayload(segments: [
                    FFCurveSegment(
                        kind: .bezier,
                        controlPoints: [
                            FFPoint2(point(0, 0)),
                            FFPoint2(point(5, 5)),
                            FFPoint2(point(10, 5)),
                            FFPoint2(point(15, 0)),
                        ]
                    ),
                ])
            ),
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        let session = FFEditorSession(document: document)

        XCTAssertFalse(
            session.constrainCurve(nodeID: node.id, constraints: [.horizontal(segment: 0)])
        )
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(
            session.sketchConstraintMessage,
            "Segment 1 is not a straight span, so it has no chord to constrain"
        )
        XCTAssertNil(session.lastSketchConstraintSolution)
    }

    func testAConstrainedSketchSurvivesSaveAndReopen() throws {
        let (session, nodeID) = makeSession(offSquareRectangle)
        _ = session.constrainCurve(
            nodeID: nodeID,
            constraints: [.horizontal(segment: 0), .vertical(segment: 1)]
        )
        let committed = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))

        let data = try JSONEncoder().encode(session.document)
        let reopened = try JSONDecoder().decode(FFDocument.self, from: data)
        let decoded = try XCTUnwrap(reopened.curvePayload(forNodeID: nodeID))

        XCTAssertEqual(decoded.fingerprint, committed.fingerprint)
        XCTAssertEqual(decoded.segments.count, committed.segments.count)
        XCTAssertNotNil(decoded.path())
    }

    // MARK: - Spread of geometry

    /// A deterministic generator so a failure is reproducible and never depends
    /// on the order the system chose to run the tests in.
    private struct Jitter: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func jitteredSketch(_ generator: inout Jitter, count: Int) -> [Vec2] {
        var points: [Vec2] = []
        var x = 0.0
        var y = 0.0
        for _ in 0..<count {
            x += 6 + Double(generator.next() % 8000) / 1000
            y = Double(Int(generator.next() % 16000) - 8000) / 1000
            points.append(point(x, y))
        }
        return points
    }

    func testSatisfiableSetsConvergeOnJitteredSketches() throws {
        var generator = Jitter(seed: 5_150_051)
        var solved = 0
        for recipe in 0..<3 {
            for _ in 0..<8 {
                let count = 3 + Int(generator.next() % 3)
                let fixture = jitteredSketch(&generator, count: count)
                let constraints: [FFSketchConstraint]
                switch recipe {
                case 0:
                    constraints = (0..<(count - 1)).map { .horizontal(segment: $0) }
                case 1:
                    constraints = (0..<(count - 2)).map { .tangent(first: $0, second: $0 + 1) }
                default:
                    constraints = (0..<(count - 2)).map { .equalLength(first: $0, second: $0 + 1) }
                }
                let solution = try solve(fixture, constraints)
                XCTAssertTrue(
                    solution.isSatisfied,
                    "recipe \(recipe) on \(fixture) reported \(solution.conflicts)"
                )
                XCTAssertLessThanOrEqual(solution.residual, 1e-9)
                XCTAssertLessThanOrEqual(solution.iterations, 9)
                XCTAssertGreaterThan(sideLengths(solution.polyline).min() ?? 0, 1e-6)
                if recipe == 1 {
                    // The model found three of eight starting chains landing on a
                    // half-turn fold while the residual was a bare sine; the
                    // angle residual must never leave one there.
                    for joint in 1..<(count - 1) {
                        XCTAssertLessThanOrEqual(
                            abs(turnAngle(solution.polyline, first: joint - 1, joint: joint, tail: joint + 1)),
                            1e-9
                        )
                        XCTAssertGreaterThan(
                            turnCosine(solution.polyline, first: joint - 1, joint: joint, tail: joint + 1),
                            0.9,
                            "a tangent chain folded back at joint \(joint)"
                        )
                    }
                }
                solved += 1
            }
        }
        XCTAssertEqual(solved, 24)
    }
}
