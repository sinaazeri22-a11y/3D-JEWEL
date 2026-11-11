import Foundation
import XCTest
@testable import FacetForge

/// Phase 46's acceptance: a fillet's tangency error stays under one micrometre,
/// and a radius larger than the leg it has to fit is refused with a sentence
/// that names both numbers instead of producing a broken curve.
///
/// Every proof here is measured against closed-form geometry the test computes
/// from the fixture's own raw points — the analytic arc centre, the tangent
/// length `radius / tan(interior / 2)`, the exact path-length balance — rather
/// than against the implementation's own notion of the answer. The encoding
/// under claim is the exact rational quadratic arc `FFArcTool` already writes,
/// so sampling it must land on that circle to within rounding, not merely near
/// it.
final class Phase46CornerTests: XCTestCase {
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

    /// One corner with two straight legs. `previous` and `next` are the far ends
    /// of the legs, so the fixture's own points are the whole input.
    private func corner(previous: Vec2, vertex: Vec2, next: Vec2) -> FFCurvePayload {
        polyline([previous, vertex, next])
    }

    /// The right angle at (10, 0), with ten millimetres of leg on each side.
    private func rightAngle() -> FFCurvePayload {
        corner(previous: point(0, 0), vertex: point(10, 0), next: point(10, 10))
    }

    // MARK: - Hand-computed helpers

    private func unit(_ vector: Vec2) -> Vec2 {
        guard let normalised = vector.normalized() else {
            XCTFail("the fixture produced a zero-length direction")
            return Vec2(x: 0, y: 0)
        }
        return normalised
    }

    /// The interior angle without `acos`: `atan2(|cross|, dot)` is the same
    /// angle through a different formula, so a shared mistake is less likely.
    private func interiorAngle(previous: Vec2, vertex: Vec2, next: Vec2) -> Double {
        let arriving = unit(vertex - previous)
        let leaving = unit(next - vertex)
        let reversed = Vec2(x: -arriving.x, y: -arriving.y)
        return atan2(abs(reversed.cross(leaving)), reversed.dot(leaving))
    }

    /// The circle a fillet of `radius` must be: its centre lies on the interior
    /// bisector at `radius / sin(interior / 2)` from the vertex.
    private func expectedCentre(
        previous: Vec2,
        vertex: Vec2,
        next: Vec2,
        radius: Double
    ) -> Vec2 {
        let arriving = unit(vertex - previous)
        let leaving = unit(next - vertex)
        let bisector = unit(Vec2(x: -arriving.x + leaving.x, y: -arriving.y + leaving.y))
        let angle = interiorAngle(previous: previous, vertex: vertex, next: next)
        return vertex + bisector * (radius / sin(angle / 2))
    }

    private func expectedTangentLength(
        previous: Vec2,
        vertex: Vec2,
        next: Vec2,
        radius: Double
    ) -> Double {
        radius / tan(interiorAngle(previous: previous, vertex: vertex, next: next) / 2)
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

    private func samples(of payload: FFCurvePayload, perSpan: Int = 8) -> [Vec2] {
        var result: [Vec2] = []
        for segment in payload.segments {
            guard let curve = segment.curve else { continue }
            for index in 0...perSpan {
                result.append(curve.point(at: Double(index) / Double(perSpan)))
            }
        }
        return result
    }

    private func totalLength(_ payload: FFCurvePayload) -> Double {
        payload.segments.reduce(0) { sum, segment in
            sum + (segment.curve?.arcLength(tolerance: 1e-10) ?? .nan)
        }
    }

    private func unitTangent(of payload: FFCurvePayload, atStart: Bool) -> Vec2? {
        let segment = atStart ? payload.segments.first : payload.segments.last
        guard let curve = segment?.curve else { return nil }
        return curve.derivative(at: atStart ? 0 : 1).normalized()
    }

    /// Every join, including the wrap on a closed path, measured as the gap
    /// between the end of one span and the start of the next.
    private func joins(_ payload: FFCurvePayload) -> [Double] {
        guard payload.segments.count >= 2 else { return [] }
        var result: [Double] = []
        for index in 0..<(payload.segments.count - 1) {
            guard let first = payload.segments[index].curve,
                  let second = payload.segments[index + 1].curve
            else { return [.infinity] }
            result.append(first.end.distance(to: second.start))
        }
        if payload.isClosed,
           let last = payload.segments.last?.curve,
           let first = payload.segments.first?.curve {
            result.append(last.end.distance(to: first.start))
        }
        return result
    }

    private func refusal(
        _ payload: FFCurvePayload,
        corner: Int,
        treatment: FFCornerTreatment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FFCornerError? {
        do {
            _ = try payload.treatingCorner(corner, with: treatment)
            XCTFail("the treatment should have been refused", file: file, line: line)
            return nil
        } catch let error as FFCornerError {
            return error
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Fillet geometry

    func testRightAngleFilletIsTangentAndPreservesTheLegs() throws {
        let payload = rightAngle()
        let outcome = try payload.treatingCorner(0, with: .fillet(radius: 2))

        // A right angle needs exactly the radius of leg on each side.
        XCTAssertEqual(outcome.report.tangentLength, 2, accuracy: 1e-12)
        XCTAssertEqual(outcome.report.treatmentSpanCount, 1)
        XCTAssertEqual(outcome.report.corner, 0)
        XCTAssertEqual(outcome.report.label, "Fillet")

        // Two shortened legs and one arc, in path order.
        XCTAssertEqual(outcome.payload.segments.count, 3)
        let incoming = try XCTUnwrap(outcome.payload.segments[0].curve)
        let outgoing = try XCTUnwrap(outcome.payload.segments[2].curve)
        assertPoint(incoming.end, point(8, 0))
        assertPoint(incoming.start, point(0, 0))
        assertPoint(outgoing.start, point(10, 2))
        assertPoint(outgoing.end, point(10, 10))
        XCTAssertEqual(outcome.payload.isClosed, false)

        // The arc's midpoint is the closed form for a quarter circle chamfer of
        // the corner: the vertex pulled in by (radius - radius / sqrt(2)).
        let inset = 2 - 2.squareRoot()
        let middle = try XCTUnwrap(outcome.treatment.segments.first?.curve).point(at: 0.5)
        assertPoint(middle, point(10 - inset, inset), accuracy: 1e-12)

        // Tangency, measured as the sine of the angle between the arc's own
        // tangent and the leg it must continue, in millimetres of departure.
        let start = try XCTUnwrap(unitTangent(of: outcome.treatment, atStart: true))
        let end = try XCTUnwrap(unitTangent(of: outcome.treatment, atStart: false))
        XCTAssertLessThan(abs(start.cross(point(1, 0))) * 2, 1e-6)
        XCTAssertLessThan(abs(end.cross(point(0, 1))) * 2, 1e-6)

        // The trimmed path is still one connected path.
        XCTAssertTrue(joins(outcome.payload).allSatisfy { $0 <= FFTolerance.curveJoin })
        XCTAssertNotNil(outcome.payload.path())
    }

    func testFilletRadiusAndTangencyHoldAcrossAnglesAndRadii() throws {
        let cases: [(name: String, previous: Vec2, vertex: Vec2, next: Vec2, radius: Double, spans: Int)] = [
            ("right angle r=1", point(0, 0), point(10, 0), point(10, 10), 1, 1),
            ("right angle r=2.5", point(0, 0), point(10, 0), point(10, 10), 2.5, 1),
            (
                "60 degree corner",
                point(-10, 0),
                point(0, 0),
                point(-5, 5 * 3.squareRoot()),
                1,
                2
            ),
            (
                "120 degree corner",
                point(-10, 0),
                point(0, 0),
                point(5, 5 * 3.squareRoot()),
                1,
                1
            ),
        ]

        for fixture in cases {
            let payload = corner(
                previous: fixture.previous,
                vertex: fixture.vertex,
                next: fixture.next
            )
            let outcome = try payload.treatingCorner(0, with: .fillet(radius: fixture.radius))

            let expected = expectedTangentLength(
                previous: fixture.previous,
                vertex: fixture.vertex,
                next: fixture.next,
                radius: fixture.radius
            )
            XCTAssertEqual(
                outcome.report.tangentLength,
                expected,
                accuracy: 1e-12,
                "\(fixture.name): wrong tangent length"
            )
            XCTAssertEqual(
                outcome.report.treatmentSpanCount,
                fixture.spans,
                "\(fixture.name): wrong arc span count"
            )

            // Every committed sample of the arc lies on the analytic circle.
            let centre = expectedCentre(
                previous: fixture.previous,
                vertex: fixture.vertex,
                next: fixture.next,
                radius: fixture.radius
            )
            for sample in samples(of: outcome.treatment) {
                XCTAssertEqual(
                    sample.distance(to: centre),
                    fixture.radius,
                    accuracy: 1e-9,
                    "\(fixture.name): an arc sample left its circle"
                )
            }

            // The arc starts and ends exactly on the resolved tangent points.
            let arriving = unit(fixture.vertex - fixture.previous)
            let leaving = unit(fixture.next - fixture.vertex)
            let first = try XCTUnwrap(outcome.treatment.segments.first?.curve).start
            let last = try XCTUnwrap(outcome.treatment.segments.last?.curve).end
            assertPoint(first, fixture.vertex - arriving * expected, accuracy: 1e-9, fixture.name)
            assertPoint(last, fixture.vertex + leaving * expected, accuracy: 1e-9, fixture.name)

            // Tangency: the arc's tangent must be the leg's direction.
            let startTangent = try XCTUnwrap(unitTangent(of: outcome.treatment, atStart: true))
            let endTangent = try XCTUnwrap(unitTangent(of: outcome.treatment, atStart: false))
            XCTAssertLessThan(
                abs(startTangent.cross(arriving)) * fixture.radius,
                1e-6,
                "\(fixture.name): the arc does not leave along its incoming leg"
            )
            XCTAssertLessThan(
                abs(endTangent.cross(leaving)) * fixture.radius,
                1e-6,
                "\(fixture.name): the arc does not arrive along its outgoing leg"
            )
        }
    }

    func testFilletLengthBalanceIsExact() throws {
        let payload = rightAngle()
        let before = totalLength(payload)
        let outcome = try payload.treatingCorner(0, with: .fillet(radius: 2))

        // Ten millimetres of leg on each side, trimmed by two each, plus a
        // quarter of a two-millimetre circle: 20 - 4 + pi.
        XCTAssertEqual(before, 20, accuracy: 1e-12)
        XCTAssertEqual(totalLength(outcome.payload), 16 + Double.pi, accuracy: 1e-9)
        XCTAssertEqual(totalLength(outcome.treatment), Double.pi, accuracy: 1e-9)
    }

    func testOnlyTheTreatedCornerMoves() throws {
        let payload = polyline([
            point(0, 0),
            point(10, 0),
            point(10, 10),
            point(0, 10),
        ])
        let outcome = try payload.treatingCorner(0, with: .fillet(radius: 2))

        XCTAssertEqual(outcome.payload.segments.count, 4)
        // The outgoing leg was shortened at its start only; the span beyond it
        // is untouched.
        let outgoing = try XCTUnwrap(outcome.payload.segments[2].curve)
        let beyond = try XCTUnwrap(outcome.payload.segments[3].curve)
        assertPoint(outgoing.start, point(10, 2))
        assertPoint(outgoing.end, point(10, 10))
        assertPoint(beyond.start, point(10, 10))
        assertPoint(beyond.end, point(0, 10))
    }

    // MARK: - Refusals

    func testFilletRefusesARadiusLongerThanTheLeg() throws {
        let payload = rightAngle()
        guard let error = refusal(payload, corner: 0, treatment: .fillet(radius: 12)) else {
            return
        }
        guard case .filletExceedsLeg(let corner, let radius, let required, let available) = error else {
            return XCTFail("wrong refusal: \(error)")
        }
        XCTAssertEqual(corner, 0)
        XCTAssertEqual(radius, 12)
        XCTAssertEqual(required, 12, accuracy: 1e-12)
        XCTAssertEqual(available, 10)

        // The sentence names both numbers, so the refusal is actionable.
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("12.000 mm fillet radius"), message)
        XCTAssertTrue(message.contains("10.000 mm"), message)
    }

    func testFilletRefusesARadiusThatWouldConsumeTheWholeLeg() throws {
        let payload = rightAngle()
        guard let error = refusal(payload, corner: 0, treatment: .fillet(radius: 10)) else {
            return
        }
        guard case .filletExceedsLeg(_, _, let required, let available) = error else {
            return XCTFail("wrong refusal: \(error)")
        }
        XCTAssertEqual(required, 10, accuracy: 1e-12)
        XCTAssertEqual(available, 10, accuracy: 1e-12)
    }

    func testSharpCornerNeedsMoreLegThanItsRadius() throws {
        // A thirty-degree corner: the leg a one-millimetre radius consumes is
        // 1 / tan(15 degrees) = 3.732 mm, so two-millimetre legs are too short
        // even though the radius itself is smaller than the leg.
        let sharp = corner(
            previous: point(-2, 0),
            vertex: point(0, 0),
            next: point(-3.squareRoot(), 1)
        )
        guard let error = refusal(sharp, corner: 0, treatment: .fillet(radius: 1)) else {
            return
        }
        guard case .filletExceedsLeg(_, let radius, let required, let available) = error else {
            return XCTFail("wrong refusal: \(error)")
        }
        XCTAssertEqual(radius, 1)
        XCTAssertEqual(required, 1 / tan(Double.pi / 12), accuracy: 1e-12)
        XCTAssertEqual(available, 2, accuracy: 1e-12)

        // The same radius fits once the legs are long enough.
        let roomy = corner(
            previous: point(-10, 0),
            vertex: point(0, 0),
            next: point(-5 * 3.squareRoot(), 5)
        )
        let outcome = try roomy.treatingCorner(0, with: .fillet(radius: 1))
        XCTAssertEqual(outcome.report.tangentLength, 1 / tan(Double.pi / 12), accuracy: 1e-12)
        XCTAssertEqual(outcome.report.treatmentSpanCount, 2)
    }

    func testCollinearLegsAreRefusedAsNoCorner() {
        let straight = polyline([point(0, 0), point(10, 0), point(20, 0)])
        guard let error = refusal(straight, corner: 0, treatment: .fillet(radius: 1)) else {
            return
        }
        guard case .degenerateCorner(let corner) = error else {
            return XCTFail("wrong refusal: \(error)")
        }
        XCTAssertEqual(corner, 0)
    }

    func testCurvedLegIsRefusedRatherThanApproximated() {
        let curved = FFCurvePayload(segments: [
            FFCurveSegment(kind: .bezier, controlPoints: [
                FFPoint2(point(0, 0)),
                FFPoint2(point(2, 4)),
                FFPoint2(point(6, 4)),
                FFPoint2(point(8, 0)),
            ]),
            line(point(8, 0), point(12, 0)),
        ])
        guard let error = refusal(curved, corner: 0, treatment: .fillet(radius: 1)) else {
            return
        }
        guard case .curvedLeg(let segment) = error else {
            return XCTFail("wrong refusal: \(error)")
        }
        XCTAssertEqual(segment, 0)
    }

    func testCornerRefusalsNameTheirGeometry() {
        let payload = rightAngle()

        guard let missing = refusal(payload, corner: 5, treatment: .fillet(radius: 1)) else {
            return
        }
        guard case .noCorner(let corner) = missing else {
            return XCTFail("wrong refusal: \(missing)")
        }
        XCTAssertEqual(corner, 5)

        // A joint whose spans do not meet is not a corner.
        let broken = FFCurvePayload(segments: [
            line(point(0, 0), point(10, 0)),
            line(point(10, 5), point(10, 15)),
        ])
        guard let notJoined = refusal(broken, corner: 0, treatment: .chamfer(distance: 1)) else {
            return
        }
        guard case .cornerNotJoined(let index) = notJoined else {
            return XCTFail("wrong refusal: \(notJoined)")
        }
        XCTAssertEqual(index, 0)

        guard let badRadius = refusal(payload, corner: 0, treatment: .fillet(radius: 0)) else {
            return
        }
        guard case .invalidRadius(let radius) = badRadius else {
            return XCTFail("wrong refusal: \(badRadius)")
        }
        XCTAssertEqual(radius, 0)

        guard let badDistance = refusal(payload, corner: 0, treatment: .chamfer(distance: -1)) else {
            return
        }
        guard case .invalidDistance(let distance) = badDistance else {
            return XCTFail("wrong refusal: \(badDistance)")
        }
        XCTAssertEqual(distance, -1)
    }

    // MARK: - Chamfer geometry

    func testChamferCutsBothLegsAtTheGivenDistance() throws {
        let outcome = try rightAngle().treatingCorner(0, with: .chamfer(distance: 2))

        XCTAssertEqual(outcome.report.tangentLength, 2, accuracy: 1e-12)
        XCTAssertEqual(outcome.report.treatmentSpanCount, 1)
        XCTAssertEqual(outcome.payload.segments.count, 3)

        let cut = try XCTUnwrap(outcome.treatment.segments.first?.curve)
        assertPoint(cut.start, point(8, 0), accuracy: 1e-12)
        assertPoint(cut.end, point(10, 2), accuracy: 1e-12)
        XCTAssertEqual(cut.arcLength(tolerance: 1e-12), 2 * 2.squareRoot(), accuracy: 1e-12)

        // The cut replaces two right-angle legs with a straight chord, so the
        // path loses 4 mm of leg and gains a 2*sqrt(2) chord.
        XCTAssertEqual(totalLength(outcome.payload), 16 + 2 * 2.squareRoot(), accuracy: 1e-9)
        XCTAssertTrue(joins(outcome.payload).allSatisfy { $0 <= FFTolerance.curveJoin })
    }

    func testChamferRefusesADistanceLongerThanTheLeg() throws {
        guard let error = refusal(rightAngle(), corner: 0, treatment: .chamfer(distance: 12)) else {
            return
        }
        guard case .chamferExceedsLeg(_, let distance, let required, let available) = error else {
            return XCTFail("wrong refusal: \(error)")
        }
        XCTAssertEqual(distance, 12)
        XCTAssertEqual(required, 12)
        XCTAssertEqual(available, 10)
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("12.000 mm chamfer"), message)
    }

    // MARK: - Trim and keep

    func testKeepReturnsTheTreatmentSpanAlone() throws {
        let source = rightAngle()
        let original = source.fingerprint
        let outcome = try source.treatingCorner(0, with: .fillet(radius: 2))

        // The treatment is one arc on its own, from tangent point to tangent
        // point: what a jeweller sweeps, and what a preview draws before any
        // commit exists.
        XCTAssertEqual(outcome.treatment.segments.count, 1)
        XCTAssertEqual(outcome.treatment.isClosed, false)
        let arc = try XCTUnwrap(outcome.treatment.segments.first?.curve)
        assertPoint(arc.start, point(8, 0), accuracy: 1e-12)
        assertPoint(arc.end, point(10, 2), accuracy: 1e-12)

        // The value stage never mutates its input.
        XCTAssertEqual(source.fingerprint, original)
        XCTAssertEqual(
            outcome.payload.fingerprint,
            try source.treatingCorner(0, with: .fillet(radius: 2)).payload.fingerprint
        )
    }

    func testClosedSquareTreatsItsClosingCornerAndStaysClosed() throws {
        let square = polyline(
            [point(0, 0), point(4, 0), point(4, 4), point(0, 4)],
            isClosed: true
        )
        XCTAssertEqual(square.cornerCount, 4)
        XCTAssertEqual(square.segments.count, 4)

        // Corner 3 is the wrap: the last span ends at the origin and the first
        // span starts there.
        let outcome = try square.treatingCorner(3, with: .fillet(radius: 1))

        XCTAssertEqual(outcome.payload.segments.count, 5)
        XCTAssertTrue(outcome.payload.isClosed)
        let firstSpan = try XCTUnwrap(outcome.payload.segments[0].curve)
        let lastStraight = try XCTUnwrap(outcome.payload.segments[3].curve)
        assertPoint(firstSpan.start, point(1, 0))
        assertPoint(lastStraight.end, point(0, 1))

        // The treatment sits after the last span, because that is where the
        // path wraps back to the first.
        let arc = try XCTUnwrap(outcome.payload.segments[4].curve)
        assertPoint(arc.start, point(0, 1), accuracy: 1e-12)
        assertPoint(arc.end, point(1, 0), accuracy: 1e-12)

        XCTAssertTrue(joins(outcome.payload).allSatisfy { $0 <= FFTolerance.curveJoin })
        let path = try XCTUnwrap(outcome.payload.path())
        XCTAssertTrue(path.isClosed())
        // Sixteen millimetres of perimeter, less two millimetres of leg, plus a
        // quarter of a one-millimetre circle.
        XCTAssertEqual(totalLength(outcome.payload), 14 + Double.pi / 2, accuracy: 1e-9)
    }

    func testTwoIdenticalTreatmentsAreIdentical() throws {
        let source = rightAngle()
        let first = try source.treatingCorner(0, with: .fillet(radius: 2))
        let second = try source.treatingCorner(0, with: .fillet(radius: 2))
        XCTAssertEqual(first.payload.fingerprint, second.payload.fingerprint)
        XCTAssertEqual(first.treatment.fingerprint, second.treatment.fingerprint)
        XCTAssertEqual(first.report, second.report)

        let chamfered = try source.treatingCorner(0, with: .chamfer(distance: 2))
        XCTAssertNotEqual(chamfered.payload.fingerprint, first.payload.fingerprint)
    }

    // MARK: - Session ownership

    private func makeSession() -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 46")
        let node = FFNode(
            name: "Corner source",
            geometry: .curve(rightAngle()),
            layerID: document.currentLayerID,
            curvePrimitive: FFCurvePrimitive(kind: .polygon)
        )
        document.rootNodes = [node]
        return (FFEditorSession(document: document), node.id)
    }

    func testFilletCommandIsOneUndo() throws {
        let (session, nodeID) = makeSession()
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        let treated = try XCTUnwrap(
            session.treatCurveCorner(nodeID: nodeID, corner: 0, treatment: .fillet(radius: 2))
        )
        XCTAssertEqual(treated, nodeID)
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertEqual(session.document.rootNodes.count, 1)
        XCTAssertEqual(session.selection.selectedIDs, Set([nodeID]))
        let report = try XCTUnwrap(session.lastCornerReport)
        XCTAssertEqual(report.tangentLength, 2, accuracy: 1e-12)

        let edited = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertNotEqual(edited.fingerprint, original)
        XCTAssertEqual(edited.segments.count, 3)
        // The parametric record no longer describes the geometry.
        XCTAssertNil(session.document.node(withID: nodeID)?.curvePrimitive)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            original,
            "one undo must restore the original corner"
        )
    }

    func testKeepCommandAddsOneNodeAndLeavesTheSourceAlone() throws {
        let (session, nodeID) = makeSession()
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        let created = try XCTUnwrap(
            session.treatCurveCorner(
                nodeID: nodeID,
                corner: 0,
                treatment: .chamfer(distance: 2),
                keepingOriginal: true
            )
        )
        XCTAssertNotEqual(created, nodeID)
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertEqual(session.document.rootNodes.count, 2)
        XCTAssertEqual(session.selection.selectedIDs, Set([created]))
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            original,
            "the kept source must not move"
        )
        let span = try XCTUnwrap(session.document.curvePayload(forNodeID: created))
        XCTAssertEqual(span.segments.count, 1)
        let createdNode = try XCTUnwrap(session.document.node(withID: created))
        XCTAssertEqual(createdNode.name, "Chamfer")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes.count, 1)
        XCTAssertNil(session.document.node(withID: created))
    }

    func testCornerRefusalsCreateNoHistory() throws {
        let (session, nodeID) = makeSession()

        XCTAssertNil(
            session.treatCurveCorner(nodeID: nodeID, corner: 0, treatment: .fillet(radius: 12))
        )
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertTrue(
            (session.curveEditMessage ?? "").contains("12.000 mm fillet radius"),
            session.curveEditMessage ?? "no message"
        )

        XCTAssertNil(
            session.treatCurveCorner(nodeID: nodeID, corner: 4, treatment: .chamfer(distance: 1))
        )
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertTrue(
            (session.curveEditMessage ?? "").hasPrefix("The curve has no corner 5"),
            session.curveEditMessage ?? "no message"
        )

        var lockedDocument = FFDocument(name: "Phase 46 locked")
        lockedDocument.layers[0].isLocked = true
        let lockedNode = FFNode(
            name: "Locked corner",
            geometry: .curve(rightAngle()),
            layerID: lockedDocument.currentLayerID
        )
        lockedDocument.rootNodes = [lockedNode]
        let lockedSession = FFEditorSession(document: lockedDocument)
        XCTAssertNil(
            lockedSession.treatCurveCorner(
                nodeID: lockedNode.id,
                corner: 0,
                treatment: .fillet(radius: 2)
            )
        )
        XCTAssertEqual(lockedSession.documentSession.undoDepth, 0)
        XCTAssertEqual(lockedSession.curveEditMessage, "That curve is on a locked layer")
    }

    func testATreatedCornerSurvivesSaveAndReopen() throws {
        let (session, nodeID) = makeSession()
        _ = try XCTUnwrap(
            session.treatCurveCorner(nodeID: nodeID, corner: 0, treatment: .fillet(radius: 2))
        )
        let committed = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))

        let data = try JSONEncoder().encode(session.document)
        let reopened = try JSONDecoder().decode(FFDocument.self, from: data)
        let decoded = try XCTUnwrap(reopened.curvePayload(forNodeID: nodeID))

        XCTAssertEqual(decoded.fingerprint, committed.fingerprint)
        XCTAssertEqual(decoded.segments.count, 3)
        XCTAssertNotNil(decoded.path())
        XCTAssertEqual(totalLength(decoded), 16 + Double.pi, accuracy: 1e-9)
    }
}
