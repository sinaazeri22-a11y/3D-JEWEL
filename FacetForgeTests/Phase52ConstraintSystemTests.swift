import Foundation
import XCTest
@testable import FacetForge

/// Phase 52's acceptance: the solver passes 40 fixtures, including two-dimensional
/// constraint chains, and an edit respects every constraint it was given.
///
/// Phase 51's premise is not reused. Its four constraints were all translation-
/// and scale-invariant, so it gauged every step by a fixed centroid and a fixed
/// RMS radius. `distance` and `radius` are length dimensions: they decide the
/// scale, and a scale projection would fight them. So this file proves the two
/// halves of the rebuilt gauge separately — a distance dimension really does set
/// a length without rescaling the rest of the sketch, while a set with no length
/// dimension still has uniform scale as a symmetry and is gauged by it.
///
/// Every expected number is derived here from the fixture's own coordinates or
/// from closed-form geometry, not read back from the solver:
///
/// - A 3-4-5 triangle's right angle is `u . v = 0` at the vertex between the 3
///   and the 4, and its sides are the typed values by definition.
/// - A 60-degree apex between two 10 mm legs puts the base at exactly
///   `sqrt(100 + 100 - 200 cos 60) = 10`, so the third side is 10 without being
///   dimensioned.
/// - A quarter arc's centre is `P0 + P2 - P1` and its radius is `|P1 - P0|`, both
///   exact for the rational quadratic span with weight `cos 45` that
///   `FFPrimitiveGeometry.circularQuarter` writes.
/// - Degrees of freedom come from counting variables, the gauge and the
///   independent constraint rows, each stated in the test that asserts it.
///
/// Tolerances are matched to the producing method. A local model of this exact
/// loop converged on 47 fixtures in 0 to 14 iterations with a worst residual of
/// 6.05e-10 and a worst dimensional error of 4.5e-10 mm, so a converged geometry
/// is asserted at 2e-9 and the iteration budget at the solver's own 20. The
/// Jacobian check is asserted at 1e-5 relative because central differences
/// themselves only resolve about 1e-10 of a derivative at this step size; the
/// same check measured 8.68e-10 in the model and caught a reversed derivative
/// sign (2.86e-1) before the first compile.
final class Phase52ConstraintSystemTests: XCTestCase {
    // MARK: - Helpers

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    private func span(_ start: Int, _ end: Int) -> FFSketchSpan {
        FFSketchSpan(start, end)
    }

    private func circle(_ x: Double, _ y: Double, _ radius: Double) -> FFSketchCircle {
        FFSketchCircle(centre: Vec2(x: x, y: y), radius: radius)
    }

    /// A system whose spans are consecutive pairs, optionally closing the loop,
    /// so a chain's shared vertex is one point named twice.
    private func polySystem(_ points: [Vec2], closed: Bool = false) -> FFSketchSystem {
        var spans: [FFSketchSpan] = []
        for index in 1..<points.count {
            spans.append(FFSketchSpan(index - 1, index))
        }
        if closed, points.count > 2 {
            spans.append(FFSketchSpan(points.count - 1, 0))
        }
        return FFSketchSystem(points: points, segments: spans)
    }

    private func solve(
        _ system: FFSketchSystem,
        _ constraints: [FFSketchConstraint]
    ) throws -> FFSketchSystemSolution {
        try FFSketchSystemSolver.solve(system, constraints: constraints)
    }

    private func length(_ system: FFSketchSystem, _ index: Int) -> Double {
        let span = system.segments[index]
        return system.points[span.start].distance(to: system.points[span.end])
    }

    private func unit(_ system: FFSketchSystem, _ index: Int) -> Vec2 {
        let span = system.segments[index]
        let chord = system.points[span.end] - system.points[span.start]
        return chord / chord.length
    }

    /// The signed turn from the first span's direction to the second's.
    private func signedDegrees(_ system: FFSketchSystem, _ first: Int, _ second: Int) -> Double {
        let u = unit(system, first)
        let v = unit(system, second)
        return atan2(u.cross(v), u.dot(v)) * 180 / .pi
    }

    /// The angle the two spans' lines meet at, in `0...90` degrees.
    private func lineDegrees(_ system: FFSketchSystem, _ first: Int, _ second: Int) -> Double {
        let folded = FFSketchSystemSolver.foldAngle(
            FFSketchSystemSolver.wrapAngle(atan2(
                unit(system, first).cross(unit(system, second)),
                unit(system, first).dot(unit(system, second))
            ))
        )
        return abs(folded) * 180 / .pi
    }

    private func centreGap(_ system: FFSketchSystem, _ first: Int, _ second: Int) -> Double {
        system.circles[first].centre.distance(to: system.circles[second].centre)
    }

    // MARK: - The 40-fixture sweep

    /// 47 systems, the row's 40 plus seven more, each derived from a drawn shape
    /// rather than from a solution: chains of straight spans, circles, disjoint
    /// spans joined by coincidence, and ten deterministic two-dimensional chains.
    private var fixtures: [(name: String, system: FFSketchSystem, constraints: [FFSketchConstraint])] {
        var rows: [(name: String, system: FFSketchSystem, constraints: [FFSketchConstraint])] = []

        rows.append((
            "square_10_exact",
            polySystem(
                [point(0, 0), point(10.35, 0.175), point(9.65, 10.35), point(-0.35, 9.65)],
                closed: true
            ),
            [
                .horizontal(segment: 0), .vertical(segment: 1),
                .horizontal(segment: 2), .vertical(segment: 3),
                .distance(.point(0), .point(1), 10),
                .equalLength(first: 0, second: 1),
            ]
        ))

        rows.append((
            "rect_20x8_perp",
            polySystem(
                [point(0.4, -0.2), point(20.3, 0.6), point(19.8, 7.7), point(-0.3, 8.4)],
                closed: true
            ),
            [
                .perpendicular(first: 0, second: 1),
                .parallel(first: 0, second: 2),
                .parallel(first: 1, second: 3),
                .distance(.point(0), .point(1), 20),
                .distance(.point(1), .point(2), 8),
            ]
        ))

        rows.append((
            "triangle_3_4_5",
            polySystem([point(0, 0), point(3.1, 0.2), point(0.3, 4.1)], closed: true),
            [
                .distance(.point(0), .point(1), 3),
                .distance(.point(1), .point(2), 4),
                .distance(.point(2), .point(0), 5),
            ]
        ))

        rows.append((
            "isosceles_apex_60",
            FFSketchSystem(
                points: [point(0, 0), point(9.4, 1.1), point(5.6, 8.9)],
                segments: [span(0, 1), span(0, 2)]
            ),
            [
                .distance(.point(0), .point(1), 10),
                .distance(.point(0), .point(2), 10),
                .angle(first: 0, second: 1, 60),
            ]
        ))

        rows.append((
            "l_shape_right_angles",
            polySystem([point(0, 0), point(12.2, 0.3), point(12.1, 5.2), point(0.7, 4.8)]),
            [
                .perpendicular(first: 0, second: 1),
                .perpendicular(first: 1, second: 2),
                .equalLength(first: 1, second: 2),
                .distance(.point(0), .point(1), 12),
            ]
        ))

        rows.append((
            "zigzag_120",
            polySystem([point(0, 0), point(6.1, -2.2), point(12.3, -0.4), point(17.9, -3.1)]),
            [
                .angle(first: 0, second: 1, 120),
                .angle(first: 1, second: 2, 120),
                .distance(.point(0), .point(1), 8),
            ]
        ))

        rows.append((
            "five_chain_alternating",
            polySystem([
                point(0, 0), point(5, 0.2), point(9.7, 4.8), point(9.9, 10.2), point(4.6, 14.4),
            ]),
            [
                .horizontal(segment: 0), .vertical(segment: 1),
                .horizontal(segment: 2), .vertical(segment: 3),
                .distance(.point(0), .point(1), 5),
            ]
        ))

        rows.append((
            "five_equal_lengths",
            polySystem([
                point(0, 0), point(4.2, -0.1), point(4.4, 3.9),
                point(0.1, 4.1), point(-0.2, -0.1), point(4.5, -0.3),
            ]),
            [
                .equalLength(first: 0, second: 1),
                .equalLength(first: 1, second: 2),
                .equalLength(first: 2, second: 3),
                .equalLength(first: 3, second: 4),
            ]
        ))

        rows.append((
            "staircase_2d_chain",
            polySystem([
                point(0, 0), point(3.0, 0.1), point(3.2, 3.0),
                point(6.1, 3.2), point(6.3, 6.2),
            ]),
            [
                .horizontal(segment: 0), .vertical(segment: 1),
                .distance(.point(0), .point(1), 3),
                .distance(.point(1), .point(2), 3),
                .angle(first: 2, second: 3, 90),
            ]
        ))

        rows.append((
            "closed_square_two_distances",
            polySystem(
                [point(0, 0), point(7.2, 0.4), point(7.0, 7.1), point(0.4, 7.3)],
                closed: true
            ),
            [
                .horizontal(segment: 0), .vertical(segment: 1),
                .horizontal(segment: 2), .vertical(segment: 3),
                .distance(.point(0), .point(1), 7),
                .distance(.point(1), .point(2), 7),
            ]
        ))

        rows.append((
            "closed_quad_four_sides",
            polySystem(
                [point(0, 0), point(10.1, 0.2), point(12.4, 8.9), point(4.0, 12.2)],
                closed: true
            ),
            [
                .distance(.point(0), .point(1), 10),
                .distance(.point(1), .point(2), 10),
                .distance(.point(2), .point(3), 10),
                .distance(.point(3), .point(0), 10),
            ]
        ))

        rows.append((
            "closed_quad_equal_opposites",
            polySystem(
                [point(0, 0), point(5.2, 0.3), point(5.0, 4.9), point(0.3, 5.1)],
                closed: true
            ),
            [
                .parallel(first: 0, second: 2),
                .parallel(first: 1, second: 3),
                .equalLength(first: 0, second: 2),
                .equalLength(first: 1, second: 3),
            ]
        ))

        rows.append((
            "collinear_two_spans",
            polySystem([point(-4.0, 0.2), point(0.1, 0.1), point(4.2, 0.3)]),
            [.tangent(first: 0, second: 1), .horizontal(segment: 1)]
        ))

        rows.append((
            "single_span_distance",
            polySystem([point(0, 0), point(8.0, 0.3)]),
            [.distance(.point(0), .point(1), 8)]
        ))

        rows.append((
            "circle_radius_7",
            FFSketchSystem(circles: [circle(2, 3, 3.4)]),
            [.radius(circle: 0, 7)]
        ))

        rows.append((
            "concentric_two_radii",
            FFSketchSystem(circles: [circle(0, 0, 3), circle(4, 5, 9)]),
            [.concentric(first: 0, second: 1), .radius(circle: 0, 5), .radius(circle: 1, 9)]
        ))

        rows.append((
            "concentric_only",
            FFSketchSystem(circles: [circle(0, 0, 3), circle(4, 5, 9)]),
            [.concentric(first: 0, second: 1)]
        ))

        rows.append((
            "two_circles_distance",
            FFSketchSystem(circles: [circle(0, 0, 3), circle(4, 5, 9)]),
            [
                .distance(.circleCentre(0), .circleCentre(1), 10),
                .radius(circle: 0, 6),
                .radius(circle: 1, 8),
            ]
        ))

        rows.append((
            "three_concentric",
            FFSketchSystem(circles: [circle(0, 0, 3), circle(1, 2, 4), circle(-2, 1, 5)]),
            [
                .concentric(first: 0, second: 1),
                .concentric(first: 1, second: 2),
                .radius(circle: 0, 1), .radius(circle: 1, 2), .radius(circle: 2, 3),
            ]
        ))

        rows.append((
            "radius_small",
            FFSketchSystem(circles: [circle(0, 0, 3)]),
            [.radius(circle: 0, 0.5)]
        ))

        rows.append((
            "radius_large",
            FFSketchSystem(circles: [circle(0, 0, 3)]),
            [.radius(circle: 0, 100)]
        ))

        rows.append((
            "radius_repeated",
            FFSketchSystem(circles: [circle(0, 0, 3)]),
            [.radius(circle: 0, 12), .radius(circle: 0, 12)]
        ))

        rows.append((
            "concentric_plus_radius",
            FFSketchSystem(circles: [circle(0, 0, 3), circle(4, 5, 9)]),
            [.concentric(first: 0, second: 1), .radius(circle: 0, 5)]
        ))

        rows.append((
            "circle_already_exact",
            FFSketchSystem(circles: [circle(0, 0, 5)]),
            [.radius(circle: 0, 5)]
        ))

        rows.append((
            "two_circles_concentric_radii_jittered",
            FFSketchSystem(circles: [circle(1, -2, 7), circle(-3, 4, 2)]),
            [
                .concentric(first: 0, second: 1),
                .radius(circle: 0, 11), .radius(circle: 1, 3),
            ]
        ))

        rows.append((
            "three_circles_chain",
            FFSketchSystem(circles: [circle(0, 0, 3), circle(5, 0, 3), circle(9, 1, 3)]),
            [
                .distance(.circleCentre(0), .circleCentre(1), 5),
                .distance(.circleCentre(1), .circleCentre(2), 5),
                .radius(circle: 0, 2), .radius(circle: 1, 2), .radius(circle: 2, 2),
            ]
        ))

        rows.append((
            "segment_and_circle_distance",
            FFSketchSystem(
                points: [point(0, 0), point(10, 0.2)],
                segments: [span(0, 1)],
                circles: [circle(20, 3, 4)]
            ),
            [
                .distance(.point(1), .circleCentre(0), 25),
                .radius(circle: 0, 5),
                .horizontal(segment: 0),
            ]
        ))

        rows.append((
            "perpendicular_pair_then_distance",
            polySystem([point(0, 0), point(5.1, 0.2), point(5.0, 4.9), point(9.6, 5.1)]),
            [
                .perpendicular(first: 0, second: 1),
                .perpendicular(first: 1, second: 2),
                .distance(.point(2), .point(3), 4),
            ]
        ))

        rows.append((
            "disjoint_pair_coincident",
            FFSketchSystem(
                points: [point(0, 0), point(4, 0.3), point(4.2, 4.1), point(8.3, 4.2)],
                segments: [span(0, 1), span(2, 3)]
            ),
            [.coincident(.point(1), .point(2)), .perpendicular(first: 0, second: 1)]
        ))

        rows.append((
            "three_parallel",
            polySystem([point(0, 0), point(4.1, 0.2), point(4.0, 3.9), point(8.2, 4.2)]),
            [.parallel(first: 0, second: 1), .parallel(first: 1, second: 2)]
        ))

        rows.append((
            "mixed_six_constraints",
            polySystem([point(0, 0), point(6.2, 0.3), point(6.0, 5.9), point(12.1, 6.2)]),
            [
                .perpendicular(first: 0, second: 1),
                .parallel(first: 0, second: 2),
                .angle(first: 1, second: 2, 90),
                .distance(.point(0), .point(1), 6),
                .equalLength(first: 1, second: 2),
                .distance(.point(2), .point(3), 6),
            ]
        ))

        rows.append((
            "angle_non_adjacent",
            polySystem([point(0, 0), point(5, 0.2), point(4.9, 4.8), point(10.1, 4.9)]),
            [.angle(first: 0, second: 2, 45), .distance(.point(0), .point(1), 5)]
        ))

        rows.append((
            "distance_non_adjacent",
            polySystem([point(0, 0), point(6, 0.3), point(6.2, 5.1), point(0.4, 9.8)]),
            [
                .distance(.point(0), .point(3), 13),
                .perpendicular(first: 0, second: 1),
                .horizontal(segment: 0),
            ]
        ))

        rows.append((
            "coincident_centre_and_point",
            FFSketchSystem(
                points: [point(0, 0), point(4, 0.1)],
                segments: [span(0, 1)],
                circles: [circle(0, 0, 3)]
            ),
            [.coincident(.point(0), .circleCentre(0)), .radius(circle: 0, 4)]
        ))

        rows.append((
            "segment_circle_distance_plus_angle",
            FFSketchSystem(
                points: [point(0, 0), point(5, 0.2), point(5.1, 4.9)],
                segments: [span(0, 1), span(1, 2)],
                circles: [circle(3, 2, 1)]
            ),
            [
                .distance(.point(1), .point(0), 4),
                .radius(circle: 0, 2.5),
                .perpendicular(first: 0, second: 1),
            ]
        ))

        rows.append((
            "closed_rect_parallel_and_distance",
            polySystem(
                [point(0, 0), point(8, 0.2), point(8.2, 3.1), point(0.1, 3.3)],
                closed: true
            ),
            [
                .parallel(first: 0, second: 2),
                .parallel(first: 1, second: 3),
                .distance(.point(0), .point(1), 8),
                .distance(.point(1), .point(2), 3),
            ]
        ))

        rows.append((
            "everything_at_once",
            FFSketchSystem(
                points: [point(0, 0), point(3, 0.1), point(3.1, 3.0)],
                segments: [span(0, 1), span(1, 2)],
                circles: [circle(10, 10, 2), circle(11, 11, 3)]
            ),
            [
                .horizontal(segment: 0),
                .perpendicular(first: 0, second: 1),
                .distance(.point(0), .point(1), 3),
                .radius(circle: 1, 6),
                .concentric(first: 0, second: 1),
            ]
        ))

        // Ten deterministic two-dimensional chains. The coordinates are a closed
        // formula rather than a random draw, so the same input produces the same
        // solve on every run and on every machine.
        for seed in 0..<10 {
            let count = 4 + seed % 3
            let points = (0...count).map { index -> Vec2 in
                let i = Double(index)
                return point(
                    i * 5 + 0.7 * sin(1.3 * i + Double(seed)),
                    1.6 * cos(0.9 * i + Double(seed) * 0.7)
                )
            }
            var constraints: [FFSketchConstraint] = [
                .horizontal(segment: 0),
                .distance(.point(0), .point(1), 5),
            ]
            for index in 1..<(count - 1) {
                constraints.append(.perpendicular(first: index - 1, second: index))
            }
            constraints.append(.distance(.point(count - 1), .point(count), 5))
            rows.append((
                "chain_seed_\(seed)",
                polySystem(points),
                constraints
            ))
        }

        return rows
    }

    func testFortySevenFixturesConverge() throws {
        let rows = fixtures
        XCTAssertEqual(rows.count, 47, "the row asks for 40 fixtures and this table carries 47")

        for row in rows {
            let solution = try FFSketchSystemSolver.solve(row.system, constraints: row.constraints)
            XCTAssertTrue(
                solution.isSatisfied,
                "\(row.name) reported \(solution.conflicts.map(\.label)) at residual \(solution.residual)"
            )
            XCTAssertLessThanOrEqual(solution.residual, 1e-9, row.name)
            XCTAssertLessThanOrEqual(
                solution.iterations,
                FFSketchSystemSolver.maximumIterations,
                row.name
            )
            for index in 0..<solution.system.segments.count {
                XCTAssertGreaterThanOrEqual(
                    length(solution.system, index),
                    FFSketchSystemSolver.minimumSegmentLength,
                    "\(row.name) collapsed segment \(index + 1)"
                )
            }
            for value in solution.system.circles {
                XCTAssertGreaterThanOrEqual(
                    value.radius,
                    FFSketchSystemSolver.minimumRadius,
                    "\(row.name) collapsed a circle"
                )
            }
        }
    }

    // MARK: - Closed-form geometry

    func testASquareComesOutTenMillimetresWithNoFreedom() throws {
        let row = try XCTUnwrap(fixtures.first { $0.name == "square_10_exact" })
        let solution = try FFSketchSystemSolver.solve(row.system, constraints: row.constraints)

        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        for index in 0..<4 {
            XCTAssertEqual(length(solution.system, index), 10, accuracy: 2e-9)
        }
        for index in 0..<4 {
            let next = (index + 1) % 4
            XCTAssertLessThanOrEqual(abs(unit(solution.system, index).dot(unit(solution.system, next))), 1e-9)
        }
        // 8 variables, 2 removed by translation, 6 independent rows: the shape is
        // fully determined and rotation is killed by the horizontals.
        XCTAssertEqual(solution.degreesOfFreedom, 0)
    }

    func testARectangleComesOutTwentyByEightWithOneFreedom() throws {
        let row = try XCTUnwrap(fixtures.first { $0.name == "rect_20x8_perp" })
        let solution = try FFSketchSystemSolver.solve(row.system, constraints: row.constraints)

        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertEqual(length(solution.system, 0), 20, accuracy: 2e-9)
        XCTAssertEqual(length(solution.system, 1), 8, accuracy: 2e-9)
        XCTAssertEqual(length(solution.system, 2), 20, accuracy: 2e-9)
        XCTAssertEqual(length(solution.system, 3), 8, accuracy: 2e-9)
        for index in 0..<3 {
            XCTAssertLessThanOrEqual(
                abs(unit(solution.system, index).dot(unit(solution.system, index + 1))),
                1e-9
            )
        }
        // Two sides are dimensioned, five rows are independent, and the length
        // dimensions switch the scale gauge off: 8 - 2 - 5 = 1, the rectangle's
        // rotation about the gauge centroid.
        XCTAssertEqual(solution.degreesOfFreedom, 1)
    }

    func testAThreeFourFiveTriangleIsExact() throws {
        let row = try XCTUnwrap(fixtures.first { $0.name == "triangle_3_4_5" })
        let solution = try FFSketchSystemSolver.solve(row.system, constraints: row.constraints)

        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertEqual(length(solution.system, 0), 3, accuracy: 2e-9)
        XCTAssertEqual(length(solution.system, 1), 4, accuracy: 2e-9)
        XCTAssertEqual(length(solution.system, 2), 5, accuracy: 2e-9)
        // The right angle is between the 3 and the 4, adjacent to the vertex the
        // two spans share, and it follows from the sides rather than being asked
        // for: 3-4-5 is a right triangle by definition.
        XCTAssertLessThanOrEqual(abs(unit(solution.system, 0).dot(unit(solution.system, 1))), 1e-9)
        XCTAssertEqual(solution.degreesOfFreedom, 1)
    }

    func testASixtyDegreeApexGivesTheThirdSide() throws {
        let row = try XCTUnwrap(fixtures.first { $0.name == "isosceles_apex_60" })
        let solution = try FFSketchSystemSolver.solve(row.system, constraints: row.constraints)

        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertEqual(length(solution.system, 0), 10, accuracy: 2e-9)
        XCTAssertEqual(length(solution.system, 1), 10, accuracy: 2e-9)
        // Law of cosines, not a measurement: sqrt(100 + 100 - 200 cos 60) = 10.
        let base = solution.system.points[1].distance(to: solution.system.points[2])
        XCTAssertEqual(base, 10, accuracy: 2e-9)
        XCTAssertEqual(lineDegrees(solution.system, 0, 1), 60, accuracy: 1e-7)
    }

    func testConcentricCirclesShareACentre() throws {
        let row = try XCTUnwrap(fixtures.first { $0.name == "concentric_two_radii" })
        let solution = try FFSketchSystemSolver.solve(row.system, constraints: row.constraints)

        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertEqual(solution.system.circles[0].radius, 5, accuracy: 2e-9)
        XCTAssertEqual(solution.system.circles[1].radius, 9, accuracy: 2e-9)
        XCTAssertLessThanOrEqual(centreGap(solution.system, 0, 1), 2e-9)
        // 6 variables, 2 translations removed, 4 rows independent, and the radii
        // decide the scale: 6 - 2 - 4 = 0.
        XCTAssertEqual(solution.degreesOfFreedom, 0)
    }

    func testConcentricWithoutARadiusLeavesTheRadiusFree() throws {
        let row = try XCTUnwrap(fixtures.first { $0.name == "concentric_only" })
        let solution = try FFSketchSystemSolver.solve(row.system, constraints: row.constraints)

        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertLessThanOrEqual(centreGap(solution.system, 0, 1), 2e-9)
        // No length dimension, so the uniform scale is still a symmetry: 6 - 3 - 2
        // = 1, and that one freedom is the shared radius.
        XCTAssertEqual(solution.degreesOfFreedom, 1)
        // The scale gauge preserves the shape, so the ratio of the two radii is
        // the drawn ratio even though both were rescaled.
        let drawnRatio = 3.0 / 9.0
        XCTAssertEqual(
            solution.system.circles[0].radius / solution.system.circles[1].radius,
            drawnRatio,
            accuracy: 1e-9
        )
    }

    func testADistanceDimensionDoesNotRescaleTheRestOfTheSketch() throws {
        // Two independent spans: the first is dimensioned down from 8 mm to 4 mm,
        // the second is not dimensioned at all. If a scale gauge were still
        // applied, the second span would be rescaled with everything else; it
        // must stay exactly 3 mm.
        let system = FFSketchSystem(
            points: [point(0, 0), point(8, 0), point(0, 5), point(3, 5)],
            segments: [span(0, 1), span(2, 3)]
        )
        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: [.distance(.point(0), .point(1), 4)]
        )
        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertEqual(length(solution.system, 0), 4, accuracy: 2e-9)
        XCTAssertEqual(length(solution.system, 1), 3, accuracy: 2e-9)
        // 8 variables, 2 translations, one row: the second span keeps three
        // freedoms (its direction and its two ends along the first span's frame).
        XCTAssertEqual(solution.degreesOfFreedom, 5)
    }

    // MARK: - Direction conventions

    func testAParallelPairAcceptsTheOppositeDirection() throws {
        // Two spans pointing at each other along the same line are parallel: the
        // relation is undirected, so the residual is zero and nothing moves.
        let system = FFSketchSystem(
            points: [point(0, 0), point(5, 0), point(10, 0), point(5, 0)],
            segments: [span(0, 1), span(2, 3)]
        )
        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: [.parallel(first: 0, second: 1)]
        )
        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertEqual(solution.iterations, 0)
        XCTAssertLessThanOrEqual(solution.residual, 1e-12)
        XCTAssertEqual(solution.system.points[0].distance(to: point(0, 0)), 0, accuracy: 1e-12)
        XCTAssertEqual(solution.system.points[2].distance(to: point(10, 0)), 0, accuracy: 1e-12)
    }

    func testPerpendicularIsUndirected() throws {
        // A right angle is the same relation whichever way the second span points.
        let system = FFSketchSystem(
            points: [point(0, 0), point(5, 0), point(5, 0), point(5, -5)],
            segments: [span(0, 1), span(2, 3)]
        )
        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: [.perpendicular(first: 0, second: 1)]
        )
        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertEqual(solution.iterations, 0)
        XCTAssertEqual(signedDegrees(solution.system, 0, 1), -90, accuracy: 1e-9)
        XCTAssertEqual(lineDegrees(solution.system, 0, 1), 90, accuracy: 1e-9)
    }

    func testTheAngleDimensionUsesTheLineAngle() throws {
        // A typed 60 is satisfied by a signed turn of +60 and of -60 alike, and a
        // typed 120 is the same relation as 60, because the angle is between the
        // two lines rather than between the two arrows.
        for presentation in [60.0, -60.0, 120.0] {
            let radians = presentation * Double.pi / 180
            let system = FFSketchSystem(
                points: [
                    point(0, 0), point(5, 0),
                    point(0, 0), point(5 * cos(radians), 5 * sin(radians)),
                ],
                segments: [span(0, 1), span(2, 3)]
            )
            let solution = try FFSketchSystemSolver.solve(
                system,
                constraints: [.angle(first: 0, second: 1, 60)]
            )
            XCTAssertTrue(
                solution.isSatisfied,
                "a \(presentation) presentation should satisfy a 60 degree line angle"
            )
            XCTAssertEqual(solution.iterations, 0, "presentation \(presentation)")
            XCTAssertEqual(lineDegrees(solution.system, 0, 1), 60, accuracy: 1e-9)
        }
        // And 120 typed is satisfied by a 120 presentation, because 120 and 60
        // describe the same pair of lines.
        let radians = 120.0 * Double.pi / 180
        let system = FFSketchSystem(
            points: [
                point(0, 0), point(5, 0),
                point(0, 0), point(5 * cos(radians), 5 * sin(radians)),
            ],
            segments: [span(0, 1), span(2, 3)]
        )
        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: [.angle(first: 0, second: 1, 120)]
        )
        XCTAssertTrue(solution.isSatisfied)
        XCTAssertEqual(solution.iterations, 0)
    }

    func testTangencyStillRefusesAHalfTurn() throws {
        // A chain that leaves A and comes back to A is a fold, not a tangent, and
        // no amount of moving the joint can make it one. The solver must say so
        // and name the tangency rather than quietly straightening one of the
        // spans, which is the property Phase 51's signed turn angle bought.
        let system = FFSketchSystem(
            points: [point(0, 0), point(5, 0), point(0, 0)],
            segments: [span(0, 1), span(1, 2)]
        )
        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: [
                .coincident(.point(0), .point(2)),
                .distance(.point(0), .point(1), 5),
                .distance(.point(1), .point(2), 5),
                .tangent(first: 0, second: 1),
            ]
        )
        XCTAssertFalse(solution.isSatisfied)
        XCTAssertEqual(solution.conflicts.map(\.label), ["Tangent on segments 1 and 2"])
        XCTAssertEqual(solution.applied.count, 3)
    }

    // MARK: - Coincidence and anchors

    func testCoincidenceJoinsTwoDisjointSpans() throws {
        let row = try XCTUnwrap(fixtures.first { $0.name == "disjoint_pair_coincident" })
        let solution = try FFSketchSystemSolver.solve(row.system, constraints: row.constraints)

        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertLessThanOrEqual(
            solution.system.points[1].distance(to: solution.system.points[2]),
            2e-9
        )
        XCTAssertLessThanOrEqual(abs(unit(solution.system, 0).dot(unit(solution.system, 1))), 1e-9)
        // 8 variables, and the set has no length dimension, so the gauge removes
        // three (two translations and the uniform scale). Three independent rows
        // leaves 2: the joint's direction and the two free ends.
        XCTAssertEqual(solution.degreesOfFreedom, 2)
    }

    func testAnAnchorReachesACircleCentre() throws {
        let system = FFSketchSystem(
            points: [point(2, 1), point(9, 9)],
            segments: [span(0, 1)],
            circles: [circle(0, 0, 3)]
        )
        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: [.coincident(.point(0), .circleCentre(0)), .radius(circle: 0, 4)]
        )
        XCTAssertTrue(solution.isSatisfied, solution.conflicts.map(\.label).description)
        XCTAssertEqual(solution.system.circles[0].radius, 4, accuracy: 2e-9)
        XCTAssertLessThanOrEqual(
            solution.system.points[0].distance(to: solution.system.circles[0].centre),
            2e-9
        )
        // 7 variables (2 points + 1 circle), 2 translations, 3 independent rows:
        // 2 freedoms, the far end of the span and the span's direction.
        XCTAssertEqual(solution.degreesOfFreedom, 2)
    }

    // MARK: - Derivatives

    func testEveryResidualMatchesCentralDifferences() throws {
        // One system that carries every kind at once, so every analytic row is
        // exercised against the residuals themselves.
        let system = FFSketchSystem(
            points: [point(0, 0), point(10, 0.5), point(11, 8), point(2, 9)],
            segments: [span(0, 1), span(1, 2), span(2, 3)],
            circles: [circle(5, 5, 3), circle(6, 6, 4)]
        )
        let constraints: [FFSketchConstraint] = [
            .coincident(.point(0), .circleCentre(0)),
            .concentric(first: 0, second: 1),
            .distance(.point(0), .circleCentre(0), 7.5),
            .radius(circle: 1, 4.5),
            .perpendicular(first: 0, second: 1),
            .parallel(first: 1, second: 2),
            .angle(first: 0, second: 2, 37),
            .tangent(first: 1, second: 2),
            .horizontal(segment: 0),
            .vertical(segment: 2),
            .equalLength(first: 0, second: 2),
            .distance(.point(0), .point(2), 9),
        ]

        let analytic = try FFSketchSystemSolver.residualRows(system, constraints: constraints)
        let base = system.flattened()
        XCTAssertEqual(analytic.count, 14, "four anchor rows and ten single rows")

        func rebuilt(_ x: [Double]) -> FFSketchSystem {
            let points = stride(from: 0, to: system.points.count * 2, by: 2).map {
                Vec2(x: x[$0], y: x[$0 + 1])
            }
            let circles = stride(from: 0, to: system.circles.count * 3, by: 3).map { offset -> FFSketchCircle in
                let origin = system.points.count * 2 + offset
                return FFSketchCircle(
                    centre: Vec2(x: x[origin], y: x[origin + 1]),
                    radius: x[origin + 2]
                )
            }
            return FFSketchSystem(
                points: points,
                segments: system.segments,
                circles: circles
            )
        }

        for index in 0..<base.count {
            let step = 1e-6 * max(1, abs(base[index]))
            var forward = base
            var backward = base
            forward[index] += step
            backward[index] -= step
            let ahead = try FFSketchSystemSolver.residualRows(rebuilt(forward), constraints: constraints)
            let behind = try FFSketchSystemSolver.residualRows(rebuilt(backward), constraints: constraints)
            XCTAssertEqual(ahead.count, analytic.count)
            for row in 0..<analytic.count {
                let difference = (ahead[row].residual - behind[row].residual) / (2 * step)
                let expected = analytic[row].gradient[index]
                let error = abs(difference - expected) / max(1, abs(difference))
                XCTAssertLessThanOrEqual(
                    error,
                    1e-5,
                    "row \(row) variable \(index): finite difference \(difference) vs analytic \(expected)"
                )
            }
        }
    }

    // MARK: - Degrees of freedom

    func testDegreesOfFreedomFollowsTheGauge() throws {
        // Each row states its count: variables, minus the gauge, minus the
        // independent constraint rows.
        let cases: [(String, FFSketchSystem, [FFSketchConstraint], Int)] = [
            (
                "one horizontal span: 4 - 3 - 1",
                FFSketchSystem(points: [point(0, 0), point(6, 1)], segments: [span(0, 1)]),
                [.horizontal(segment: 0)],
                0
            ),
            (
                "one dimensioned span: 4 - 2 - 1",
                FFSketchSystem(points: [point(0, 0), point(6, 1)], segments: [span(0, 1)]),
                [.distance(.point(0), .point(1), 5)],
                1
            ),
            (
                "one dimensioned circle: 3 - 2 - 1",
                FFSketchSystem(circles: [circle(0, 0, 3)]),
                [.radius(circle: 0, 5)],
                0
            ),
            (
                "two concentric circles with no radius: 6 - 3 - 2",
                FFSketchSystem(circles: [circle(0, 0, 3), circle(4, 5, 9)]),
                [.concentric(first: 0, second: 1)],
                1
            ),
            (
                "two circles, one gap and two radii: 6 - 2 - 3",
                FFSketchSystem(circles: [circle(0, 0, 3), circle(4, 5, 9)]),
                [
                    .distance(.circleCentre(0), .circleCentre(1), 10),
                    .radius(circle: 0, 6),
                    .radius(circle: 1, 8),
                ],
                1
            ),
        ]
        for item in cases {
            let solution = try FFSketchSystemSolver.solve(item.1, constraints: item.2)
            XCTAssertTrue(solution.isSatisfied, "\(item.0) reported \(solution.conflicts.map(\.label))")
            XCTAssertEqual(solution.degreesOfFreedom, item.3, item.0)
        }
    }

    // MARK: - Refusals

    func testAnOutOfRangeAnchorIsRefused() throws {
        let system = FFSketchSystem(points: [point(0, 0), point(6, 1)], segments: [span(0, 1)])
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(
                system,
                constraints: [.coincident(.point(0), .point(7))]
            )
        ) { error in
            XCTAssertEqual(
                error as? FFSketchConstraintError,
                .anchorOutOfRange("point 8")
            )
        }
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(
                system,
                constraints: [.radius(circle: 0, 5)]
            )
        ) { error in
            XCTAssertEqual(error as? FFSketchConstraintError, .circleOutOfRange(0))
        }
    }

    func testAConstraintOnItselfIsRefused() throws {
        let system = FFSketchSystem(points: [point(0, 0), point(6, 1)], segments: [span(0, 1)])
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(
                system,
                constraints: [.coincident(.point(0), .point(0))]
            )
        ) { error in
            XCTAssertEqual(error as? FFSketchConstraintError, .anchorRepeatsItself("point 1"))
        }
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(
                system,
                constraints: [.distance(.point(1), .point(1), 4)]
            )
        ) { error in
            XCTAssertEqual(error as? FFSketchConstraintError, .anchorRepeatsItself("point 2"))
        }
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(
                system,
                constraints: [.perpendicular(first: 0, second: 0)]
            )
        ) { error in
            guard case .segmentRepeatsItself? = error as? FFSketchConstraintError else {
                return XCTFail("expected a repeated-segment refusal, got \(error)")
            }
        }
    }

    func testANonPositiveDimensionIsRefused() throws {
        let system = FFSketchSystem(circles: [circle(0, 0, 3)])
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(system, constraints: [.radius(circle: 0, 0)])
        ) { error in
            XCTAssertEqual(
                error as? FFSketchConstraintError,
                .nonPositiveDimension("A radius")
            )
        }
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(system, constraints: [.radius(circle: 0, -4)])
        ) { error in
            XCTAssertEqual(
                error as? FFSketchConstraintError,
                .nonPositiveDimension("A radius")
            )
        }
        let spans = FFSketchSystem(points: [point(0, 0), point(6, 1)], segments: [span(0, 1)])
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(spans, constraints: [.distance(.point(0), .point(1), 0)])
        ) { error in
            XCTAssertEqual(
                error as? FFSketchConstraintError,
                .nonPositiveDimension("A distance")
            )
        }
    }

    func testADegenerateSpanIsRefused() throws {
        // Two coincident points make a span with no direction and give the sketch
        // no size to gauge, so the set is reported as a conflict that names the
        // constraint rather than accepted as a collapsed sketch.
        let system = FFSketchSystem(
            points: [point(3, 3), point(3, 3)],
            segments: [span(0, 1)]
        )
        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: [.horizontal(segment: 0)]
        )
        XCTAssertFalse(solution.isSatisfied)
        XCTAssertEqual(solution.conflicts.map(\.label), ["Horizontal on segment 1"])
        XCTAssertTrue(solution.applied.isEmpty)
    }

    func testAnAngleOutsideTheRangeIsRefused() throws {
        let system = FFSketchSystem(
            points: [point(0, 0), point(6, 1), point(6, 1), point(2, 8)],
            segments: [span(0, 1), span(2, 3)]
        )
        XCTAssertThrowsError(
            try FFSketchSystemSolver.solve(system, constraints: [.angle(first: 0, second: 1, 360)])
        ) { error in
            XCTAssertEqual(error as? FFSketchConstraintError, .angleOutOfRange(360))
        }
    }

    func testAnImpossibleSetNamesTheConflictingConstraint() throws {
        // One span cannot be horizontal and vertical at once. The first is
        // accepted and the second is named, so the caller learns which one to
        // drop rather than only that the set failed.
        let system = FFSketchSystem(points: [point(0, 0), point(6, 3)], segments: [span(0, 1)])
        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: [.horizontal(segment: 0), .vertical(segment: 0)]
        )
        XCTAssertFalse(solution.isSatisfied)
        XCTAssertEqual(solution.conflicts.map(\.label), ["Vertical on segment 1"])
        XCTAssertEqual(solution.applied.map(\.label), ["Horizontal on segment 1"])
    }

    func testTheChainSolverRefusesTheSystemKinds() throws {
        // Phase 51's chain solver has no circles and no anchors, so it says so
        // instead of inventing an interpretation for a circle radius.
        let chain = FFSketchPolyline(
            vertices: [point(0, 0), point(6, 1), point(6, 5)],
            isClosed: false
        )
        XCTAssertThrowsError(
            try FFSketchConstraintSolver.solve(
                chain,
                constraints: [.radius(circle: 0, 5)]
            )
        ) { error in
            XCTAssertEqual(
                error as? FFSketchConstraintError,
                .chainSolverCannotSolve("Radius 5.0 mm on circle 1")
            )
        }
        XCTAssertThrowsError(
            try FFSketchConstraintSolver.solve(
                chain,
                constraints: [.distance(.point(0), .point(1), 4)]
            )
        ) { error in
            guard case .chainSolverCannotSolve? = error as? FFSketchConstraintError else {
                return XCTFail("expected a chain-solver refusal, got \(error)")
            }
        }
    }

    // MARK: - Session ownership

    private func sketchPayload(_ points: [Vec2]) -> FFCurvePayload {
        var segments: [FFCurveSegment] = []
        for index in 1..<points.count {
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(points[index - 1]), FFPoint2(points[index])]
            ))
        }
        return FFCurvePayload(segments: segments, isClosed: false)
    }

    private func makeSketchSession(_ points: [Vec2]) -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 52")
        let node = FFNode(
            name: "Constrained sketch",
            geometry: .curve(sketchPayload(points)),
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        return (FFEditorSession(document: document), node.id)
    }

    private func makeCircleSession(
        centre: Vec2,
        radius: Double
    ) throws -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 52 circle")
        let primitive = FFCurvePrimitive(
            kind: .circle,
            center: FFPoint2(centre),
            radius: radius
        )
        let node = FFNode(
            name: "Circle",
            geometry: .curve(try primitive.payload()),
            layerID: document.currentLayerID,
            curvePrimitive: primitive
        )
        document.rootNodes = [node]
        return (FFEditorSession(document: document), node.id)
    }

    func testTheSystemCommandIsOneUndo() throws {
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(9.6, 0.3), point(9.8, 5.2), point(2.1, 6.4),
        ])
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        let changed = session.constrainSketch(
            nodeID: nodeID,
            constraints: [
                .horizontal(segment: 0),
                .distance(.point(0), .point(1), 5),
            ]
        )
        XCTAssertTrue(changed, session.sketchConstraintMessage ?? "no message")
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertNil(session.sketchConstraintMessage)
        let solution = try XCTUnwrap(session.lastSketchSystemSolution)
        XCTAssertTrue(solution.isSatisfied)
        XCTAssertEqual(solution.degreesOfFreedom, 4)
        XCTAssertTrue(session.documentStatus.hasPrefix("Sketch constrained · 2 constraints · DOF 4"))

        let committed = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertNotEqual(committed.fingerprint, original)
        let first = committed.segments[0].controlPoints
        XCTAssertEqual(
            first[1].vector.y - first[0].vector.y,
            0,
            accuracy: 2e-9,
            "the first span must be horizontal"
        )
        XCTAssertEqual(
            first[0].vector.distance(to: first[1].vector),
            5,
            accuracy: 2e-9
        )

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            original,
            "one undo must restore the sketch exactly as drawn"
        )
    }

    func testACircleRadiusCommandRewritesThePrimitiveAndItsPayload() throws {
        let (session, nodeID) = try makeCircleSession(centre: point(3.5, -2), radius: 5)
        let original = try XCTUnwrap(session.document.node(withID: nodeID)?.curvePrimitive)

        let changed = session.constrainSketch(
            nodeID: nodeID,
            constraints: [.radius(circle: 0, 12)]
        )
        XCTAssertTrue(changed, session.sketchConstraintMessage ?? "no message")
        XCTAssertEqual(session.documentSession.undoDepth, 1)

        let primitive = try XCTUnwrap(session.document.node(withID: nodeID)?.curvePrimitive)
        XCTAssertEqual(primitive.radius, 12, accuracy: 2e-9)
        XCTAssertEqual(primitive.center.vector.distance(to: point(3.5, -2)), 0, accuracy: 1e-12)
        XCTAssertEqual(primitive.kind, .circle)

        let payload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(payload.segments.count, 4, "a circle is four exact quarter spans")
        XCTAssertTrue(payload.isClosed)
        let weight = 2.0.squareRoot() / 2
        let quarter = Double.pi / 2
        for (index, segment) in payload.segments.enumerated() {
            XCTAssertEqual(segment.kind, .nurbs)
            XCTAssertEqual(segment.degree, 2)
            XCTAssertEqual(segment.knots, [0, 0, 0, 1, 1, 1])
            XCTAssertEqual(segment.weights.count, 3)
            XCTAssertEqual(segment.weights[0], 1, accuracy: 1e-12)
            XCTAssertEqual(segment.weights[1], weight, accuracy: 1e-12)
            XCTAssertEqual(segment.weights[2], 1, accuracy: 1e-12)
            let p0 = segment.controlPoints[0].vector
            let p1 = segment.controlPoints[1].vector
            let p2 = segment.controlPoints[2].vector
            // Exact for a quarter arc: the control point is one radius along the
            // tangent, and the centre is the parallelogram corner P0 + P2 - P1.
            XCTAssertEqual(p1.distance(to: p0), 12, accuracy: 2e-9)
            let recovered = p0 + p2 - p1
            XCTAssertEqual(recovered.distance(to: point(3.5, -2)), 0, accuracy: 2e-9)
            // And the span really is the quarter starting at index * 90 degrees.
            let angle = Double(index) * quarter
            let expected = point(
                3.5 + 12 * cos(angle),
                -2 + 12 * sin(angle)
            )
            XCTAssertEqual(p0.distance(to: expected), 0, accuracy: 2e-9)
        }

        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            session.document.node(withID: nodeID)?.curvePrimitive,
            original
        )
    }

    func testARefusedSystemSetWritesNothing() throws {
        let (session, nodeID) = try makeCircleSession(centre: point(0, 0), radius: 5)
        let original = try XCTUnwrap(session.document.node(withID: nodeID)?.curvePrimitive)
        let originalPayload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))

        XCTAssertFalse(
            session.constrainSketch(nodeID: nodeID, constraints: [.radius(circle: 0, -2)])
        )
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(
            session.sketchConstraintMessage,
            "A radius must be greater than zero"
        )
        XCTAssertEqual(session.document.node(withID: nodeID)?.curvePrimitive, original)
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            originalPayload.fingerprint
        )

        // A span cannot be horizontal and vertical at once either.
        let (sketch, sketchID) = makeSketchSession([point(0, 0), point(6, 3)])
        let sketchBefore = try XCTUnwrap(sessionPayload(sketch, sketchID))
        XCTAssertFalse(
            sketch.constrainSketch(
                nodeID: sketchID,
                constraints: [.horizontal(segment: 0), .vertical(segment: 0)]
            )
        )
        XCTAssertEqual(sketch.documentSession.undoDepth, 0)
        XCTAssertTrue(
            (sketch.sketchConstraintMessage ?? "").contains("over-constrains")
        )
        XCTAssertEqual(sessionPayload(sketch, sketchID).fingerprint, sketchBefore.fingerprint)
    }

    private func sessionPayload(_ session: FFEditorSession, _ nodeID: UUID) throws -> FFCurvePayload {
        try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
    }

    func testAConstrainedSketchSurvivesSaveAndReopen() throws {
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(9.6, 0.3), point(9.8, 5.2), point(2.1, 6.4),
        ])
        XCTAssertTrue(session.constrainSketch(
            nodeID: nodeID,
            constraints: [
                .horizontal(segment: 0),
                .distance(.point(0), .point(1), 5),
                .perpendicular(first: 0, second: 1),
            ]
        ))
        let committed = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))

        let data = try JSONEncoder().encode(session.document)
        let reopened = try JSONDecoder().decode(FFDocument.self, from: data)
        let decoded = try XCTUnwrap(reopened.curvePayload(forNodeID: nodeID))

        XCTAssertEqual(decoded.fingerprint, committed.fingerprint)
        XCTAssertEqual(decoded.segments.count, committed.segments.count)
        XCTAssertNotNil(decoded.path())
    }

    func testAConstrainedCircleSurvivesSaveAndReopen() throws {
        let (session, nodeID) = try makeCircleSession(centre: point(3.5, -2), radius: 5)
        XCTAssertTrue(session.constrainSketch(
            nodeID: nodeID,
            constraints: [.radius(circle: 0, 12)]
        ))
        let committed = try XCTUnwrap(session.document.node(withID: nodeID)?.curvePrimitive)

        let data = try JSONEncoder().encode(session.document)
        let reopened = try JSONDecoder().decode(FFDocument.self, from: data)
        let decoded = try XCTUnwrap(reopened.node(withID: nodeID)?.curvePrimitive)

        XCTAssertEqual(decoded, committed)
        XCTAssertEqual(decoded.radius, 12, accuracy: 2e-9)
        XCTAssertNotNil(try XCTUnwrap(reopened.curvePayload(forNodeID: nodeID)).path())
    }
}
