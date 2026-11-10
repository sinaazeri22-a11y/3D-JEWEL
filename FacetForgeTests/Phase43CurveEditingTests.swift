import Foundation
import XCTest
@testable import FacetForge

/// Phase 43's acceptance: twenty-five editing operations each change the
/// canonical, nanometre-quantised curve fingerprint and leave the path joined,
/// and a weight change is reflected in the curvature comb.
///
/// The sequence is deliberately cumulative: each operation builds on the
/// previous payload, so an operation that quietly does nothing hashes the same
/// payload as its neighbour and fails the distinctness check. The whole script
/// runs twice and both hash sequences must agree, which is the expected-hash
/// check without pinning values that only one runtime can produce.
final class Phase43CurveEditingTests: XCTestCase {
    // MARK: - Fixtures

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    /// Two joined cubic NURBS spans that meet exactly at (80, 0). The shared
    /// endpoint is what makes the drag test prove join propagation.
    private func basePayload() -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(point(0, 0)),
                    FFPoint2(point(20, 30)),
                    FFPoint2(point(60, 30)),
                    FFPoint2(point(80, 0)),
                ],
                weights: [1, 1, 1, 1],
                degree: 3,
                knots: [0, 0, 0, 0, 1, 1, 1, 1]
            ),
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(point(80, 0)),
                    FFPoint2(point(100, -30)),
                    FFPoint2(point(140, -30)),
                    FFPoint2(point(160, 0)),
                ],
                weights: [1, 1, 1, 1],
                degree: 3,
                knots: [0, 0, 0, 0, 1, 1, 1, 1]
            ),
        ])
    }

    private func weightedCubic() -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(point(0, 0)),
                    FFPoint2(point(20, 30)),
                    FFPoint2(point(60, 30)),
                    FFPoint2(point(80, 0)),
                ],
                weights: [1, 1.2, 0.8, 1],
                degree: 3,
                knots: [0, 0, 0, 0, 1, 1, 1, 1]
            ),
        ])
    }

    private func cubicBezier() -> FFCurvePayload {
        FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .bezier,
                controlPoints: [
                    FFPoint2(point(0, 0)),
                    FFPoint2(point(10, 20)),
                    FFPoint2(point(30, 20)),
                    FFPoint2(point(40, 0)),
                ]
            ),
        ])
    }

    private func makeDocument(with payload: FFCurvePayload) -> (FFDocument, UUID) {
        var document = FFDocument(name: "Phase 43")
        let node = FFNode(
            name: "Editable curve",
            geometry: .curve(payload),
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        return (document, node.id)
    }

    private func assertPoint(
        _ actual: Vec2,
        _ expected: Vec2,
        accuracy: Double = 1e-9,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message(), file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message(), file: file, line: line)
    }

    private func samples(
        _ payload: FFCurvePayload,
        segment index: Int,
        count: Int = 100
    ) throws -> [(t: Double, point: Vec2)] {
        let curve = try XCTUnwrap(payload.segments[index].curve)
        return (0...count).map { step in
            let t = Double(step) / Double(count)
            return (t, curve.point(at: t))
        }
    }

    // MARK: - Twenty-five operations

    func testTwentyFiveEditingOperationsProduceAReproducibleHashSequence() throws {
        let first = try applyTwentyFiveEditingOperations()
        let second = try applyTwentyFiveEditingOperations()

        XCTAssertEqual(first.labels.count, 25)
        XCTAssertEqual(first.hashes.count, 25)
        XCTAssertEqual(Set(first.hashes).count, 25, "an operation left the payload unchanged")
        XCTAssertEqual(second.hashes, first.hashes, "the script did not reproduce its hash sequence")
        // Span 1 is elevated three times, inserted into three times and loses
        // two interior points; span 2 is elevated twice, inserted into twice
        // and loses two interior points.
        XCTAssertEqual(first.payload.segments[0].controlPoints.count, 8)
        XCTAssertEqual(first.payload.segments[1].controlPoints.count, 6)
    }

    /// Applies the 25 cumulative edits and returns each step's label, the
    /// fingerprint sequence and the final payload. The test runs it twice, so
    /// the first sequence is the expected hash sequence for the second, and an
    /// operation that quietly does nothing collides with its neighbour.
    private func applyTwentyFiveEditingOperations() throws -> (
        labels: [String],
        hashes: [String],
        payload: FFCurvePayload
    ) {
        var payload = basePayload()
        var hashes: [String] = []
        var labels: [String] = []

        func record(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNotNil(payload.path(), "\(label) left the path unjoined", file: file, line: line)
            labels.append(label)
            hashes.append(payload.fingerprint)
        }

        try payload.moveControlPoint(FFCurvePointRef(segment: 0, point: 1), to: point(21, 33))
        record("move span 1 point 2")
        try payload.moveControlPoint(FFCurvePointRef(segment: 0, point: 2), to: point(59, 32))
        record("move span 1 point 3")
        try payload.moveControlPoint(FFCurvePointRef(segment: 1, point: 1), to: point(101, -33))
        record("move span 2 point 2")
        try payload.moveControlPoint(FFCurvePointRef(segment: 1, point: 2), to: point(139, -32))
        record("move span 2 point 3")
        try payload.moveControlPoint(FFCurvePointRef(segment: 0, point: 3), to: point(82, 1))
        record("move shared join")
        try payload.setWeight(FFCurvePointRef(segment: 0, point: 1), to: 1.2)
        record("weight span 1 point 2")
        try payload.setWeight(FFCurvePointRef(segment: 0, point: 2), to: 0.8)
        record("weight span 1 point 3")
        try payload.setWeight(FFCurvePointRef(segment: 1, point: 1), to: 2)
        record("weight span 2 point 2")
        try payload.setWeight(FFCurvePointRef(segment: 1, point: 2), to: 0.5)
        record("weight span 2 point 3")
        try payload.elevateDegree(segment: 0)
        record("elevate span 1 to degree 4")
        try payload.elevateDegree(segment: 1)
        record("elevate span 2 to degree 4")
        try payload.elevateDegree(segment: 0)
        record("elevate span 1 to degree 5")
        try payload.elevateDegree(segment: 1)
        record("elevate span 2 to degree 5")
        try payload.elevateDegree(segment: 0)
        record("elevate span 1 to degree 6")
        _ = try payload.insertControlPoint(segment: 0, at: 0.25)
        record("insert span 1 at 0.25")
        _ = try payload.insertControlPoint(segment: 0, at: 0.6)
        record("insert span 1 at 0.6")
        _ = try payload.insertControlPoint(segment: 1, at: 0.4)
        record("insert span 2 at 0.4")
        _ = try payload.insertControlPoint(segment: 1, at: 0.75)
        record("insert span 2 at 0.75")
        _ = try payload.insertControlPoint(segment: 0, at: 0.45)
        record("insert span 1 at 0.45")
        try payload.deleteControlPoint(FFCurvePointRef(segment: 0, point: 3))
        record("delete span 1 point 4")
        try payload.deleteControlPoint(FFCurvePointRef(segment: 0, point: 4))
        record("delete span 1 point 5")
        try payload.deleteControlPoint(FFCurvePointRef(segment: 1, point: 3))
        record("delete span 2 point 4")
        try payload.deleteControlPoint(FFCurvePointRef(segment: 1, point: 2))
        record("delete span 2 point 3")
        try payload.moveControlPoint(FFCurvePointRef(segment: 0, point: 0), to: point(1, 2))
        record("move span 1 start")
        try payload.moveControlPoint(
            FFCurvePointRef(segment: 1, point: payload.segments[1].controlPoints.count - 1),
            to: point(161, 1)
        )
        record("move span 2 end")

        return (labels, hashes, payload)
    }

    func testSharedJoinMoveFollowsBothSegmentsWithoutMovingTheirOtherPoints() throws {
        var payload = basePayload()
        try payload.moveControlPoint(FFCurvePointRef(segment: 0, point: 3), to: point(82, 1))

        assertPoint(payload.segments[0].controlPoints[3].vector, point(82, 1))
        assertPoint(payload.segments[1].controlPoints[0].vector, point(82, 1))
        assertPoint(payload.segments[0].controlPoints[2].vector, point(60, 30))
        assertPoint(payload.segments[1].controlPoints[1].vector, point(100, -30))
    }

    // MARK: - Curvature comb

    func testWeightChangeIsReflectedInTheCurvatureComb() throws {
        var payload = cubicBezier()
        let before = try XCTUnwrap(payload.curvatureComb(samplesPerSegment: 16, scale: 2))
        let beforeMid = try XCTUnwrap(before.first { abs($0.parameter - 0.5) < 1e-12 })

        // The polynomial cubic's analytic curvature at t = 0.5 is
        // |B' × B''| / |B'|³ = 5400 / 45³.
        let expected = 5400.0 / (45.0 * 45.0 * 45.0)
        XCTAssertEqual(beforeMid.curvature, expected, accuracy: 1e-12)
        assertPoint(beforeMid.point, point(20, 15))
        XCTAssertEqual(beforeMid.combTip.x, beforeMid.point.x, accuracy: 1e-12)
        XCTAssertEqual(
            beforeMid.combTip.y,
            beforeMid.point.y + expected * 2,
            accuracy: 1e-12
        )

        try payload.setWeight(FFCurvePointRef(segment: 0, point: 1), to: 2)
        let after = try XCTUnwrap(payload.curvatureComb(samplesPerSegment: 16, scale: 2))
        let afterMid = try XCTUnwrap(after.first { abs($0.parameter - 0.5) < 1e-12 })

        XCTAssertGreaterThan(
            abs(afterMid.curvature - beforeMid.curvature),
            1e-4,
            "the weight edit did not move the curvature"
        )
        XCTAssertNotEqual(
            afterMid.combTip,
            beforeMid.combTip,
            "the comb tip did not follow the changed curvature"
        )
        for sample in after {
            XCTAssertEqual(
                sample.combTip.x,
                sample.point.x + sample.normal.x * sample.curvature * 2,
                accuracy: 1e-9
            )
            XCTAssertEqual(
                sample.combTip.y,
                sample.point.y + sample.normal.y * sample.curvature * 2,
                accuracy: 1e-9
            )
        }
    }

    // MARK: - Insertion and degree elevation keep the curve

    func testKnotInsertionKeepsEverySampledPointOnTheCurve() throws {
        var payload = weightedCubic()
        let before = payload
        let ref = try payload.insertControlPoint(segment: 0, at: 0.37)

        XCTAssertEqual(ref.segment, 0)
        XCTAssertEqual(payload.segments[0].controlPoints.count, 5)
        XCTAssertEqual(payload.segments[0].kind, .nurbs)
        XCTAssertEqual(payload.segments[0].degree, 3)
        XCTAssertEqual(payload.segments[0].knots.count, 9)

        let oldSamples = try samples(before, segment: 0)
        let newSamples = try samples(payload, segment: 0)
        XCTAssertEqual(oldSamples.count, newSamples.count)
        for (old, new) in zip(oldSamples, newSamples) {
            XCTAssertEqual(old.t, new.t)
            assertPoint(new.point, old.point, accuracy: 1e-9, "t = \(old.t)")
        }

        var bezier = cubicBezier()
        let bezierBefore = bezier
        _ = try bezier.insertControlPoint(segment: 0, at: 0.25)
        XCTAssertEqual(bezier.segments[0].kind, .nurbs)
        XCTAssertEqual(bezier.segments[0].controlPoints.count, 5)
        let bezierOldSamples = try samples(bezierBefore, segment: 0)
        let bezierNewSamples = try samples(bezier, segment: 0)
        for (old, new) in zip(bezierOldSamples, bezierNewSamples) {
            assertPoint(new.point, old.point, accuracy: 1e-9, "bezier t = \(old.t)")
        }
    }

    func testDegreeElevationKeepsEverySampledPointOnTheCurve() throws {
        var bezier = cubicBezier()
        let bezierBefore = bezier
        try bezier.elevateDegree(segment: 0)
        XCTAssertEqual(bezier.segments[0].kind, .bezier)
        XCTAssertEqual(bezier.segments[0].controlPoints.count, 5)
        let bezierOldSamples = try samples(bezierBefore, segment: 0)
        let bezierNewSamples = try samples(bezier, segment: 0)
        for (old, new) in zip(bezierOldSamples, bezierNewSamples) {
            assertPoint(new.point, old.point, accuracy: 1e-9, "bezier t = \(old.t)")
        }

        var nurbs = weightedCubic()
        let nurbsBefore = nurbs
        try nurbs.elevateDegree(segment: 0)
        XCTAssertEqual(nurbs.segments[0].kind, .nurbs)
        XCTAssertEqual(nurbs.segments[0].controlPoints.count, 5)
        XCTAssertEqual(nurbs.segments[0].degree, 4)
        let nurbsOldSamples = try samples(nurbsBefore, segment: 0)
        let nurbsNewSamples = try samples(nurbs, segment: 0)
        for (old, new) in zip(nurbsOldSamples, nurbsNewSamples) {
            assertPoint(new.point, old.point, accuracy: 1e-9, "nurbs t = \(old.t)")
        }
    }

    // MARK: - Knot display and tangent handles

    func testKnotDisplayReportsDegreeMultiplicityAndRationalState() throws {
        var payload = basePayload()
        var display = try payload.knotDisplay(in: 0)

        XCTAssertEqual(display.segment, 0)
        XCTAssertEqual(display.degree, 3)
        XCTAssertEqual(display.controlPointCount, 4)
        XCTAssertFalse(display.isRational)
        XCTAssertEqual(display.knots.count, 8)
        XCTAssertEqual(display.multiplicities, [
            FFKnotMultiplicity(value: 0, count: 4),
            FFKnotMultiplicity(value: 1, count: 4),
        ])

        try payload.setWeight(FFCurvePointRef(segment: 0, point: 1), to: 1.2)
        display = try payload.knotDisplay(in: 0)
        XCTAssertTrue(display.isRational)
        XCTAssertEqual(display.controlPointCount, 4)

        _ = try payload.insertControlPoint(segment: 0, at: 0.25)
        display = try payload.knotDisplay(in: 0)
        XCTAssertEqual(display.controlPointCount, 5)
        XCTAssertEqual(display.knots.count, 9)
        XCTAssertEqual(display.multiplicities, [
            FFKnotMultiplicity(value: 0, count: 4),
            FFKnotMultiplicity(value: 0.25, count: 1),
            FFKnotMultiplicity(value: 1, count: 4),
        ])
    }

    func testTangentHandlesNameTheAdjacentControlPointAndItsEnd() throws {
        let payload = basePayload()
        let handles = try payload.tangentHandles(in: 1)

        XCTAssertEqual(handles.count, 2)
        XCTAssertEqual(handles[0].end, .start)
        assertPoint(handles[0].origin, point(80, 0))
        assertPoint(handles[0].tip, point(100, -30))
        XCTAssertEqual(handles[0].controlPoint, FFCurvePointRef(segment: 1, point: 1))
        XCTAssertEqual(handles[1].end, .end)
        assertPoint(handles[1].origin, point(160, 0))
        assertPoint(handles[1].tip, point(140, -30))
        XCTAssertEqual(handles[1].controlPoint, FFCurvePointRef(segment: 1, point: 2))

        let line = FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(point(0, 0)), FFPoint2(point(10, 0))]
            ),
        ])
        XCTAssertTrue(try line.tangentHandles(in: 0).isEmpty)
    }

    // MARK: - Refusals

    func testControlPointRefusalsLeaveThePayloadUntouched() throws {
        var payload = basePayload()

        let before = payload
        XCTAssertThrowsError(
            try payload.moveControlPoint(FFCurvePointRef(segment: 0, point: 0), to: point(.nan, 0))
        ) { XCTAssertEqual($0 as? FFCurveEditError, .invalidPoint) }
        XCTAssertEqual(payload, before)

        XCTAssertThrowsError(
            try payload.moveControlPoint(FFCurvePointRef(segment: 0, point: 0), to: point(.infinity, 0))
        ) { XCTAssertEqual($0 as? FFCurveEditError, .invalidPoint) }
        XCTAssertEqual(payload, before)

        XCTAssertThrowsError(
            try payload.moveControlPoint(FFCurvePointRef(segment: 2, point: 0), to: point(0, 0))
        ) { XCTAssertEqual($0 as? FFCurveEditError, .noSegment(2)) }
        XCTAssertEqual(payload, before)

        XCTAssertThrowsError(
            try payload.moveControlPoint(FFCurvePointRef(segment: 0, point: 9), to: point(0, 0))
        ) { XCTAssertEqual($0 as? FFCurveEditError, .noPoint(segment: 0, point: 9)) }
        XCTAssertEqual(payload, before)

        for weight in [0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(
                try payload.setWeight(FFCurvePointRef(segment: 0, point: 1), to: weight)
            ) { XCTAssertEqual($0 as? FFCurveEditError, .invalidWeight) }
            XCTAssertEqual(payload, before)
        }

        XCTAssertThrowsError(
            try payload.deleteControlPoint(FFCurvePointRef(segment: 0, point: 0))
        ) { XCTAssertEqual($0 as? FFCurveEditError, .endpoint(segment: 0, point: 0)) }
        XCTAssertEqual(payload, before)

        XCTAssertThrowsError(
            try payload.deleteControlPoint(FFCurvePointRef(segment: 0, point: 3))
        ) { XCTAssertEqual($0 as? FFCurveEditError, .endpoint(segment: 0, point: 3)) }
        XCTAssertEqual(payload, before)

        XCTAssertThrowsError(
            try payload.deleteControlPoint(FFCurvePointRef(segment: 0, point: 1))
        ) { XCTAssertEqual($0 as? FFCurveEditError, .tooFewPoints(segment: 0)) }
        XCTAssertEqual(payload, before)

        for parameter in [0, 1, -0.1, 1.1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(
                try payload.insertControlPoint(segment: 0, at: parameter)
            ) { XCTAssertEqual($0 as? FFCurveEditError, .invalidParameter) }
            XCTAssertEqual(payload, before)
        }
        XCTAssertThrowsError(
            try payload.insertControlPoint(segment: 2, at: 0.5)
        ) { XCTAssertEqual($0 as? FFCurveEditError, .noSegment(2)) }
        XCTAssertEqual(payload, before)
    }

    func testKnotInsertionRefusesAKnotThatHasReachedTheDegree() throws {
        var line = FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(point(0, 0)), FFPoint2(point(10, 0))]
            ),
        ])
        _ = try line.insertControlPoint(segment: 0, at: 0.5)
        let inserted = line

        XCTAssertThrowsError(
            try line.insertControlPoint(segment: 0, at: 0.5)
        ) { XCTAssertEqual($0 as? FFCurveEditError, .cannotInsert(segment: 0)) }
        XCTAssertEqual(line, inserted)
    }

    func testDegreeElevationRefusesAMultiSpanCurve() throws {
        var payload = FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(point(0, 0)),
                    FFPoint2(point(10, 10)),
                    FFPoint2(point(20, 0)),
                    FFPoint2(point(30, 10)),
                    FFPoint2(point(40, 0)),
                ],
                weights: [1, 1, 1, 1, 1],
                degree: 3,
                knots: [0, 0, 0, 0, 0.5, 1, 1, 1, 1]
            ),
        ])
        let before = payload

        XCTAssertThrowsError(try payload.elevateDegree(segment: 0)) {
            XCTAssertEqual($0 as? FFCurveEditError, .notSingleSpan(segment: 0))
        }
        XCTAssertEqual(payload, before)
    }

    // MARK: - Adversarial inputs

    /// A collinear run, a duplicated control point and a curve reduced to two
    /// points are the shapes that make a naive derivative or knot normaliser
    /// divide by zero. Every result must stay finite, and a zero-speed sample
    /// must report zero curvature rather than a NaN comb.
    func testCollinearDuplicateAndTwoPointCurvesStayFinite() throws {
        var collinear = FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(point(0, 0)),
                    FFPoint2(point(10, 0)),
                    FFPoint2(point(20, 0)),
                ],
                weights: [1, 1, 1],
                degree: 2,
                knots: [0, 0, 0, 1, 1, 1]
            ),
        ])
        try collinear.moveControlPoint(FFCurvePointRef(segment: 0, point: 1), to: point(0, 0))
        try collinear.setWeight(FFCurvePointRef(segment: 0, point: 1), to: 2)
        try collinear.elevateDegree(segment: 0)
        _ = try collinear.insertControlPoint(segment: 0, at: 0.5)

        for controlPoint in collinear.segments[0].controlPoints {
            XCTAssertTrue(controlPoint.x.isFinite)
            XCTAssertTrue(controlPoint.y.isFinite)
        }
        for knot in collinear.segments[0].knots {
            XCTAssertTrue(knot.isFinite)
        }
        let collinearComb = try XCTUnwrap(collinear.curvatureComb(samplesPerSegment: 8))
        XCTAssertTrue(collinearComb.allSatisfy { sample in
            sample.curvature.isFinite
                && sample.normal.x.isFinite
                && sample.normal.y.isFinite
                && sample.combTip.x.isFinite
                && sample.combTip.y.isFinite
        })
        XCTAssertNotNil(collinear.path())

        var line = FFCurvePayload(segments: [
            FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(point(0, 0)), FFPoint2(point(20, 0))]
            ),
        ])
        try line.setWeight(FFCurvePointRef(segment: 0, point: 1), to: 2)
        try line.elevateDegree(segment: 0)
        _ = try line.insertControlPoint(segment: 0, at: 0.5)
        XCTAssertEqual(line.segments[0].controlPoints.count, 4)
        let lineCurve = try XCTUnwrap(line.segments[0].curve)
        for step in 0...10 {
            let sample = lineCurve.point(at: Double(step) / 10)
            XCTAssertTrue(sample.x.isFinite)
            XCTAssertTrue(sample.y.isFinite)
        }
        XCTAssertNotNil(line.path())
        XCTAssertThrowsError(try line.deleteControlPoint(FFCurvePointRef(segment: 0, point: 0))) {
            XCTAssertEqual($0 as? FFCurveEditError, .endpoint(segment: 0, point: 0))
        }
    }

    // MARK: - Session ownership

    func testEveryEditingCommandIsOneUndoStep() throws {
        let (document, nodeID) = makeDocument(with: basePayload())
        let session = FFEditorSession(document: document)
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        XCTAssertTrue(session.moveCurveControlPoint(
            nodeID: nodeID,
            segment: 0,
            point: 1,
            to: point(21, 33)
        ))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            original
        )

        XCTAssertTrue(session.setCurveWeight(nodeID: nodeID, segment: 0, point: 1, weight: 1.2))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            original
        )

        XCTAssertTrue(session.insertCurveControlPoint(nodeID: nodeID, segment: 0, at: 0.25))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            original
        )

        XCTAssertTrue(session.elevateCurveDegree(nodeID: nodeID, segment: 0))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            original
        )

        XCTAssertTrue(session.insertCurveControlPoint(nodeID: nodeID, segment: 0, at: 0.25))
        XCTAssertTrue(session.deleteCurveControlPoint(nodeID: nodeID, segment: 0, point: 2))
        XCTAssertEqual(session.documentSession.undoDepth, 2)
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            original
        )
    }

    func testACoalescedDragIsOneUndoStep() throws {
        let (document, nodeID) = makeDocument(with: basePayload())
        let session = FFEditorSession(document: document)
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        XCTAssertTrue(session.moveCurveControlPoint(
            nodeID: nodeID,
            segment: 0,
            point: 1,
            to: point(21, 33),
            coalescingKey: "curve-drag-1"
        ))
        XCTAssertTrue(session.moveCurveControlPoint(
            nodeID: nodeID,
            segment: 0,
            point: 1,
            to: point(24, 36),
            coalescingKey: "curve-drag-1"
        ))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        let dragged = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint
        XCTAssertNotEqual(dragged, original)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            original
        )
        XCTAssertTrue(session.redo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            dragged
        )
    }

    func testWeightEditThroughTheSessionChangesTheCombAndUndoRestoresIt() throws {
        let (document, nodeID) = makeDocument(with: cubicBezier())
        let session = FFEditorSession(document: document)
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint
        let before = try XCTUnwrap(session.curveCurvatureComb(nodeID: nodeID, samplesPerSegment: 16))
        let beforeMid = try XCTUnwrap(before.first { abs($0.parameter - 0.5) < 1e-12 })

        XCTAssertTrue(session.setCurveWeight(nodeID: nodeID, segment: 0, point: 1, weight: 2))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        let after = try XCTUnwrap(session.curveCurvatureComb(nodeID: nodeID, samplesPerSegment: 16))
        let afterMid = try XCTUnwrap(after.first { abs($0.parameter - 0.5) < 1e-12 })
        XCTAssertGreaterThan(abs(afterMid.curvature - beforeMid.curvature), 1e-4)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            original
        )
        let restored = try XCTUnwrap(session.curveCurvatureComb(nodeID: nodeID, samplesPerSegment: 16))
        let restoredMid = try XCTUnwrap(restored.first { abs($0.parameter - 0.5) < 1e-12 })
        XCTAssertEqual(restoredMid.curvature, beforeMid.curvature, accuracy: 1e-12)
    }

    func testLockedCurveRefusesTheEditWithoutCreatingHistory() throws {
        var made = makeDocument(with: basePayload())
        made.0.layers[0].isLocked = true
        let session = FFEditorSession(document: made.0)
        let nodeID = made.1
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        XCTAssertFalse(session.moveCurveControlPoint(
            nodeID: nodeID,
            segment: 0,
            point: 1,
            to: point(21, 33)
        ))
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(session.curveEditMessage, "That curve is on a locked layer")
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint,
            original
        )
    }

    func testEditingOneCurveLeavesAnotherNodeAlone() throws {
        var made = makeDocument(with: basePayload())
        let nodeID = made.1
        let other = FFNode(
            name: "Other curve",
            geometry: .curve(cubicBezier()),
            layerID: made.0.currentLayerID
        )
        made.0.rootNodes.append(other)
        let session = FFEditorSession(document: made.0)
        let otherBefore = try XCTUnwrap(session.document.curvePayload(forNodeID: other.id)).fingerprint

        XCTAssertTrue(session.moveCurveControlPoint(
            nodeID: nodeID,
            segment: 0,
            point: 1,
            to: point(21, 33)
        ))
        XCTAssertEqual(
            try XCTUnwrap(session.document.curvePayload(forNodeID: other.id)).fingerprint,
            otherBefore
        )
    }

    func testEditingASavedCurveStillRebuildsAfterReopen() throws {
        let (document, nodeID) = makeDocument(with: basePayload())
        let session = FFEditorSession(document: document)
        XCTAssertTrue(session.moveCurveControlPoint(
            nodeID: nodeID,
            segment: 0,
            point: 1,
            to: point(21, 33)
        ))
        let edited = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))

        let data = try JSONEncoder().encode(session.document)
        let reopened = try JSONDecoder().decode(FFDocument.self, from: data)
        let decoded = try XCTUnwrap(reopened.curvePayload(forNodeID: nodeID))

        XCTAssertEqual(decoded.fingerprint, edited.fingerprint)
        XCTAssertNotNil(decoded.path())
        let curve = try XCTUnwrap(decoded.segments[0].curve)
        let editedCurve = try XCTUnwrap(edited.segments[0].curve)
        XCTAssertEqual(curve.point(at: 0.5).x, editedCurve.point(at: 0.5).x, accuracy: 1e-12)
    }
}
