import Foundation
import XCTest
@testable import FacetForge

/// Phase 45's acceptance: twenty fixtures keep their minimum distance to the
/// source inside 0.001 mm, and a folded offset never commits a self-crossing
/// curve.
///
/// The offset is a polyline in the existing curve payload, so every proof here
/// is measured against the source curve's own closest-point solver rather than
/// against a second approximation written for the test. The corner proofs use
/// closed-form geometry (a rectangle's offset perimeter, a hairpin's miter
/// length) so a regression in the join maths cannot hide inside a tolerance.
final class Phase45OffsetTests: XCTestCase {
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

    private func cubic(_ points: [Vec2]) -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(kind: .bezier, controlPoints: points.map { FFPoint2($0) }),
        ])
    }

    private func polyline(_ points: [Vec2], isClosed: Bool) -> FFCurvePayload {
        var segments: [FFCurveSegment] = []
        for index in 1..<points.count {
            segments.append(line(points[index - 1], points[index]))
        }
        if isClosed {
            segments.append(line(points[points.count - 1], points[0]))
        }
        return FFCurvePayload(segments: segments, isClosed: isClosed)
    }

    /// Four rational quadratic quarter spans: the circle Phase 41 and Phase 40
    /// already store, so the fixture exercises the same kernel path the app does.
    private func circle(radius: Double, centre: Vec2 = .zero) -> FFCurvePayload {
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
                    FFPoint2(centre + corners[index]),
                    FFPoint2(centre + mids[index]),
                    FFPoint2(centre + corners[next]),
                ],
                weights: [1, weight, 1],
                degree: 2,
                knots: [0, 0, 0, 1, 1, 1]
            ))
        }
        return FFCurvePayload(segments: segments, isClosed: true)
    }

    private func ellipse(a: Double, b: Double) -> FFCurvePayload {
        let weight = cos(Double.pi / 4)
        let corners = [
            Vec2(x: a, y: 0),
            Vec2(x: 0, y: b),
            Vec2(x: -a, y: 0),
            Vec2(x: 0, y: -b),
        ]
        let mids = [
            Vec2(x: a, y: b),
            Vec2(x: -a, y: b),
            Vec2(x: -a, y: -b),
            Vec2(x: a, y: -b),
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

    private func rectangle(width: Double, height: Double) -> FFCurvePayload {
        polyline(
            [
                point(0, 0),
                point(width, 0),
                point(width, height),
                point(0, height),
            ],
            isClosed: true
        )
    }

    /// A quarter of a circle as one rational quadratic span, open at both ends.
    private func quarterArc(radius: Double) -> FFCurvePayload {
        let weight = cos(Double.pi / 4)
        return FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(point(radius, 0)),
                    FFPoint2(point(radius, radius)),
                    FFPoint2(point(0, radius)),
                ],
                weights: [1, weight, 1],
                degree: 2,
                knots: [0, 0, 0, 1, 1, 1]
            ),
        ])
    }

    private struct OffsetRandom {
        var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        mutating func value(_ low: Double, _ high: Double) -> Double {
            low + (high - low) * unit()
        }
    }

    // MARK: - Measurement

    private func distanceToSource(_ payload: FFCurvePayload, _ query: Vec2) -> Double {
        guard let path = payload.path() else { return .infinity }
        return path.closestPoint(to: query).distance
    }

    private func vertices(_ payload: FFCurvePayload) -> [Vec2] {
        FFOffsetDiagnostics.vertices(of: payload) ?? []
    }

    private func polylineLength(_ payload: FFCurvePayload) -> Double {
        let points = vertices(payload)
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            total += points[index - 1].distance(to: points[index])
        }
        return total
    }

    /// Vertices plus chord midpoints, so the distance proof measures the drawn
    /// polyline and not only its exact vertices. The midpoints are where a
    /// tolerance-driven chord can sit inside the true offset.
    private func probes(_ payload: FFCurvePayload, stride requested: Int) -> [Vec2] {
        let points = vertices(payload)
        guard points.count >= 2 else { return [] }
        let step = max(1, requested)
        var result: [Vec2] = []
        var index = 0
        while index < points.count {
            result.append(points[index])
            if index + 1 < points.count {
                let next = points[index + 1]
                result.append((points[index] + next) * 0.5)
                result.append(points[index].lerp(to: next, t: 0.25))
                result.append(points[index].lerp(to: next, t: 0.75))
            }
            index += step
        }
        return result
    }

    // MARK: - Distance preservation (the row's first clause)

    func testTwentyFixturesPreserveTheOffsetDistance() throws {
        var fixtures: [(name: String, payload: FFCurvePayload, distance: Double)] = []

        var random = OffsetRandom(seed: 0x5EED_0045_0000_0001)
        for index in 0..<8 {
            // Draw each coordinate into a local first: one expression with two
            // mutating calls on the same generator is a needless exclusivity
            // risk for no gain.
            let firstX = random.value(25, 35)
            let firstY = random.value(-20, 20)
            let secondX = random.value(65, 75)
            let secondY = random.value(-20, 20)
            let endY = random.value(-20, 20)
            let payload = cubic([
                point(0, 0),
                Vec2(x: firstX, y: firstY),
                Vec2(x: secondX, y: secondY),
                Vec2(x: 100, y: endY),
            ])
            fixtures.append(("cubic \(index + 1)", payload, index % 2 == 0 ? 0.5 : -0.5))
        }

        fixtures.append(("circle 25 inward", circle(radius: 25), 0.5))
        fixtures.append(("circle 25 outward", circle(radius: 25), -0.5))
        fixtures.append(("circle 50 inward", circle(radius: 50), 0.5))
        fixtures.append(("circle 50 outward", circle(radius: 50), -0.5))
        fixtures.append(("ellipse inward", ellipse(a: 30, b: 20), 0.5))
        fixtures.append(("ellipse outward", ellipse(a: 30, b: 20), -0.5))
        fixtures.append(("rectangle inward", rectangle(width: 40, height: 25), 0.5))
        fixtures.append(("rectangle outward", rectangle(width: 40, height: 25), -0.5))
        fixtures.append(("quarter arc inward", quarterArc(radius: 40), 0.5))
        fixtures.append(("quarter arc outward", quarterArc(radius: 40), -0.5))
        fixtures.append((
            "open corner inward",
            polyline([point(0, 0), point(40, 0), point(40, 30)], isClosed: false),
            0.5
        ))
        fixtures.append((
            "open corner outward",
            polyline([point(0, 0), point(40, 0), point(40, 30)], isClosed: false),
            -0.5
        ))

        XCTAssertEqual(fixtures.count, 20, "the row names twenty fixtures")

        for fixture in fixtures {
            let result = try FFOffset.offset(
                fixture.payload,
                by: fixture.distance,
                corner: .round,
                tolerance: 0.0005
            )
            XCTAssertFalse(
                vertices(result.payload).isEmpty,
                "\(fixture.name) produced no vertices"
            )
            XCTAssertNotNil(
                result.payload.path(),
                "\(fixture.name) did not rebuild as one curve"
            )
            XCTAssertTrue(
                FFOffsetDiagnostics.selfIntersections(in: result.payload).isEmpty,
                "\(fixture.name) committed a self-crossing offset"
            )
            let measured = probes(result.payload, stride: max(1, vertices(result.payload).count / 12))
            for probe in measured {
                XCTAssertEqual(
                    distanceToSource(fixture.payload, probe),
                    0.5,
                    accuracy: 0.001,
                    "\(fixture.name) left the 0.5 mm band at \(probe)"
                )
            }
        }
    }

    // MARK: - Corners (round and miter)

    func testRoundAndMiterCornersMatchTheirClosedForms() throws {
        let source = rectangle(width: 40, height: 25)

        let round = try FFOffset.offset(source, by: -1, corner: .round, tolerance: 0.0005)
        let roundPoints = vertices(round.payload)
        XCTAssertGreaterThan(roundPoints.count, 8, "a rounded rectangle is not a four-point ring")
        XCTAssertEqual(round.report.cornerCount, 4, "one corner per rectangle vertex")
        XCTAssertEqual(roundPoints.map(\.x).min() ?? .nan, -1, accuracy: 1e-9)
        XCTAssertEqual(roundPoints.map(\.x).max() ?? .nan, 41, accuracy: 1e-9)
        XCTAssertEqual(roundPoints.map(\.y).min() ?? .nan, -1, accuracy: 1e-9)
        XCTAssertEqual(roundPoints.map(\.y).max() ?? .nan, 26, accuracy: 1e-9)
        // Four radius-1 quarter arcs replace the four sharp corners: the straight
        // edges are still 2·(40 + 25) and the arcs add a full circumference.
        XCTAssertEqual(polylineLength(round.payload), 130 + 2 * Double.pi, accuracy: 0.01)

        let miter = try FFOffset.offset(
            source,
            by: -1,
            corner: .miter(limit: 4),
            tolerance: 0.0005
        )
        let miterPoints = vertices(miter.payload)
        XCTAssertEqual(miter.report.cornerCount, 4)
        // A mitered 40 × 25 rectangle grows by exactly one offset distance on
        // every side, so its perimeter is 2·(42 + 27) with no arc length at all.
        XCTAssertEqual(polylineLength(miter.payload), 138, accuracy: 1e-9)
        XCTAssertTrue(
            miterPoints.contains { $0.distance(to: point(-1, -1)) < 1e-9 },
            "the miter point of the (0, 0) corner is (-1, -1)"
        )
        XCTAssertTrue(
            miterPoints.contains { $0.distance(to: point(41, 26)) < 1e-9 },
            "the miter point of the (40, 25) corner is (41, 26)"
        )
    }

    /// The miter point of a corner is the one vertex at exactly the offset
    /// distance from both legs' infinite lines. A fallback to round leaves no
    /// such vertex, which is what makes the limit observable rather than a
    /// comment.
    private func miterRadius(
        of payload: FFCurvePayload,
        vertex: Vec2,
        awayFromLeg firstLeg: Vec2,
        and secondLeg: Vec2,
        distance: Double
    ) -> Double? {
        var best: Double?
        for candidate in vertices(payload) {
            let first = abs((candidate - vertex).cross(firstLeg))
            let second = abs((candidate - vertex).cross(secondLeg))
            guard abs(first - distance) < 1e-6, abs(second - distance) < 1e-6 else {
                continue
            }
            let radius = candidate.distance(to: vertex)
            if best == nil || radius > (best ?? 0) {
                best = radius
            }
        }
        return best
    }

    func testMiterLimitFallsBackToRoundOnASharpCorner() throws {
        // A 160° turn, so the legs' interior angle is 20° and the outside miter
        // is 0.5 / sin(10°) ≈ 2.879 mm from the vertex: longer than twice the
        // offset distance, which is the limit the fallback has to catch.
        let turn = FFMath.radians(160)
        let source = polyline(
            [
                point(-50, 0),
                point(0, 0),
                Vec2(x: 50 * cos(turn), y: 50 * sin(turn)),
            ],
            isClosed: false
        )
        let firstLeg = point(-1, 0)
        let secondLeg = Vec2(x: cos(turn), y: sin(turn))
        let expectedMiter = 0.5 / sin(FFMath.radians(10))

        let limited = try FFOffset.offset(
            source,
            by: -0.5,
            corner: .miter(limit: 2),
            tolerance: 0.0005
        )
        XCTAssertNil(
            miterRadius(
                of: limited.payload,
                vertex: .zero,
                awayFromLeg: firstLeg,
                and: secondLeg,
                distance: 0.5
            ),
            "a limit of 2 must not leave a 2.879 mm miter in place"
        )

        let allowed = try FFOffset.offset(
            source,
            by: -0.5,
            corner: .miter(limit: 10),
            tolerance: 0.0005
        )
        let radius = try XCTUnwrap(
            miterRadius(
                of: allowed.payload,
                vertex: .zero,
                awayFromLeg: firstLeg,
                and: secondLeg,
                distance: 0.5
            ),
            "a limit of 10 must keep the miter"
        )
        XCTAssertEqual(radius, expectedMiter, accuracy: 1e-6)
    }

    // MARK: - Spike cleanup (the row's second clause)

    /// The loop remover is the step that makes a folded offset committable at
    /// all, so it is exercised on a shape that crosses by construction rather
    /// than only through a fixture whose fold depends on sampling density.
    func testTheLoopRemoverSplicesASelfCrossingPolyline() {
        let bowTie = [
            point(0, 0),
            point(10, 10),
            point(10, 0),
            point(0, 10),
        ]
        XCTAssertEqual(
            FFOffsetDiagnostics.selfIntersections(in: bowTie, isClosed: false).count,
            1,
            "the scanner must see the one crossing before the remover runs"
        )

        let cleaned = FFOffset.removingLoops(bowTie)
        XCTAssertGreaterThan(cleaned.removals, 0)
        XCTAssertTrue(
            FFOffsetDiagnostics.selfIntersections(in: cleaned.points, isClosed: false).isEmpty,
            "the spliced polyline still crosses"
        )
        XCTAssertGreaterThanOrEqual(cleaned.points.count, 2)
    }

    func testTheSelfIntersectionScannerFindsABowTie() {
        let teeth = polyline(
            [point(0, 0), point(10, 10), point(10, 0), point(0, 10)],
            isClosed: false
        )
        XCTAssertEqual(FFOffsetDiagnostics.selfIntersections(in: teeth).count, 1)

        let clean = polyline([point(0, 0), point(10, 0), point(10, 10)], isClosed: false)
        XCTAssertTrue(FFOffsetDiagnostics.selfIntersections(in: clean).isEmpty)
    }

    /// Whatever a folded input does, the app never receives a curve that crosses
    /// itself: the operation either commits a clean offset or refuses with a
    /// sentence. The thin U is narrower than the offset distance, so its inside
    /// offset has no valid boundary left at all.
    func testFoldedOffsetsCommitCleanlyOrRefuseWithASentence() throws {
        let thinU = polyline(
            [point(0, 0), point(10, 0), point(10, 1), point(0, 1)],
            isClosed: false
        )
        let tightCircle = circle(radius: 10)
        let shortHairpin = polyline(
            [
                point(-3, 0),
                point(0, 0),
                Vec2(
                    x: 3 * cos(FFMath.radians(150)),
                    y: 3 * sin(FFMath.radians(150))
                ),
            ],
            isClosed: false
        )

        let folded: [(name: String, payload: FFCurvePayload, distance: Double)] = [
            ("thin U", thinU, 2),
            ("tight circle", tightCircle, 12),
            ("short hairpin", shortHairpin, 2),
        ]

        for fixture in folded {
            do {
                let result = try FFOffset.offset(
                    fixture.payload,
                    by: fixture.distance,
                    corner: .round,
                    tolerance: 0.0005
                )
                XCTAssertTrue(
                    FFOffsetDiagnostics.selfIntersections(in: result.payload).isEmpty,
                    "\(fixture.name) committed a self-crossing offset"
                )
                XCTAssertNotNil(
                    result.payload.path(),
                    "\(fixture.name) committed a curve that does not rebuild"
                )
                XCTAssertGreaterThan(
                    result.report.pointCount,
                    1,
                    "\(fixture.name) committed a degenerate polyline"
                )
            } catch let error as FFOffsetError {
                XCTAssertNotNil(
                    error.errorDescription,
                    "\(fixture.name) refused without a sentence"
                )
            } catch {
                XCTFail("\(fixture.name) threw a non-offset error: \(error)")
            }
        }
    }

    func testAnInwardOffsetPastTheRadiusCollapsesInsteadOfInverting() {
        XCTAssertThrowsError(
            try FFOffset.offset(circle(radius: 10), by: 12, tolerance: 0.0005)
        ) { error in
            guard let offset = error as? FFOffsetError else {
                return XCTFail("expected an offset refusal, got \(error)")
            }
            XCTAssertEqual(offset, .collapsedOffset)
        }
    }

    // MARK: - Tolerance

    func testToleranceBoundsTheChordDeviationFromTheTrueOffset() throws {
        let source = circle(radius: 25)
        let tolerances = [0.002, 0.0005, 0.0001]
        var pointCounts: [Int] = []

        for tolerance in tolerances {
            let result = try FFOffset.offset(source, by: 0.5, tolerance: tolerance)
            let points = vertices(result.payload)
            pointCounts.append(result.report.pointCount)

            // Vertices are exact offset points, so they sit on the 24.5 mm
            // radius to rounding; the chords between them are what the
            // tolerance governs.
            for candidate in points {
                XCTAssertEqual(candidate.length, 24.5, accuracy: 1e-9)
            }
            XCTAssertGreaterThan(points.count, 2)
            for index in 1..<points.count {
                let midpoint = (points[index - 1] + points[index]) * 0.5
                XCTAssertLessThanOrEqual(
                    abs(midpoint.length - 24.5),
                    tolerance + 1e-9,
                    "a chord of the \(tolerance) mm offset sits off the true radius"
                )
            }
        }

        XCTAssertGreaterThanOrEqual(pointCounts[1], pointCounts[0])
        XCTAssertGreaterThanOrEqual(pointCounts[2], pointCounts[1])
    }

    // MARK: - Closed and open results

    func testClosedInputStaysClosedAndOpenInputStaysOpen() throws {
        let ring = try FFOffset.offset(circle(radius: 25), by: 0.5, tolerance: 0.0005)
        XCTAssertTrue(ring.payload.isClosed)
        XCTAssertTrue(try XCTUnwrap(ring.payload.path()).isClosed())
        XCTAssertEqual(polylineLength(ring.payload), 2 * Double.pi * 24.5, accuracy: 0.01)

        let arc = try FFOffset.offset(quarterArc(radius: 40), by: 0.5, tolerance: 0.0005)
        XCTAssertFalse(arc.payload.isClosed)
        XCTAssertFalse(try XCTUnwrap(arc.payload.path()).isClosed())
    }

    // MARK: - Session ownership

    private func makeSession() -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 45")
        let node = FFNode(
            name: "Offset source",
            geometry: .curve(cubic([
                point(0, 0),
                point(20, 30),
                point(60, 30),
                point(80, 0),
            ])),
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        return (FFEditorSession(document: document), node.id)
    }

    func testOffsetCommandIsOneUndoAndOneNewNode() throws {
        let (session, nodeID) = makeSession()
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        let created = try XCTUnwrap(session.offsetCurve(nodeID: nodeID, by: 0.5))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertEqual(session.document.rootNodes.count, 2)
        XCTAssertNotEqual(created, nodeID)
        XCTAssertEqual(session.selection.selectedIDs, Set([created]))
        XCTAssertNotNil(session.lastOffsetReport)
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            original,
            "the source curve must not move"
        )

        let offsetPayload = try XCTUnwrap(session.document.curvePayload(forNodeID: created))
        XCTAssertFalse(offsetPayload.isClosed)
        XCTAssertNotNil(offsetPayload.path())

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes.count, 1)
        XCTAssertNil(session.document.node(withID: created))
        XCTAssertEqual(session.documentSession.undoDepth, 0)
    }

    func testOffsetRefusalsExplainThemselvesAndCreateNoHistory() throws {
        let (session, nodeID) = makeSession()

        XCTAssertNil(session.offsetCurve(nodeID: nodeID, by: 0))
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertTrue(
            (session.curveEditMessage ?? "").hasPrefix("An offset needs a finite, non-zero distance")
        )

        XCTAssertNil(session.offsetCurve(nodeID: nodeID, by: 0.5, tolerance: 0))
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertTrue(
            (session.curveEditMessage ?? "").hasPrefix("An offset tolerance must be finite")
        )

        var lockedDocument = FFDocument(name: "Phase 45 locked")
        lockedDocument.layers[0].isLocked = true
        let lockedNode = FFNode(
            name: "Locked source",
            geometry: .curve(cubic([
                point(0, 0),
                point(20, 30),
                point(60, 30),
                point(80, 0),
            ])),
            layerID: lockedDocument.currentLayerID
        )
        lockedDocument.rootNodes = [lockedNode]
        let lockedSession = FFEditorSession(document: lockedDocument)
        XCTAssertNil(lockedSession.offsetCurve(nodeID: lockedNode.id, by: 0.5))
        XCTAssertEqual(lockedSession.documentSession.undoDepth, 0)
        XCTAssertEqual(lockedSession.curveEditMessage, "That curve is on a locked layer")

        var grouped = FFDocument(name: "Phase 45 group")
        let group = FFNode(name: "Empty group", layerID: grouped.currentLayerID)
        grouped.rootNodes = [group]
        let groupSession = FFEditorSession(document: grouped)
        XCTAssertNil(groupSession.offsetCurve(nodeID: group.id, by: 0.5))
        XCTAssertEqual(groupSession.documentSession.undoDepth, 0)
        XCTAssertEqual(
            groupSession.curveEditMessage,
            "Select a curve before editing its control points"
        )
    }

    func testAnOffsetCurveSurvivesSaveAndReopen() throws {
        let (session, nodeID) = makeSession()
        let created = try XCTUnwrap(session.offsetCurve(nodeID: nodeID, by: -0.5))
        let committed = try XCTUnwrap(session.document.curvePayload(forNodeID: created))

        let data = try JSONEncoder().encode(session.document)
        let reopened = try JSONDecoder().decode(FFDocument.self, from: data)
        let decoded = try XCTUnwrap(reopened.curvePayload(forNodeID: created))

        XCTAssertEqual(decoded.fingerprint, committed.fingerprint)
        XCTAssertEqual(decoded.segments.count, committed.segments.count)
        XCTAssertNotNil(decoded.path())
        XCTAssertEqual(
            decoded.segments.count,
            max(0, (FFOffsetDiagnostics.vertices(of: decoded)?.count ?? 1) - 1),
            "a polyline payload keeps one two-point span per vertex pair"
        )
    }
}
