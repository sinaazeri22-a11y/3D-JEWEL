import Foundation
import XCTest
@testable import FacetForge

/// Phase 48's acceptance: a projection round-trips to far inside the 1e-5 mm
/// budget, and the section of the revolved ring body matches the circles its
/// profile predicts.
///
/// The fixtures are analytic before the code runs: the ring is the demo scene's
/// torus (major 30, minor 4.5, the shipping dimensions), so a plane through its
/// mid-plane cuts the annulus at radii 25.5 and 34.5, a plane at height 2.7 cuts
/// 30 +/- 3.6, and a plane through the axis cuts the tube circle twice. A cylinder's crossings are at its
/// radius exactly, and a quadratic that touches a plane without crossing it must
/// report nothing. None of these numbers come from the implementation.
final class Phase48ProjectionTests: XCTestCase {
    // MARK: - Fixtures

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    private func point3(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
        Vec3(x: x, y: y, z: z)
    }

    private func line(_ start: Vec2, _ end: Vec2) -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(start), FFPoint2(end)]
            ),
        ])
    }

    /// The exact four-span rational quadratic the arc tool writes for a full
    /// turn, so the fixtures use the app's own encoding rather than a sampled
    /// circle.
    private func circle(_ center: Vec2, radius: Double) throws -> FFCurvePayload {
        let arc = try FFArc2D(
            center: center,
            radius: radius,
            startAngle: 0,
            sweep: FFArc2D.fullTurn
        )
        return FFArcTool.payload(for: arc)
    }

    /// The revolved ring body: a 4.5 mm tube whose centre circle is 30 mm from
    /// the Y axis, which is exactly the demo scene's torus.
    private func ringSurface() throws -> FFRevolutionSurface {
        let profile = FFSpatialCurve(
            payload: try circle(point(30, 0), radius: 4.5),
            plane: .ground
        )
        return try FFRevolutionSurface(axisOrigin: .zero, axis: .unitY, profile: profile)
    }

    /// A cylinder of radius 10 between y = -5 and y = 5, whose profile is one
    /// straight span and therefore single-sheeted.
    private func cylinderSurface() -> FFRevolutionSurface? {
        let profile = FFSpatialCurve(
            payload: line(point(10, -5), point(10, 5)),
            plane: .ground
        )
        return try? FFRevolutionSurface(axisOrigin: .zero, axis: .unitY, profile: profile)
    }

    private func plane(
        _ origin: Vec3,
        _ normal: Vec3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> FFPlane3D {
        try XCTUnwrap(FFPlane3D(origin: origin, normal: normal), file: file, line: line)
    }

    /// The distance from a point to the Y axis, which is the radial distance the
    /// ring's sections are measured against.
    private func radial(_ point: Vec3) -> Double {
        (point.x * point.x + point.z * point.z).squareRoot()
    }

    private func assertPoint(
        _ actual: Vec3,
        _ expected: Vec3,
        accuracy: Double = 1e-9,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Planes

    func testAPlaneRoundTripsItsOwnCoordinates() throws {
        let tilted = try plane(point3(1, 2, 3), point3(1, 1, 0))
        let probes = [
            point3(0, 0, 0),
            point3(5, -7, 11),
            point3(-3.25, 0.5, 9.75),
            point3(1, 2, 3),
        ]
        for probe in probes {
            let onPlane = tilted.project(probe)
            XCTAssertTrue(tilted.contains(onPlane, tolerance: 1e-12), "the projection must lie on the plane")
            let rebuilt = tilted.embed(tilted.coordinates(of: onPlane))
            assertPoint(rebuilt, onPlane, accuracy: 1e-12, "embed must invert coordinates")
            XCTAssertEqual(
                onPlane.distance(to: probe),
                abs(tilted.signedDistance(of: probe)),
                accuracy: 1e-12,
                "the projection must move only along the normal"
            )
        }
    }

    func testTheGroundPlaneFlattensHeightOnly() throws {
        let folded = FFPlane3D.ground.project(point3(3, 4, 7))
        assertPoint(folded, point3(3, 4, 0), accuracy: 1e-12)
        let coordinates = FFPlane3D.ground.coordinates(of: point3(3, 4, 7))
        XCTAssertEqual(coordinates.x, 3, accuracy: 1e-12)
        XCTAssertEqual(coordinates.y, 4, accuracy: 1e-12)
        XCTAssertEqual(FFPlane3D.ground.signedDistance(of: point3(0, 0, 7)), 7, accuracy: 1e-12)
    }

    // MARK: - Projection onto a plane

    func testProjectingACurveAlreadyInThePlaneChangesNothing() throws {
        let curve = FFSpatialCurve(payload: try circle(point(0, 0), radius: 12), plane: .ground)
        let projected = try XCTUnwrap(curve.projected(onto: .ground))
        XCTAssertEqual(projected.payload.fingerprint, curve.payload.fingerprint)
        XCTAssertEqual(projected.payload.segments.count, 4)
        XCTAssertTrue(projected.payload.isClosed)
    }

    func testProjectingToAParallelPlaneKeepsThePayloadExactly() throws {
        let target = try XCTUnwrap(
            FFPlane3D(origin: point3(0, 0, 5), xAxis: .unitX, yAxis: .unitY)
        )
        let curve = FFSpatialCurve(payload: try circle(point(0, 0), radius: 7), plane: .ground)
        let projected = try XCTUnwrap(curve.projected(onto: target))
        XCTAssertEqual(
            projected.payload.fingerprint,
            curve.payload.fingerprint,
            "sliding a curve along the normal leaves its own coordinates untouched"
        )
        for step in 0...16 {
            let u = Double(step) / 2
            let moved = try XCTUnwrap(projected.point(atGlobal: u))
            XCTAssertEqual(moved.z, 5, accuracy: 1e-12)
        }
    }

    func testProjectionIsOrthogonalAtEverySample() throws {
        let tilted = try plane(point3(1, 2, 3), point3(1, 1, 0))
        let curve = FFSpatialCurve(payload: try circle(point(0, 0), radius: 9), plane: .ground)
        let projected = try XCTUnwrap(curve.projected(onto: tilted))

        for step in 0...64 {
            let u = Double(step) / 16
            let first = try XCTUnwrap(curve.point(atGlobal: u))
            let second = try XCTUnwrap(projected.point(atGlobal: u))
            assertPoint(second, tilted.project(first), accuracy: 1e-12, "u = \(u)")
            XCTAssertTrue(tilted.contains(second, tolerance: 1e-12), "u = \(u)")
        }
    }

    func testProjectingTwiceChangesNothing() throws {
        let tilted = try plane(point3(-2, 0, 4), point3(1, -2, 1))
        let curve = FFSpatialCurve(payload: try circle(point(3, 1), radius: 6), plane: .ground)
        let once = try XCTUnwrap(curve.projected(onto: tilted))
        let twice = try XCTUnwrap(once.projected(onto: tilted))

        for step in 0...32 {
            let u = Double(step) / 8
            assertPoint(
                try XCTUnwrap(twice.point(atGlobal: u)),
                try XCTUnwrap(once.point(atGlobal: u)),
                accuracy: 1e-12,
                "u = \(u)"
            )
        }
    }

    /// The row's acceptance is a round-trip under 1e-5 mm; an affine pair is
    /// exact to arithmetic noise, so the same measurement also proves the tighter
    /// claim that nothing is refitted.
    func testProjectionRoundTripStaysInsideTheRowsBudget() throws {
        let tilted = try plane(point3(-4, 3, 2), point3(1, 2, -1))
        let curve = FFSpatialCurve(payload: try circle(point(2, -1), radius: 11), plane: .ground)
        let there = try XCTUnwrap(curve.projected(onto: tilted))
        let back = try XCTUnwrap(there.projected(onto: .ground))

        var worst = 0.0
        for step in 0...256 {
            let u = Double(step) / 64
            let before = try XCTUnwrap(curve.point(atGlobal: u))
            let after = try XCTUnwrap(back.point(atGlobal: u))
            worst = max(worst, before.distance(to: after))
        }
        XCTAssertLessThan(worst, 1e-5, "the row's budget is 1e-5 mm")
        XCTAssertLessThan(worst, 1e-9, "an affine round trip is exact to arithmetic noise")
    }

    func testProjectionPreservesWeightsDegreeAndKnots() throws {
        let tilted = try plane(point3(0, 0, 0), point3(0, 0, 1))
        let curve = FFSpatialCurve(payload: try circle(point(0, 0), radius: 5), plane: .ground)
        let projected = try XCTUnwrap(curve.projected(onto: tilted))

        XCTAssertEqual(projected.payload.segments.count, curve.payload.segments.count)
        for (before, after) in zip(curve.payload.segments, projected.payload.segments) {
            XCTAssertEqual(after.weights, before.weights)
            XCTAssertEqual(after.degree, before.degree)
            XCTAssertEqual(after.knots, before.knots)
            XCTAssertEqual(after.kind, before.kind)
        }
    }

    func testProjectionRefusesADamagedPayload() throws {
        let damaged = FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(point(0, 0)),
                    FFPoint2(point(1, 0)),
                    FFPoint2(point(2, 0)),
                ],
                weights: [1, 1, 1],
                degree: 2,
                knots: [0, 1]
            ),
        ])
        let curve = FFSpatialCurve(payload: damaged, plane: .ground)
        XCTAssertNil(curve.projected(onto: .ground))
        XCTAssertNil(curve.crossings(with: .ground, samplesPerSegment: 16))
    }

    // MARK: - Curve and plane

    func testLineCrossingsAreExact() throws {
        let curve = FFSpatialCurve(payload: line(point(-10, 0), point(10, 0)), plane: .ground)
        let plane = try plane(point3(3, 0, 0), .unitX)
        let crossings = try XCTUnwrap(curve.crossings(with: plane))

        XCTAssertEqual(crossings.count, 1)
        let crossing = try XCTUnwrap(crossings.first)
        XCTAssertEqual(crossing.segment, 0)
        XCTAssertEqual(crossing.parameter, 0.65, accuracy: 1e-9)
        assertPoint(crossing.point, point3(3, 0, 0))
        XCTAssertTrue(crossing.summary.hasPrefix("Crossing"))
    }

    func testACurveThatOnlyTouchesThePlaneReportsNoCrossing() throws {
        // y(t) = 10 (1 - t)^2 + 10 t^2 has its minimum exactly 5 at t = 0.5, so
        // the plane y = 5 is tangent to it and nothing passes through.
        let touching = FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(point(0, 10)), FFPoint2(point(10, 0)), FFPoint2(point(20, 10))]
            ),
        ])
        let curve = FFSpatialCurve(payload: touching, plane: .ground)
        let plane = try plane(point3(0, 5, 0), .unitY)
        XCTAssertEqual(try XCTUnwrap(curve.crossings(with: plane)).count, 0)
    }

    func testACurveLyingInThePlaneReportsNoCrossing() throws {
        let curve = FFSpatialCurve(payload: try circle(point(0, 0), radius: 5), plane: .ground)
        XCTAssertEqual(try XCTUnwrap(curve.crossings(with: .ground)).count, 0)
    }

    // MARK: - Ring sections

    func testRingSectionAtTheMidPlaneIsAnAnnulus() throws {
        let surface = try ringSurface()
        let midPlane = try plane(.zero, .unitY)
        let sections = try surface.section(by: midPlane)

        XCTAssertEqual(sections.count, 2, "the mid-plane cuts an inner and an outer circle")
        var radii: [Double] = []
        for section in sections {
            XCTAssertTrue(section.payload.isClosed)
            XCTAssertEqual(section.payload.segments.count, 4, "a circle stays four exact spans")
            for step in 0...64 {
                let point = try XCTUnwrap(section.point(atGlobal: Double(step) / 16))
                XCTAssertEqual(point.y, 0, accuracy: 1e-12, "the section stays in its plane")
                radii.append(radial(point))
            }
        }
        let low = try XCTUnwrap(radii.min())
        let high = try XCTUnwrap(radii.max())
        XCTAssertEqual(low, 25.5, accuracy: 1e-9, "inner radius is major - minor")
        XCTAssertEqual(high, 34.5, accuracy: 1e-9, "outer radius is major + minor")
        for radius in radii {
            XCTAssertTrue(
                abs(radius - 25.5) <= 1e-9 || abs(radius - 34.5) <= 1e-9,
                "every section point sits on one of the two circles, not between them"
            )
        }
    }

    func testRingSectionAtHeightTwoPointSevenUsesTheProfileRoots() throws {
        let surface = try ringSurface()
        let plane = try plane(point3(0, 2.7, 0), .unitY)
        let sections = try surface.section(by: plane)
        XCTAssertEqual(sections.count, 2)

        var radii: [Double] = []
        for section in sections {
            for step in 0...32 {
                let point = try XCTUnwrap(section.point(atGlobal: Double(step) / 8))
                XCTAssertEqual(point.y, 2.7, accuracy: 1e-12)
                radii.append(radial(point))
            }
        }
        // sin(phi) = 0.6, so cos(phi) = 0.8 and the tube's radius there is
        // 4.5 * 0.8 = 3.6 exactly; the height is 4.5 * 0.6 = 2.7.
        XCTAssertEqual(try XCTUnwrap(radii.min()), 30 - 3.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(radii.max()), 30 + 3.6, accuracy: 1e-9)
    }

    func testSectionThroughTheAxisIsTheProfileAndItsOpposite() throws {
        let surface = try ringSurface()
        let sections = try surface.section(by: .ground)
        XCTAssertEqual(sections.count, 2, "a plane through the axis cuts both walls")

        // A full circle's mean point is its centre, so averaging the samples
        // measures where each section's tube sits without asking the section
        // where it put itself.
        var centres: [Vec3] = []
        for section in sections {
            XCTAssertTrue(section.payload.isClosed)
            var sum = Vec3.zero
            for step in 0..<64 {
                let point = try XCTUnwrap(section.point(atGlobal: Double(step) / 16))
                XCTAssertEqual(point.z, 0, accuracy: 1e-12)
                sum = sum + point
            }
            centres.append(sum / 64)
        }
        let xs = centres.map { $0.x }.sorted()
        XCTAssertEqual(xs[0], -30, accuracy: 1e-9, "the opposite wall is the profile turned half a turn")
        XCTAssertEqual(xs[1], 30, accuracy: 1e-9)

        for (section, centre) in zip(sections, centres) {
            for step in 0...32 {
                let point = try XCTUnwrap(section.point(atGlobal: Double(step) / 8))
                XCTAssertEqual(point.distance(to: centre), 4.5, accuracy: 1e-9, "the tube radius")
            }
        }
    }

    func testASectionPlaneFromNeitherFamilyIsRefused() throws {
        let surface = try ringSurface()
        let wall = try plane(point3(0, 0, 5), .unitZ)
        XCTAssertThrowsError(try surface.section(by: wall)) { error in
            XCTAssertEqual(error as? FFRevolutionError, .unsupportedSectionPlane)
        }
    }

    func testASectionPlaneThatMissesTheBodyReturnsNothing() throws {
        let surface = try ringSurface()
        let above = try plane(point3(0, 10, 0), .unitY)
        XCTAssertEqual(try surface.section(by: above).count, 0)
    }

    func testTheShippingRingBodyIsTheSameSurface() throws {
        let body = try XCTUnwrap(
            FFMeshFactory.torus(majorRadius: 30, minorRadius: 4.5, majorSegments: 72, minorSegments: 36)
        )
        var sectionRadii: [Double] = []
        for position in body.positions {
            let rho = radial(position)
            XCTAssertEqual(
                (rho - 30) * (rho - 30) + position.y * position.y,
                20.25,
                accuracy: 1e-12,
                "every vertex of the shipping ring lies on the revolved tube"
            )
            if abs(position.y) <= 1e-12 {
                sectionRadii.append(rho)
            }
        }
        XCTAssertFalse(sectionRadii.isEmpty)
        for radius in sectionRadii {
            XCTAssertTrue(abs(radius - 25.5) <= 1e-12 || abs(radius - 34.5) <= 1e-12)
        }
        XCTAssertTrue(sectionRadii.contains { abs($0 - 25.5) <= 1e-12 })
        XCTAssertTrue(sectionRadii.contains { abs($0 - 34.5) <= 1e-12 })

        let surface = try ringSurface()
        let sections = try surface.section(by: try plane(.zero, .unitY))
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(
            sectionRadii.count,
            2 * 72,
            "each major segment contributes one point on each wall at y = 0"
        )
    }

    // MARK: - Projection onto the ring

    func testProjectingOntoTheRingSurfaceLandsOnTheSurface() throws {
        let surface = try ringSurface()
        let vertical = try XCTUnwrap(FFPlane3D(origin: point3(10, 0, 0), normal: .unitX))
        let source = FFSpatialCurve(payload: line(point(0, -2), point(0, 2)), plane: vertical)

        let projected = try XCTUnwrap(surface.projected(source))
        XCTAssertGreaterThanOrEqual(projected.points.count, 2)
        XCTAssertFalse(projected.isClosed)
        for point in projected.points {
            let rho = radial(point)
            XCTAssertEqual(
                (rho - 30) * (rho - 30) + point.y * point.y,
                20.25,
                accuracy: 1e-9,
                "a projected point must lie on the ring's surface"
            )
            XCTAssertGreaterThanOrEqual(point.y, -2 - 1e-12)
            XCTAssertLessThanOrEqual(point.y, 2 + 1e-12)
            XCTAssertEqual(point.x, rho, accuracy: 1e-12)
        }
        let first = try XCTUnwrap(projected.points.first)
        let last = try XCTUnwrap(projected.points.last)
        XCTAssertEqual(first.y, -2, accuracy: 1e-12)
        XCTAssertEqual(last.y, 2, accuracy: 1e-12)
    }

    func testAProfileOnTheFarSideOfTheAxisRevolvesTheSameWay() throws {
        // A cylinder whose profile sits on -X: the surface must pass through
        // the profile at angle zero instead of mirroring it to +X.
        let profile = FFSpatialCurve(
            payload: line(point(-10, -5), point(-10, 5)),
            plane: .ground
        )
        let surface = try FFRevolutionSurface(axisOrigin: .zero, axis: .unitY, profile: profile)
        XCTAssertEqual(surface.radialAxis.x, -1, accuracy: 1e-12)
        assertPoint(try XCTUnwrap(surface.point(atParameter: 0, around: 0)), point3(-10, -5, 0))
        assertPoint(try XCTUnwrap(surface.point(atParameter: 1, around: 0)), point3(-10, 5, 0))

        let crossings = try surface.crossings(of: FFSpatialCurve(
            payload: line(point(-20, 0), point(20, 0)),
            plane: .ground
        ))
        XCTAssertEqual(crossings.count, 2)
        assertPoint(crossings[0].point, point3(-10, 0, 0))
        assertPoint(crossings[1].point, point3(10, 0, 0))
    }

    func testAProfileThatCrossesTheAxisIsRefused() throws {
        let straddling = FFSpatialCurve(
            payload: line(point(-5, -5), point(5, 5)),
            plane: .ground
        )
        XCTAssertThrowsError(
            try FFRevolutionSurface(axisOrigin: .zero, axis: .unitY, profile: straddling)
        ) { error in
            XCTAssertEqual(error as? FFRevolutionError, .profileCrossesAxis)
        }
    }

    func testProjectingOutsideTheSurfaceExtentIsRefused() throws {
        let surface = try ringSurface()
        let vertical = try XCTUnwrap(FFPlane3D(origin: point3(10, 0, 0), normal: .unitX))
        let outside = FFSpatialCurve(payload: line(point(0, 5), point(0, 6)), plane: vertical)
        XCTAssertNil(surface.projected(outside), "the tube has no surface at y = 5")
    }

    // MARK: - Curve and surface

    func testCurveSurfaceCrossingsOnACylinderAreExact() throws {
        let surface = try XCTUnwrap(cylinderSurface())
        XCTAssertTrue(surface.isSingleSheet)
        let curve = FFSpatialCurve(payload: line(point(-20, 0), point(20, 0)), plane: .ground)
        let crossings = try surface.crossings(of: curve)

        XCTAssertEqual(crossings.count, 2)
        XCTAssertEqual(crossings[0].parameter, 0.25, accuracy: 1e-9)
        XCTAssertEqual(crossings[1].parameter, 0.75, accuracy: 1e-9)
        assertPoint(crossings[0].point, point3(-10, 0, 0))
        assertPoint(crossings[1].point, point3(10, 0, 0))
    }

    func testCurveSurfaceCrossingsRefuseAMultiSheetProfile() throws {
        let surface = try ringSurface()
        XCTAssertFalse(surface.isSingleSheet)
        let curve = FFSpatialCurve(payload: line(point(-30, 0), point(30, 0)), plane: .ground)
        XCTAssertThrowsError(try surface.crossings(of: curve)) { error in
            XCTAssertEqual(error as? FFRevolutionError, .multiSheetProfile)
        }
    }

    // MARK: - Determinism and refusals

    func testTwoIdenticalSectionsAndProjectionsAgree() throws {
        let surface = try ringSurface()
        let midPlane = try plane(.zero, .unitY)
        XCTAssertEqual(try surface.section(by: midPlane), try surface.section(by: midPlane))

        let vertical = try XCTUnwrap(FFPlane3D(origin: point3(10, 0, 0), normal: .unitX))
        let source = FFSpatialCurve(payload: line(point(0, -1), point(0, 1)), plane: vertical)
        XCTAssertEqual(try surface.projected(source), try surface.projected(source))
    }

    func testASurfaceRefusesAProfileOffItsAxis() throws {
        let offAxis = FFSpatialCurve(
            payload: line(point(5, -2), point(5, 2)),
            plane: .ground
        )
        XCTAssertThrowsError(
            try FFRevolutionSurface(axisOrigin: .zero, axis: .unitZ, profile: offAxis)
        ) { error in
            XCTAssertEqual(error as? FFRevolutionError, .profileOffAxis)
        }

        let flat = FFSpatialCurve(payload: line(point(5, 0), point(9, 0)), plane: .ground)
        XCTAssertThrowsError(
            try FFRevolutionSurface(axisOrigin: .zero, axis: .unitY, profile: flat)
        ) { error in
            XCTAssertEqual(error as? FFRevolutionError, .flatProfile)
        }
    }
}
