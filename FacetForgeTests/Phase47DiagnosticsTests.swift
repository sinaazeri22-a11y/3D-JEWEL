import Foundation
import XCTest
@testable import FacetForge

/// Phase 47's acceptance: the curvature comb's scale matches the analytic
/// curvature on ten fixtures, and every continuity label agrees with a numeric
/// measurement of the same seam.
///
/// The fixtures are chosen so the answer is known before the code runs: a line
/// and a square bend nowhere, a circle and an arc bend by exactly `1 / radius`,
/// a quarter ellipse is anchored at its two vertices and its 45-degree point,
/// the symmetric cubic's inflection is exactly its centre, and the arch's
/// tightest bend is `4 / 15` at `t = 0.5`. Nothing here is compared against the
/// implementation's own idea of the answer.
final class Phase47DiagnosticsTests: XCTestCase {
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

    /// Four rational quadratic quarter spans, counter-clockwise from `(r, 0)`.
    /// The same encoding `FFArcTool` writes, so the kernel path is the app's.
    private func circle(radius: Double) -> FFCurvePayload {
        let weight = cos(Double.pi / 4)
        let corners = [
            Vec2(x: radius, y: 0),
            Vec2(x: 0, y: radius),
            Vec2(x: -radius, y: 0),
            Vec2(x: 0, y: -radius),
        ]
        let mids = [
            Vec2(x: radius, y: radius),
            Vec2(x: -radius, y: radius),
            Vec2(x: -radius, y: -radius),
            Vec2(x: radius, y: -radius),
        ]
        var segments: [FFCurveSegment] = []
        for index in 0..<4 {
            let next = (index + 1) % 4
            segments.append(FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(corners[index]),
                    FFPoint2(mids[index]),
                    FFPoint2(corners[next]),
                ],
                weights: [1, weight, 1],
                degree: 2,
                knots: [0, 0, 0, 1, 1, 1]
            ))
        }
        return FFCurvePayload(segments: segments, isClosed: true)
    }

    private func arcPayload(
        center: Vec2,
        radius: Double,
        startAngle: Double,
        sweep: Double
    ) throws -> FFCurvePayload {
        let arc = try FFArc2D(
            center: center,
            radius: radius,
            startAngle: startAngle,
            sweep: sweep
        )
        return FFArcTool.payload(for: arc)
    }

    /// One rational quadratic quarter of the ellipse `x = a cos t`, `y = b sin t`.
    private func ellipseQuarter(a: Double, b: Double) -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(point(a, 0)),
                    FFPoint2(point(a, b)),
                    FFPoint2(point(0, b)),
                ],
                weights: [1, cos(Double.pi / 4), 1],
                degree: 2,
                knots: [0, 0, 0, 1, 1, 1]
            ),
        ])
    }

    private func cubic(_ points: [Vec2]) -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(kind: .bezier, controlPoints: points.map { FFPoint2($0) }),
        ])
    }

    /// The classic symmetric S: its midpoint is the origin of its own symmetry,
    /// so the curvature there is exactly zero.
    private func sCurve() -> FFCurvePayload {
        cubic([
            point(0, 0),
            point(10, 25),
            point(30, -25),
            point(40, 0),
        ])
    }

    /// An arch whose curvature is negative everywhere: no inflection inside it.
    private func arch() -> FFCurvePayload {
        cubic([
            point(0, 0),
            point(0, 10),
            point(10, 10),
            point(10, 0),
        ])
    }

    private func square() -> FFCurvePayload {
        polyline(
            [point(0, 0), point(4, 0), point(4, 4), point(0, 4)],
            isClosed: true
        )
    }

    private func rightAngle() -> FFCurvePayload {
        polyline([point(0, 0), point(10, 0), point(10, 10)])
    }

    private func assertPoint(
        _ actual: Vec2,
        _ expected: Vec2,
        accuracy: Double = 1e-9,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Curvature comb

    func testCurvatureCombMatchesAnalyticCurvatureOnTenFixtures() throws {
        struct Fixture {
            var name: String
            var payload: FFCurvePayload
            /// The analytic curvature when the parameter has a closed form, or
            /// nil where only the scale invariant applies.
            var analytic: (Int, Double) -> Double?
        }

        let fillet = try rightAngle().treatingCorner(0, with: .fillet(radius: 2)).treatment
        let arc12 = try arcPayload(center: .zero, radius: 12, startAngle: 0, sweep: .pi / 2)
        // The ellipse's 45-degree point: a*b / ((a^2 + b^2) / 2)^(3/2).
        let ellipse45 = 10.0 * 4.0 / pow((100.0 + 16.0) / 2, 1.5)

        let fixtures: [Fixture] = [
            Fixture(name: "horizontal line", payload: polyline([point(0, 0), point(10, 0)])) { _, _ in 0 },
            Fixture(name: "vertical line", payload: polyline([point(0, 0), point(0, 10)])) { _, _ in 0 },
            Fixture(name: "circle r=40", payload: circle(radius: 40)) { _, _ in 1.0 / 40.0 },
            Fixture(name: "circle r=7", payload: circle(radius: 7)) { _, _ in 1.0 / 7.0 },
            Fixture(name: "fillet arc r=2", payload: fillet) { _, _ in 0.5 },
            Fixture(name: "arc r=12", payload: arc12) { _, _ in 1.0 / 12.0 },
            Fixture(name: "ellipse quarter", payload: ellipseQuarter(a: 10, b: 4)) { segment, parameter in
                guard segment == 0 else { return nil }
                if parameter == 0 { return 10.0 / 16.0 }
                if parameter == 0.5 { return ellipse45 }
                if parameter == 1 { return 4.0 / 100.0 }
                return nil
            },
            Fixture(name: "arch cubic", payload: arch()) { _, parameter in
                parameter == 0.5 ? 4.0 / 15.0 : nil
            },
            Fixture(name: "symmetric S", payload: sCurve()) { _, parameter in
                parameter == 0.5 ? 0 : nil
            },
            Fixture(name: "closed square", payload: square()) { _, _ in 0 },
        ]
        XCTAssertEqual(fixtures.count, 10, "the row asks for ten analytic fixtures")

        let scale = 2.0
        for fixture in fixtures {
            let samples = try XCTUnwrap(
                FFCurveDiagnostics.curvatureComb(
                    of: fixture.payload,
                    samplesPerSegment: 32,
                    scale: scale
                ),
                "\(fixture.name): the comb refused to measure the payload"
            )
            XCTAssertFalse(samples.isEmpty, "\(fixture.name): no samples")

            for sample in samples {
                let curve = try XCTUnwrap(fixture.payload.segments[sample.segment].curve)
                let tangent = curve.derivative(at: sample.parameter)
                let speed = tangent.length
                if speed > FFMath.eps {
                    let expectedNormal = Vec2(x: -tangent.y / speed, y: tangent.x / speed)
                    assertPoint(sample.normal, expectedNormal, accuracy: 1e-12, fixture.name)
                    assertPoint(
                        sample.combTip,
                        sample.point + sample.normal * (sample.curvature * scale),
                        accuracy: 1e-12,
                        fixture.name
                    )
                    XCTAssertGreaterThanOrEqual(
                        sample.curvature,
                        0,
                        "\(fixture.name): the comb's curvature must be unsigned"
                    )
                }
                if let expected = fixture.analytic(sample.segment, sample.parameter) {
                    // The kernel's NURBS second derivative is a documented one-
                    // sided difference at a span's ends, measured at 8.8e-7
                    // relative; the tolerance leaves room for that and still
                    // catches any structural error.
                    XCTAssertEqual(
                        sample.curvature,
                        expected,
                        accuracy: max(1e-9, abs(expected) * 3e-6),
                        "\(fixture.name): curvature at t=\(sample.parameter) of span \(sample.segment)"
                    )
                }
            }
        }
    }

    // MARK: - Inflections

    func testTheSymmetricCubicHasExactlyOneInflectionAtItsCentre() throws {
        let markers = try XCTUnwrap(FFCurveDiagnostics.inflections(of: sCurve()))
        XCTAssertEqual(markers.count, 1)
        let marker = try XCTUnwrap(markers.first)
        XCTAssertEqual(marker.segment, 0)
        XCTAssertEqual(marker.parameter, 0.5, accuracy: 1e-9)
        assertPoint(marker.point, point(20, 0), accuracy: 1e-9)
        XCTAssertTrue(marker.summary.hasPrefix("Inflection"))
    }

    func testStraightAndConsistentlyCurvingPayloadsHaveNoInflection() throws {
        for payload in [circle(radius: 40), polyline([point(0, 0), point(10, 0)]), arch(), square()] {
            let markers = try XCTUnwrap(FFCurveDiagnostics.inflections(of: payload))
            XCTAssertEqual(markers.count, 0)
        }
    }

    func testASignChangeAtASealIsNotAnInflection() throws {
        // Both arcs leave (0, 40) along (-1, 0); the first turns left and the
        // second turns right, so the curvature flips sign at a G1 seam rather
        // than crossing zero inside a span.
        let first = try arcPayload(center: .zero, radius: 40, startAngle: 0, sweep: .pi / 2)
        let second = try arcPayload(
            center: point(0, 81),
            radius: 41,
            startAngle: -.pi / 2,
            sweep: -.pi / 2
        )
        let payload = FFCurvePayload(segments: first.segments + second.segments)

        let joins = try XCTUnwrap(FFCurveDiagnostics.joins(of: payload))
        XCTAssertEqual(joins.count, 1)
        XCTAssertEqual(joins[0].continuity, FFCurveContinuity.g1)
        XCTAssertLessThan(joins[0].tangentAngle, 1e-9)
        XCTAssertEqual(joins[0].curvatureBefore, 1.0 / 40.0, accuracy: 1e-6)
        XCTAssertEqual(joins[0].curvatureAfter, -1.0 / 41.0, accuracy: 1e-6)

        XCTAssertEqual(try XCTUnwrap(FFCurveDiagnostics.inflections(of: payload)).count, 0)
    }

    // MARK: - Continuity

    func testAFilletedCornerReadsAsTwoTangentJoinsWithItsExactCurvature() throws {
        let filleted = try rightAngle().treatingCorner(0, with: .fillet(radius: 2)).payload
        let readings = try XCTUnwrap(FFCurveDiagnostics.joins(of: filleted))
        XCTAssertEqual(readings.count, 2)

        XCTAssertEqual(readings[0].index, 0)
        XCTAssertEqual(readings[0].continuity, FFCurveContinuity.g1)
        XCTAssertEqual(readings[0].gap, 0, accuracy: 1e-12)
        XCTAssertLessThan(readings[0].tangentAngle, 1e-9)
        XCTAssertEqual(readings[0].curvatureBefore, 0, accuracy: 1e-12)
        XCTAssertEqual(readings[0].curvatureAfter, 0.5, accuracy: 2e-6)

        XCTAssertEqual(readings[1].index, 1)
        XCTAssertEqual(readings[1].continuity, FFCurveContinuity.g1)
        XCTAssertLessThan(readings[1].tangentAngle, 1e-9)
        XCTAssertEqual(readings[1].curvatureBefore, 0.5, accuracy: 2e-6)
        XCTAssertEqual(readings[1].curvatureAfter, 0, accuracy: 1e-12)
    }

    func testAQuarteredCircleReadsAsFourG2Seams() throws {
        let readings = try XCTUnwrap(FFCurveDiagnostics.joins(of: circle(radius: 40)))
        XCTAssertEqual(readings.count, 4)
        for reading in readings {
            XCTAssertEqual(reading.continuity, FFCurveContinuity.g2)
            XCTAssertLessThan(reading.gap, FFTolerance.curveJoin)
            XCTAssertLessThan(reading.tangentAngle, 1e-9)
            XCTAssertEqual(reading.curvatureBefore, 1.0 / 40.0, accuracy: 1e-6)
            XCTAssertEqual(reading.curvatureAfter, 1.0 / 40.0, accuracy: 1e-6)
            XCTAssertLessThan(reading.curvatureDifference, 1e-6)
            XCTAssertTrue(reading.summary.hasPrefix("G2"))
        }
    }

    func testASquareReadsAsFourRightAngleG0Seams() throws {
        let readings = try XCTUnwrap(FFCurveDiagnostics.joins(of: square()))
        XCTAssertEqual(readings.count, 4)
        for reading in readings {
            XCTAssertEqual(reading.continuity, FFCurveContinuity.g0)
            XCTAssertEqual(reading.tangentAngle, Double.pi / 2, accuracy: 1e-12)
            XCTAssertEqual(reading.curvatureBefore, 0, accuracy: 1e-12)
            XCTAssertEqual(reading.curvatureAfter, 0, accuracy: 1e-12)
        }
    }

    func testTangentArcsOfDifferentRadiusReadAsG1NotG2() throws {
        let first = try arcPayload(center: .zero, radius: 40, startAngle: 0, sweep: .pi / 2)
        let second = try arcPayload(
            center: point(0, -1),
            radius: 41,
            startAngle: .pi / 2,
            sweep: .pi / 2
        )
        let payload = FFCurvePayload(segments: first.segments + second.segments)

        let readings = try XCTUnwrap(FFCurveDiagnostics.joins(of: payload))
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings[0].continuity, FFCurveContinuity.g1)
        XCTAssertLessThan(readings[0].tangentAngle, 1e-9)
        XCTAssertEqual(readings[0].curvatureDifference, 1.0 / 40.0 - 1.0 / 41.0, accuracy: 1e-7)
    }

    func testAParallelButSeparatedSeamIsNotReportedAsAJoin() throws {
        let payload = FFCurvePayload(segments: [
            line(point(0, 0), point(10, 0)),
            line(point(10, 1), point(20, 1)),
        ])
        let readings = try XCTUnwrap(FFCurveDiagnostics.joins(of: payload))
        XCTAssertEqual(readings.count, 1)
        XCTAssertNil(readings[0].continuity, "parallel spans one millimetre apart are not joined")
        XCTAssertEqual(readings[0].gap, 1, accuracy: 1e-12)
        XCTAssertLessThan(readings[0].tangentAngle, 1e-12)
        XCTAssertTrue(readings[0].summary.hasPrefix("Not joined"))
    }

    // MARK: - Minimum radius

    func testMinRadiusReportsTheExactRadiusOfCirclesAndArcs() throws {
        let arc12 = try arcPayload(center: .zero, radius: 12, startAngle: 0, sweep: .pi / 2)
        let fillet = try rightAngle().treatingCorner(0, with: .fillet(radius: 2)).treatment
        let cases: [(name: String, payload: FFCurvePayload, radius: Double)] = [
            ("circle r=40", circle(radius: 40), 40),
            ("circle r=7", circle(radius: 7), 7),
            ("arc r=12", arc12, 12),
            ("fillet arc r=2", fillet, 2),
        ]

        for fixture in cases {
            let report = try XCTUnwrap(
                FFCurveDiagnostics.minRadius(of: fixture.payload),
                "\(fixture.name): the report was refused"
            )
            XCTAssertFalse(report.isStraight, "\(fixture.name)")
            XCTAssertEqual(report.spanCount, fixture.payload.segments.count)
            let tightest = try XCTUnwrap(report.tightest, "\(fixture.name): no tightest reading")
            // Same endpoint-difference budget as the comb: one part in 1e5 is
            // 0.4 micrometres at a 40 mm radius, and still catches a factor or
            // a dropped weight.
            XCTAssertEqual(
                tightest.radius,
                fixture.radius,
                accuracy: fixture.radius * 1e-5,
                "\(fixture.name): wrong minimum radius"
            )
            XCTAssertEqual(
                abs(tightest.curvature),
                1 / fixture.radius,
                accuracy: (1 / fixture.radius) * 1e-5,
                "\(fixture.name): the reading's curvature does not match its radius"
            )
        }
    }

    func testAStraightPayloadHasNoMinimumRadius() throws {
        for payload in [polyline([point(0, 0), point(10, 0)]), square()] {
            let report = try XCTUnwrap(FFCurveDiagnostics.minRadius(of: payload))
            XCTAssertNil(report.tightest)
            XCTAssertTrue(report.isStraight)
            XCTAssertEqual(report.spanCount, payload.segments.count)
            XCTAssertEqual(report.summary, "Every span is straight")
        }
    }

    func testTheCubicArchsTightestBendIsAtItsCentre() throws {
        let payload = arch()
        let report = try XCTUnwrap(FFCurveDiagnostics.minRadius(of: payload))
        let tightest = try XCTUnwrap(report.tightest)

        XCTAssertEqual(tightest.segment, 0)
        XCTAssertEqual(tightest.parameter, 0.5, accuracy: 1e-6)
        XCTAssertEqual(tightest.radius, 3.75, accuracy: 1e-6)
        XCTAssertEqual(tightest.curvature, -4.0 / 15.0, accuracy: 1e-6)
        // Finding a smooth maximum by comparing curvature values stops where
        // the difference between candidates falls below one ulp, which here is
        // about 2e-9 of parameter — that is 3e-8 mm of apex travel and no
        // further. The point is asserted to 1e-6 (0.4 micrometres on a 10 mm
        // arch), and the apex is proven geometrically instead: its tangent is
        // horizontal, which no other point of this arch satisfies.
        assertPoint(tightest.point, point(5, 7.5), accuracy: 1e-6)
        let apex = try XCTUnwrap(payload.segments[0].curve)
        let apexTangent = apex.derivative(at: tightest.parameter)
        XCTAssertEqual(apexTangent.x, 15, accuracy: 1e-6)
        XCTAssertLessThan(abs(apexTangent.y), 1e-6 * apexTangent.length)

        // Independent invariant: no sampled parameter bends tighter than the
        // reading, so the report is a genuine minimum radius and not an
        // artefact of one lucky sample.
        let curve = try XCTUnwrap(payload.segments[0].curve)
        for step in 0...200 {
            let parameter = Double(step) / 200
            let curvature = abs(
                FFCurveDiagnostics.signedCurvature(of: curve, at: parameter)
            )
            XCTAssertLessThanOrEqual(
                curvature,
                abs(tightest.curvature) + 1e-9,
                "t=\(parameter) bends tighter than the report"
            )
        }
    }

    // MARK: - Degenerate input

    func testDamagedPayloadsAreRefusedRatherThanGuessed() throws {
        let damagedSegment = FFCurveSegment(
            kind: .nurbs,
            controlPoints: [
                FFPoint2(point(0, 0)),
                FFPoint2(point(1, 0)),
                FFPoint2(point(2, 0)),
            ],
            weights: [1, 1, 1],
            degree: 2,
            knots: [0, 1]
        )
        let damaged = FFCurvePayload(segments: [damagedSegment, damagedSegment])

        XCTAssertNil(damaged.segments[0].curve, "the fixture must be invalid")
        XCTAssertNil(FFCurveDiagnostics.inflections(of: damaged))
        XCTAssertNil(FFCurveDiagnostics.joins(of: damaged))
        XCTAssertNil(FFCurveDiagnostics.minRadius(of: damaged))
    }

    func testAnEmptyPayloadHasNothingToMeasure() throws {
        let empty = FFCurvePayload(segments: [])
        XCTAssertEqual(try XCTUnwrap(FFCurveDiagnostics.inflections(of: empty)).count, 0)
        XCTAssertEqual(try XCTUnwrap(FFCurveDiagnostics.joins(of: empty)).count, 0)
        let report = try XCTUnwrap(FFCurveDiagnostics.minRadius(of: empty))
        XCTAssertNil(report.tightest)
        XCTAssertEqual(report.spanCount, 0)
        XCTAssertEqual(report.summary, "No spans")
    }

    func testTwoIdenticalReadoutsAgree() throws {
        XCTAssertEqual(
            try XCTUnwrap(FFCurveDiagnostics.inflections(of: sCurve())),
            try XCTUnwrap(FFCurveDiagnostics.inflections(of: sCurve()))
        )
        XCTAssertEqual(
            try XCTUnwrap(FFCurveDiagnostics.joins(of: circle(radius: 40))),
            try XCTUnwrap(FFCurveDiagnostics.joins(of: circle(radius: 40)))
        )
        XCTAssertEqual(
            try XCTUnwrap(FFCurveDiagnostics.minRadius(of: arch())),
            try XCTUnwrap(FFCurveDiagnostics.minRadius(of: arch()))
        )
    }
}
