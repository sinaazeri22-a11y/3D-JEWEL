import Foundation
import XCTest
@testable import FacetForge

/// Phase 44's acceptance: a join of two tangent curves reports G1 and yields
/// one curve, and a trimmed endpoint lies within 1e-7 mm of its cutter.
///
/// The other five cleanup operations are proved beside those two: trim and
/// extend keep the surviving geometry on the original curve, split produces two
/// halves that meet at the same parameter, reverse is an exact re-parameter-
/// isation, close adds one span or only the intent flag, and duplicate removal
/// drops only data that carries no geometry.
final class Phase44CurveCleanupTests: XCTestCase {
    // MARK: - Fixtures

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    private func cubic(_ points: [Vec2]) -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .bezier,
                controlPoints: points.map { FFPoint2($0) }
            ),
        ])
    }

    private func line(_ start: Vec2, _ end: Vec2) -> FFCurveSegment {
        FFCurveSegment(
            kind: .bezier,
            controlPoints: [FFPoint2(start), FFPoint2(end)]
        )
    }

    /// A cubic hump from (0, 0) to (80, 0). Its end tangent is 3·(P3 − P2) =
    /// (60, −90), the direction the G1 fixture must leave on.
    private func hump() -> FFCurvePayload {
        cubic([point(0, 0), point(20, 30), point(60, 30), point(80, 0)])
    }

    /// The same cubic as a rational NURBS span with unit weights.
    private func rationalHump() -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    point(0, 0), point(20, 30), point(60, 30), point(80, 0),
                ].map { FFPoint2($0) },
                weights: [1, 1, 1, 1],
                degree: 3,
                knots: [0, 0, 0, 0, 1, 1, 1, 1]
            ),
        ])
    }

    /// A quarter circle of radius 10 from (10, 0) to (0, 10): the rational
    /// conic a Phase 40 arc stores.
    private func quarterCircle() -> FFCurvePayload {
        let cosine = cos(Double.pi / 4)
        return FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [point(10, 0), point(10, 10), point(0, 10)].map { FFPoint2($0) },
                weights: [1, cosine, 1],
                degree: 2,
                knots: [0, 0, 0, 1, 1, 1]
            ),
        ])
    }

    /// A cubic that leaves (80, 0) on the hump's end tangent. Its start
    /// curvature differs from the hump's end curvature, so the seam is G1 and
    /// not G2.
    private func tangentPartner() -> FFCurvePayload {
        cubic([point(80, 0), point(100, -30), point(140, 10), point(170, 40)])
    }

    /// A cubic that corners away from the hump's end tangent: G0 only.
    private func cornerPartner() -> FFCurvePayload {
        cubic([point(80, 0), point(120, 20), point(140, 30), point(170, 40)])
    }

    private func makeDocument(with payload: FFCurvePayload) -> (FFDocument, UUID) {
        var document = FFDocument(name: "Phase 44")
        let node = FFNode(
            name: "Cleanup curve",
            geometry: .curve(payload),
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        return (document, node.id)
    }

    private func assertCleanupError(
        _ expected: FFCurveCleanupError,
        _ body: @autoclosure () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? FFCurveCleanupError, expected, file: file, line: line)
        }
    }

    /// Refusals that carry the measured distance cannot be written as a
    /// constant, so they are matched by case and the distance is checked to be
    /// a real positive measurement.
    private func assertOffCurve(
        _ body: @autoclosure () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let cleanup = error as? FFCurveCleanupError else {
                return XCTFail("expected a cleanup refusal, got \(error)", file: file, line: line)
            }
            switch cleanup {
            case .trimPointOffCurve(let distance), .splitPointOffCurve(let distance):
                XCTAssertGreaterThan(distance, 0, file: file, line: line)
            default:
                XCTFail("expected an off-curve refusal, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - Trim

    func testATrimmedEndpointLiesOnTheCutter() throws {
        let fixtures: [(name: String, payload: FFCurvePayload)] = [
            ("cubic", hump()),
            ("rational cubic", rationalHump()),
            ("quarter circle", quarterCircle()),
        ]

        for fixture in fixtures {
            for parameter in [0.17, 0.43, 0.78] {
                for side in FFCurveEnd.allCases {
                    var payload = fixture.payload
                    let curve = try XCTUnwrap(payload.segments[0].curve)
                    let cutter = curve.point(at: parameter)
                    let endpoint = try payload.trim(at: cutter, removing: side)

                    XCTAssertLessThan(
                        endpoint.distance(to: cutter),
                        1e-7,
                        "\(fixture.name) \(side.label) at \(parameter) missed its cutter"
                    )

                    // The survivor is the original curve over the surviving
                    // interval, retimed to [0, 1], not a refit of it. Trim
                    // retimes from the parameter `closestPoint` resolved, not
                    // from the requested one, so the interval is checked by
                    // its own ends and the interior by the
                    // parameter-independent property: every sampled point of
                    // the survivor still lies on the original curve.
                    let trimmed = try XCTUnwrap(payload.segments[0].curve)
                    XCTAssertEqual(trimmed.start, side == .start ? endpoint : curve.start)
                    XCTAssertEqual(trimmed.end, side == .end ? endpoint : curve.end)
                    for step in 0...20 {
                        let local = Double(step) / 20
                        let onOriginal = curve.closestPoint(to: trimmed.point(at: local))
                        XCTAssertLessThan(
                            onOriginal.distance,
                            1e-7,
                            "\(fixture.name) \(side.label) left the original curve"
                        )
                    }
                    XCTAssertNotNil(payload.path(), "\(fixture.name) \(side.label) was not joined")
                }
            }
        }
    }

    func testTrimRefusesAPointOffTheCurveAndItsOwnEnd() throws {
        var payload = hump()
        assertOffCurve(try payload.trim(at: point(40, 40), removing: .start))

        let curve = try XCTUnwrap(payload.segments[0].curve)
        assertCleanupError(
            .trimAtEndpoint,
            try payload.trim(at: curve.point(at: 0), removing: .start)
        )

        var closed = hump()
        XCTAssertTrue(try closed.close())
        assertCleanupError(
            .closedCurve,
            try closed.trim(at: point(20, 30), removing: .start)
        )
    }

    // MARK: - Extend

    func testExtendGrowsAlongTheEndTangent() throws {
        var extended = hump()
        let original = try XCTUnwrap(extended.segments[0].curve)
        let direction = try XCTUnwrap(original.derivative(at: 1).normalized())
        let tip = try extended.extend(at: .end, by: 5)

        XCTAssertEqual(tip.distance(to: original.end + direction * 5), 0, accuracy: 1e-12)
        XCTAssertEqual(extended.segments.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(extended.segments[1].curve).start.distance(to: original.end),
            0,
            accuracy: 1e-12
        )
        XCTAssertNotNil(extended.path())

        var headed = hump()
        let headDirection = try XCTUnwrap(original.derivative(at: 0).normalized())
        let head = try headed.extend(at: .start, by: 2)
        XCTAssertEqual(head.distance(to: original.start - headDirection * 2), 0, accuracy: 1e-12)
        XCTAssertEqual(headed.segments.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(headed.segments[0].curve).start.distance(to: head),
            0,
            accuracy: 1e-12
        )
        XCTAssertNotNil(headed.path())
    }

    func testExtendRefusesAZeroDistanceAndAZeroTangent() throws {
        var payload = hump()
        assertCleanupError(.extensionDistance, try payload.extend(at: .end, by: 0))

        var flatPayload = cubic([point(0, 0), point(10, 10), point(20, 20), point(20, 20)])
        assertCleanupError(.noEndTangent(segment: 0), try flatPayload.extend(at: .end, by: 1))

        var closed = hump()
        XCTAssertTrue(try closed.close())
        assertCleanupError(.closedCurve, try closed.extend(at: .end, by: 1))
    }

    // MARK: - Split

    func testSplitProducesTwoHalvesThatMeetAtTheParameter() throws {
        let payload = hump()
        let curve = try XCTUnwrap(payload.segments[0].curve)
        let parameter = 0.375
        let seam = curve.point(at: parameter)
        let pieces = try payload.split(segment: 0, at: parameter)

        let left = try XCTUnwrap(pieces.left.segments.last?.curve)
        let right = try XCTUnwrap(pieces.right.segments.first?.curve)
        XCTAssertLessThan(left.end.distance(to: seam), 1e-12)
        XCTAssertLessThan(right.start.distance(to: seam), 1e-12)

        for step in 0...20 {
            let local = Double(step) / 20
            XCTAssertLessThan(
                left.point(at: local).distance(to: curve.point(at: parameter * local)),
                1e-12
            )
            XCTAssertLessThan(
                right.point(at: local).distance(to: curve.point(at: parameter + (1 - parameter) * local)),
                1e-12
            )
        }
    }

    func testSplitAtAPointResolvesTheCutter() throws {
        let payload = hump()
        let curve = try XCTUnwrap(payload.segments[0].curve)
        let cutter = curve.point(at: 0.3)
        let pieces = try payload.split(segment: 0, at: cutter)

        XCTAssertEqual(pieces.parameter, 0.3, accuracy: 1e-6)
        let leftEnd = try XCTUnwrap(pieces.left.segments.last?.curve).end
        let rightStart = try XCTUnwrap(pieces.right.segments.first?.curve).start
        // The two halves share the split point exactly, because the split is
        // one construction; the distance to the caller's cutter is bounded by
        // the closest-point solver's 1e-10 parameter tolerance times the
        // hump's ~93 mm/unit speed, so it is a measurement, not an identity.
        XCTAssertEqual(leftEnd, rightStart)
        XCTAssertLessThan(leftEnd.distance(to: cutter), 1e-7)
        XCTAssertLessThan(rightStart.distance(to: cutter), 1e-7)
        assertOffCurve(try payload.split(segment: 0, at: point(40, 40)))
    }

    // MARK: - Join

    func testJoinOfTwoTangentCurvesReportsG1AndYieldsOneCurve() throws {
        let outcome = try hump().joined(with: tangentPartner())

        XCTAssertEqual(outcome.report.continuity, .g1)
        XCTAssertEqual(outcome.report.gap, 0, accuracy: 1e-12)
        // Two identical unit tangents can read a few 1e-8 apart through acos
        // after the dot product rounds, so the bound is the model's own G1
        // tangent tolerance rather than zero to the last bit.
        XCTAssertLessThan(outcome.report.tangentAngle, 1e-6)
        XCTAssertGreaterThan(
            outcome.report.curvatureDifference,
            1e-4,
            "the fixture must not also be G2"
        )
        XCTAssertEqual(outcome.payload.segments.count, 2)
        XCTAssertNotNil(outcome.payload.path(), "the joined payload is not one curve")
        XCTAssertFalse(outcome.reversedFirst)
        XCTAssertFalse(outcome.reversedSecond)
        XCTAssertEqual(
            outcome.payload.segments[0].curve?.end,
            outcome.payload.segments[1].curve?.start
        )
        XCTAssertTrue(outcome.report.summary.hasPrefix("G1"))
    }

    func testJoinReportsTheContinuityTheSeamActuallyHas() throws {
        let corner = try hump().joined(with: cornerPartner())
        XCTAssertEqual(corner.report.continuity, .g0)
        XCTAssertGreaterThan(corner.report.tangentAngle, 1e-3)

        let halves = try hump().split(segment: 0, at: 0.5)
        let restored = try halves.left.joined(with: halves.right)
        XCTAssertEqual(restored.report.continuity, .g2)
        XCTAssertEqual(restored.report.curvatureDifference, 0, accuracy: 1e-9)
        XCTAssertEqual(restored.payload.segments.count, 2)
        XCTAssertNotNil(restored.payload.path())
    }

    func testJoinReversesWhicheverCurveBringsTheEndsTogether() throws {
        // The partner is stored end-to-start, so only a reversal can put its
        // start on the hump's end.
        let backwards = cubic([
            point(170, 40), point(140, 10), point(100, -30), point(80, 0),
        ])
        let outcome = try hump().joined(with: backwards)

        XCTAssertTrue(outcome.reversedSecond)
        XCTAssertFalse(outcome.reversedFirst)
        XCTAssertEqual(outcome.report.continuity, .g1)
        XCTAssertEqual(outcome.report.gap, 0, accuracy: 1e-12)
        XCTAssertEqual(
            outcome.payload.segments[1].curve?.end,
            point(170, 40)
        )
    }

    func testJoinRefusesAGapAndAClosedCurve() throws {
        let far = cubic([point(90, 0), point(110, -30), point(150, 10), point(180, 40)])
        // The reported gap is a measurement: 10 mm is the distance between the
        // hump's end and the far curve's start.
        XCTAssertThrowsError(try hump().joined(with: far)) { error in
            guard let cleanup = error as? FFCurveCleanupError,
                  case .joinGap(let gap) = cleanup
            else { return XCTFail("expected joinGap, got \(error)") }
            XCTAssertEqual(gap, 10, accuracy: 1e-12)
        }

        var closed = hump()
        XCTAssertTrue(try closed.close())
        assertCleanupError(.closedCurve, try closed.joined(with: tangentPartner()))
    }

    // MARK: - Reverse

    func testReverseIsAnExactReParameterisation() throws {
        let original = hump()
        let curve = try XCTUnwrap(original.segments[0].curve)
        let reversed = try XCTUnwrap(original.reversed())
        let reversedCurve = try XCTUnwrap(reversed.segments[0].curve)

        XCTAssertEqual(reversedCurve.start, curve.end)
        XCTAssertEqual(reversedCurve.end, curve.start)
        for step in 0...20 {
            let t = Double(step) / 20
            XCTAssertLessThan(
                reversedCurve.point(at: t).distance(to: curve.point(at: 1 - t)),
                1e-12
            )
        }
    }

    // MARK: - Close

    func testCloseAddsOneSpanOrOnlyTheIntentFlag() throws {
        var open = FFCurvePayload(segments: [line(point(0, 0), point(10, 0)), line(point(10, 0), point(10, 10))])
        XCTAssertTrue(try open.close())
        XCTAssertTrue(open.isClosed)
        XCTAssertEqual(open.segments.count, 3)
        let path = try XCTUnwrap(open.path())
        XCTAssertTrue(path.isClosed())
        XCTAssertEqual(path.curves.count, 3)
        assertCleanupError(.alreadyClosed, try open.close())

        var meeting = FFCurvePayload(segments: [line(point(0, 0), point(10, 0)), line(point(10, 0), point(0, 0))])
        XCTAssertFalse(try meeting.close())
        XCTAssertTrue(meeting.isClosed)
        XCTAssertEqual(meeting.segments.count, 2)
        XCTAssertTrue(try XCTUnwrap(meeting.path()).isClosed())
    }

    // MARK: - Duplicates

    func testDuplicateRemovalDropsOnlyDataWithoutGeometry() throws {
        let points: [Vec2] = [point(0, 0), point(0, 0), point(10, 0), point(10, 0), point(10, 10)]
        let polyline = FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: points.map { FFPoint2($0) },
                weights: [1, 1, 1, 1, 1],
                degree: 1,
                knots: FFCurvePayload.clampedKnots(degree: 1, pointCount: 5)
            ),
        ])
        let reduced = polyline.removingDuplicates()
        XCTAssertEqual(reduced.removedPoints, 2)
        XCTAssertEqual(reduced.removedSpans, 0)
        XCTAssertEqual(reduced.payload.segments[0].controlPoints.count, 3)
        XCTAssertNotNil(reduced.payload.path())
        // Every surviving vertex is one of the original vertices, in order.
        XCTAssertEqual(
            reduced.payload.segments[0].controlPoints.map(\.vector),
            [point(0, 0), point(10, 0), point(10, 10)]
        )

        let duplicated = FFCurvePayload(segments: [
            line(point(0, 0), point(10, 0)),
            line(point(0, 0), point(10, 0)),
            line(point(10, 0), point(10, 10)),
        ])
        let deduped = duplicated.removingDuplicates()
        XCTAssertEqual(deduped.removedSpans, 1)
        XCTAssertEqual(deduped.payload.segments.count, 2)
        XCTAssertNotNil(deduped.payload.path())

        let empty = FFCurvePayload(segments: [
            line(point(0, 0), point(10, 0)),
            line(point(10, 0), point(10, 0)),
            line(point(10, 0), point(10, 10)),
        ])
        let cleared = empty.removingDuplicates()
        XCTAssertEqual(cleared.removedSpans, 1)
        XCTAssertNotNil(cleared.payload.path())

        // A repeated control point inside a higher-degree span would change the
        // curve, so it is left alone.
        let higherDegree = cubic([point(0, 0), point(0, 0), point(10, 10), point(20, 0)])
        let untouched = higherDegree.removingDuplicates()
        XCTAssertFalse(untouched.hasChanges)
        XCTAssertEqual(untouched.payload.fingerprint, higherDegree.fingerprint)

        XCTAssertFalse(hump().removingDuplicates().hasChanges)
    }

    // MARK: - Session ownership

    func testEveryCleanupCommandIsOneUndoStep() throws {
        let (session, nodeID) = makeSession()
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        let cutter = try XCTUnwrap(
            session.document.curvePayload(forNodeID: nodeID)?.segments[0].curve
        ).point(at: 0.4)

        XCTAssertTrue(session.trimCurve(nodeID: nodeID, removing: .start, at: cutter))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.curvePayload(forNodeID: nodeID)?.fingerprint, original)

        XCTAssertTrue(session.extendCurve(nodeID: nodeID, at: .end, by: 4))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.curvePayload(forNodeID: nodeID)?.fingerprint, original)

        XCTAssertTrue(session.reverseCurve(nodeID: nodeID))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.curvePayload(forNodeID: nodeID)?.fingerprint, original)

        XCTAssertTrue(session.closeCurve(nodeID: nodeID))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.isClosed,
            true
        )
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.curvePayload(forNodeID: nodeID)?.fingerprint, original)

        XCTAssertFalse(session.removeCurveDuplicates(nodeID: nodeID))
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(
            session.curveEditMessage,
            "That curve has no duplicate points or empty spans"
        )
    }

    func testSplitCreatesOneNodeAndOneUndoRestoresBothHalves() throws {
        let (session, nodeID) = makeSession()
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint
        let cutter = try XCTUnwrap(
            session.document.curvePayload(forNodeID: nodeID)?.segments[0].curve
        ).point(at: 0.45)

        let created = try XCTUnwrap(session.splitCurve(nodeID: nodeID, segment: 0, at: cutter))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertEqual(session.document.rootNodes.count, 2)
        XCTAssertNotEqual(created, nodeID)
        XCTAssertEqual(session.selection.selectedIDs, Set([created]))
        XCTAssertNotNil(session.document.curvePayload(forNodeID: created))
        XCTAssertEqual(session.document.curveNodeCount, 2)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes.count, 1)
        XCTAssertNil(session.document.node(withID: created))
        XCTAssertEqual(session.document.curvePayload(forNodeID: nodeID)?.fingerprint, original)
    }

    func testJoinMergesTwoNodesAndOneUndoRestoresBoth() throws {
        var document = FFDocument(name: "Phase 44 join")
        let first = FFNode(
            name: "First",
            geometry: .curve(hump()),
            layerID: document.currentLayerID
        )
        let second = FFNode(
            name: "Partner",
            geometry: .curve(tangentPartner()),
            layerID: document.currentLayerID
        )
        document.rootNodes = [first, second]
        let session = FFEditorSession(document: document)
        let firstID = first.id

        let firstBefore = try XCTUnwrap(session.document.curvePayload(forNodeID: firstID)).fingerprint
        let secondBefore = try XCTUnwrap(session.document.curvePayload(forNodeID: second.id)).fingerprint

        XCTAssertTrue(session.joinCurves(nodeID: firstID, with: second.id))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertEqual(session.document.rootNodes.count, 1)
        XCTAssertEqual(session.lastCurveJoinReport?.continuity, .g1)
        XCTAssertTrue(session.documentStatus.contains("G1"))
        let joined = try XCTUnwrap(session.document.curvePayload(forNodeID: firstID))
        XCTAssertEqual(joined.segments.count, 2)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes.count, 2)
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: firstID)?.fingerprint,
            firstBefore
        )
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: second.id)?.fingerprint,
            secondBefore
        )
    }

    func testJoinMapsTheSecondCurveIntoTheFirstPlanesSpace() throws {
        var document = FFDocument(name: "Phase 44 placement")
        let first = FFNode(
            name: "First",
            geometry: .curve(hump()),
            layerID: document.currentLayerID
        )
        let offset = Vec3(x: 5, y: 7, z: 0)
        let partnerPoints = [point(75, -7), point(95, -37), point(135, 3), point(165, 33)]
        let second = FFNode(
            name: "Placed partner",
            transform: FFTransform(matrix: Mat4.translation(offset), pivot: Vec3.zero),
            geometry: .curve(cubic(partnerPoints)),
            layerID: document.currentLayerID
        )
        document.rootNodes = [first, second]
        let session = FFEditorSession(document: document)

        XCTAssertTrue(session.joinCurves(nodeID: first.id, with: second.id))
        XCTAssertEqual(session.lastCurveJoinReport?.continuity, .g1)
        XCTAssertEqual(session.lastCurveJoinReport?.gap ?? 1, 0, accuracy: 1e-12)
        let joined = try XCTUnwrap(session.document.curvePayload(forNodeID: first.id))
        // The placed span is stored in the first node's local space, which is
        // the partner's world position minus the translation.
        let placedStart = try XCTUnwrap(joined.segments[1].controlPoints.first).vector
        XCTAssertEqual(placedStart.distance(to: point(80, 0)), 0, accuracy: 1e-12)
        // Every stored control point draws where the partner was drawn: its
        // local point plus the partner's translation is the world point.
        let placedThird = try XCTUnwrap(joined.segments[1].controlPoints.dropFirst(2).first).vector
        XCTAssertEqual(
            placedThird.distance(to: partnerPoints[2] + Vec2(x: offset.x, y: offset.y)),
            0,
            accuracy: 1e-12
        )
    }

    func testJoinRefusesTwoDifferentSketchPlanes() throws {
        var document = FFDocument(name: "Phase 44 planes")
        let first = FFNode(
            name: "First",
            geometry: .curve(hump()),
            layerID: document.currentLayerID
        )
        let tilted = FFNode(
            name: "Tilted partner",
            transform: FFTransform(
                matrix: Mat4.rotationX(0.2),
                pivot: Vec3.zero
            ),
            geometry: .curve(tangentPartner()),
            layerID: document.currentLayerID
        )
        document.rootNodes = [first, tilted]
        let session = FFEditorSession(document: document)

        XCTAssertFalse(session.joinCurves(nodeID: first.id, with: tilted.id))
        XCTAssertEqual(
            session.curveEditMessage,
            "Join needs both curves on one sketch plane at the same scale"
        )
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(session.document.rootNodes.count, 2)
    }

    func testALockedCurveAndANonCurveRefuseWithoutCreatingHistory() throws {
        var locked = FFDocument(name: "Phase 44 locked")
        locked.layers[0].isLocked = true
        let node = FFNode(
            name: "Locked curve",
            geometry: .curve(hump()),
            layerID: locked.currentLayerID
        )
        locked.rootNodes = [node]
        let session = FFEditorSession(document: locked)
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: node.id)).fingerprint

        XCTAssertFalse(session.trimCurve(nodeID: node.id, removing: .start, at: point(40, 20)))
        XCTAssertFalse(session.reverseCurve(nodeID: node.id))
        XCTAssertFalse(session.closeCurve(nodeID: node.id))
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(session.curveEditMessage, "That curve is on a locked layer")
        XCTAssertEqual(session.document.curvePayload(forNodeID: node.id)?.fingerprint, original)

        var grouped = FFDocument(name: "Phase 44 group")
        let group = FFNode(name: "Empty group", layerID: grouped.currentLayerID)
        grouped.rootNodes = [group]
        let groupSession = FFEditorSession(document: grouped)
        XCTAssertFalse(groupSession.reverseCurve(nodeID: group.id))
        XCTAssertEqual(
            groupSession.curveEditMessage,
            "Select a curve before editing its control points"
        )
        XCTAssertEqual(groupSession.documentSession.undoDepth, 0)
    }

    func testACleanedCurveSurvivesSaveAndReopen() throws {
        let (session, nodeID) = makeSession()
        XCTAssertTrue(session.reverseCurve(nodeID: nodeID))
        XCTAssertTrue(session.closeCurve(nodeID: nodeID))
        let cleaned = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))

        let data = try JSONEncoder().encode(session.document)
        let reopened = try JSONDecoder().decode(FFDocument.self, from: data)
        let decoded = try XCTUnwrap(reopened.curvePayload(forNodeID: nodeID))

        XCTAssertEqual(decoded.fingerprint, cleaned.fingerprint)
        XCTAssertTrue(decoded.isClosed)
        XCTAssertEqual(decoded.segments.count, cleaned.segments.count)
        XCTAssertTrue(try XCTUnwrap(decoded.path()).isClosed())
    }

    /// A default argument cannot call an instance method, so the common case
    /// is its own overload rather than `payload: FFCurvePayload = hump()`.
    private func makeSession() -> (FFEditorSession, UUID) {
        makeSession(payload: hump())
    }

    private func makeSession(payload: FFCurvePayload) -> (FFEditorSession, UUID) {
        let (document, nodeID) = makeDocument(with: payload)
        return (FFEditorSession(document: document), nodeID)
    }
}
