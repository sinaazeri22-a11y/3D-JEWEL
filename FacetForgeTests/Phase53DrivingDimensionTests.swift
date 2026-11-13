import Foundation
import XCTest
@testable import FacetForge

/// Phase 53's acceptance: a typed dimension drives geometry to within 1e-6 of
/// the value, a locked dimension survives an accidental drag, and the readout is
/// unit-aware.
///
/// The premise of a lock is stated in the API and repeated here because it is the
/// whole behaviour: a locked dimension is a hard row in every solve, and an
/// unlocked one is a readout re-measured from the solved geometry. A drag is
/// therefore a starting guess, not a command, and the solver decides how much of
/// it the locks allow.
///
/// Every expected number below was measured in an independent local model of the
/// same algebra before these assertions existed, and each one states where it
/// comes from:
///
/// - An exactly 10 mm span on the x axis measures 10.000 mm, and 10 mm is
///   0.39370 in at the five-decimal inch policy, which is the unit-aware display.
/// - The drag fixture is `(0,0), (10,0), (10.2,4.6)` with a locked 10 mm first
///   span and a reference second span of `sqrt(0.04 + 21.16) = 4.604345773` mm.
///   Dragging the shared vertex 3 mm along +Y solved in one iteration with a
///   residual of 2.201e-11, holding the locked span at 10.000000000022 mm,
///   landing the shared vertex at `(9.789131452, 2.936739416)` with the far end
///   still at `(10.2, 4.6)`, and taking the reference to 1.713256751863 mm. So
///   the lock is asserted at 1e-9 and the solved coordinates and reference at
///   1e-6, while the row's own 1e-6 clause is asserted on the typed value.
/// - The angle fixture is 74.357753543 degrees as drawn (a 105.642246457 degree
///   turn folded into 0...90) and 60.000000040 degrees after a typed 60 at a
///   residual of 7.0e-10, so the assertion is 1e-6 against the typed value.
/// - A radius of 5 driven to 12 agrees with the primitive to 8.0e-10.
final class Phase53DrivingDimensionTests: XCTestCase {
    // MARK: - Helpers

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    private func sketchPayload(_ points: [Vec2], isClosed: Bool = false) -> FFCurvePayload {
        var segments: [FFCurveSegment] = []
        for index in 1..<points.count {
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(points[index - 1]), FFPoint2(points[index])]
            ))
        }
        if isClosed, points.count > 2 {
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(points[points.count - 1]), FFPoint2(points[0])]
            ))
        }
        return FFCurvePayload(segments: segments, isClosed: isClosed)
    }

    private func makeSketchSession(
        _ points: [Vec2],
        unit: FFLengthUnit = .millimetres,
        isClosed: Bool = false
    ) -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 53")
        document.displayUnit = unit
        let node = FFNode(
            name: "Dimensioned sketch",
            geometry: .curve(sketchPayload(points, isClosed: isClosed)),
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        return (FFEditorSession(document: document), node.id)
    }

    private func makeCircleSession(centre: Vec2, radius: Double) throws -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 53 circle")
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

    private func spanLength(_ payload: FFCurvePayload, _ index: Int) -> Double {
        let ends = payload.segments[index].controlPoints
        return ends[0].vector.distance(to: ends[1].vector)
    }

    /// The angle two spans meet at, measured the way the solver measures it: the
    /// fold of the signed turn between the two segment directions, so a +60 and a
    /// -60 turn are the same 60 degree relation (Phase 52's `lineAngle` row).
    private func lineDegrees(_ payload: FFCurvePayload, _ first: Int, _ second: Int) -> Double {
        let a = payload.segments[first].controlPoints
        let b = payload.segments[second].controlPoints
        let aStart = a[0].vector
        let aEnd = a[1].vector
        let bStart = b[0].vector
        let bEnd = b[1].vector
        let u = (aEnd - aStart) / aEnd.distance(to: aStart)
        let v = (bEnd - bStart) / bEnd.distance(to: bStart)
        let turn = atan2(u.cross(v), u.dot(v))
        let folded = FFSketchSystemSolver.foldAngle(FFSketchSystemSolver.wrapAngle(turn))
        return abs(folded) * 180 / .pi
    }

    private func dimensions(_ session: FFEditorSession, _ nodeID: UUID) -> [FFDimensionAnnotation] {
        session.document.dimensionAnnotations(forNodeID: nodeID)
    }

    // MARK: - Adding a dimension

    func testAddingADimensionRecordsTheMeasuredValueAndMovesNothing() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(10, 0)])
        let before = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint

        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: false)
        ))
        XCTAssertEqual(session.documentSession.undoDepth, 1)
        XCTAssertNil(session.dimensionMessage)

        let stored = try XCTUnwrap(dimensions(session, nodeID).first)
        XCTAssertEqual(stored.kind, .distance)
        XCTAssertEqual(stored.value, 10, accuracy: 1e-12, "the added value is the measurement")
        XCTAssertFalse(stored.isLocked)
        XCTAssertEqual(stored.summary(unit: .millimetres), "10.000 mm")

        // Adding a dimension records what is there; it never moves the sketch.
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            before
        )
        XCTAssertTrue(session.documentStatus.hasPrefix("Dimension · 10.000 mm"))

        XCTAssertTrue(session.undo())
        XCTAssertTrue(dimensions(session, nodeID).isEmpty)
        XCTAssertEqual(session.documentSession.undoDepth, 0)
    }

    func testTheReadoutIsUnitAwareWithoutAStoredSecondNumber() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(10, 0)])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: true)
        ))

        let document = session.document
        let stored = try XCTUnwrap(document.dimensionAnnotations(forNodeID: nodeID).first)
        // One stored number of millimetres, two honest sentences. 10 mm is
        // 10.000 mm, and 10 / 25.4 = 0.393700787... at five decimals is 0.39370.
        XCTAssertEqual(stored.summary(unit: .millimetres), "10.000 mm")
        XCTAssertEqual(stored.summary(unit: .inches), "0.39370 in")
        XCTAssertEqual(stored.value, 10, accuracy: 1e-12)
        XCTAssertEqual(stored.kind, .distance)
    }

    func testAnAngleReadoutKeepsTheAngleTwoLinesMeetAt() throws {
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(5, 0), point(4.3, 2.5),
        ])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.angle(first: 0, second: 1), isLocked: false)
        ))
        let stored = try XCTUnwrap(dimensions(session, nodeID).first)
        // The drawn line angle, folded into 0...90: the fold of the 105.642246457
        // degree turn between (0,0)-(5,0) and (5,0)-(4.3,2.5) is 74.357753543,
        // measured by the model from the same three vertices.
        XCTAssertEqual(stored.value, 74.357754, accuracy: 1e-6)
        XCTAssertEqual(stored.summary(unit: .millimetres), "74.36°")
    }

    func testARadiusDimensionTargetsACircle() throws {
        let (session, nodeID) = try makeCircleSession(centre: point(3.5, -2), radius: 5)
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.radius(circle: 0), isLocked: false)
        ))
        let stored = try XCTUnwrap(dimensions(session, nodeID).first)
        XCTAssertEqual(stored.kind, .radius)
        XCTAssertEqual(stored.value, 5, accuracy: 1e-12)
        XCTAssertEqual(stored.summary(unit: .millimetres), "R 5.000 mm")
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.segments.count,
            4,
            "recording a radius must not reshape the four quarter spans"
        )
    }

    // MARK: - A typed value drives geometry

    func testATypedDistanceDrivesTheGeometryToWithinAMicrometre() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(8.4, 0.6)])
        let original = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: false)
        ))
        let id = try XCTUnwrap(dimensions(session, nodeID).first?.id)

        XCTAssertTrue(session.applyDimension(nodeID: nodeID, command: .setValue(id, 12)))
        XCTAssertEqual(session.documentSession.undoDepth, 2, "add and edit are two steps")

        let payload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(spanLength(payload, 0), 12, accuracy: 1e-6, "the row's clause")
        XCTAssertEqual(spanLength(payload, 0), 12, accuracy: 1e-9, "the solver's resolution")
        XCTAssertEqual(try XCTUnwrap(dimensions(session, nodeID).first).value, 12, accuracy: 1e-12)
        let resolution = try XCTUnwrap(session.lastDimensionResolution)
        XCTAssertLessThanOrEqual(resolution.residual, 1e-9)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            original,
            "one undo must restore the geometry the dimension was added to"
        )
        // Undoing the edit puts back the value the add recorded: the measurement
        // of (0,0)-(8.4,0.6), which is sqrt(70.92) = 8.421401 mm.
        XCTAssertEqual(try XCTUnwrap(dimensions(session, nodeID).first).value, 8.421401, accuracy: 1e-5)
    }

    func testATypedAngleDrivesTheGeometryToWithinAMicrometre() throws {
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(5, 0), point(4.3, 2.5),
        ])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.angle(first: 0, second: 1), isLocked: true)
        ))
        let id = try XCTUnwrap(dimensions(session, nodeID).first?.id)

        XCTAssertTrue(session.applyDimension(nodeID: nodeID, command: .setValue(id, 60)))
        let payload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(lineDegrees(payload, 0, 1), 60, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(dimensions(session, nodeID).first).summary(unit: .millimetres), "60.00°")
    }

    func testATypedRadiusDrivesThePrimitiveAndItsPayload() throws {
        let (session, nodeID) = try makeCircleSession(centre: point(3.5, -2), radius: 5)
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.radius(circle: 0), isLocked: true)
        ))
        let id = try XCTUnwrap(dimensions(session, nodeID).first?.id)

        XCTAssertTrue(session.applyDimension(nodeID: nodeID, command: .setValue(id, 12)))
        let primitive = try XCTUnwrap(session.document.node(withID: nodeID)?.curvePrimitive)
        XCTAssertEqual(primitive.radius, 12, accuracy: 1e-6)
        XCTAssertEqual(primitive.center.vector.distance(to: point(3.5, -2)), 0, accuracy: 1e-9)

        let payload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(payload.segments.count, 4)
        XCTAssertTrue(payload.isClosed)
        let start = payload.segments[0].controlPoints[0].vector
        XCTAssertEqual(start.distance(to: point(3.5 + 12, -2)), 0, accuracy: 1e-6)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(
            try XCTUnwrap(session.document.node(withID: nodeID)?.curvePrimitive).radius,
            5,
            accuracy: 1e-6,
            "one undo puts the primitive back with the payload it came with"
        )
    }

    // MARK: - The lock is a hard row of every solve

    func testAConstraintSolveStillHoldsALockedDimension() throws {
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(10, 0), point(10.2, 4.6),
        ])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: true)
        ))

        // A Phase 51 horizontal row on the slanted span rotates the sketch. The
        // lock is a row of that solve too, so the 10 mm span is not a casualty:
        // the model solved it in 5 iterations at a residual of 1.8e-15, keeping
        // the locked span at 10.000000000000 and the second span's dy at 8.9e-16.
        XCTAssertTrue(session.constrainSketch(nodeID: nodeID, constraints: [.horizontal(segment: 1)]))
        let payload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(spanLength(payload, 0), 10, accuracy: 1e-9)
        let second = payload.segments[1].controlPoints
        XCTAssertEqual(second[1].vector.y, second[0].vector.y, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(dimensions(session, nodeID).first).value, 10, accuracy: 1e-12)
    }

    func testAPayloadTopologyChangeDropsTheDimensionRecords() throws {
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(10, 0), point(10, 6),
        ])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: true)
        ))
        XCTAssertEqual(dimensions(session, nodeID).count, 1)

        // A fillet replaces the shared vertex, so the payload gains a span and
        // the level indices a dimension names no longer describe the same curve.
        // The records go in the same mutation rather than pointing at a new span.
        XCTAssertNotNil(session.treatCurveCorner(nodeID: nodeID, corner: 0, treatment: .fillet(radius: 2)))
        XCTAssertTrue(dimensions(session, nodeID).isEmpty)
        XCTAssertNil(session.document.node(withID: nodeID)?.dimensions)
    }

    // MARK: - Locks and drags

    func testALockedDimensionSurvivesAnAccidentalDrag() throws {
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(10, 0), point(10.2, 4.6),
        ])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: true)
        ))
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(1), to: .point(2)), isLocked: false)
        ))
        let locked = try XCTUnwrap(dimensions(session, nodeID).first)
        XCTAssertTrue(locked.isLocked)
        XCTAssertEqual(dimensions(session, nodeID).count, 2)
        let reference = try XCTUnwrap(dimensions(session, nodeID).last)
        XCTAssertEqual(reference.value, 4.604345773, accuracy: 1e-6)

        // The shared vertex is dragged 3 mm along +Y. Segment 0's second control
        // point is that vertex.
        XCTAssertTrue(session.moveCurveControlPoint(
            nodeID: nodeID,
            segment: 0,
            point: 1,
            to: point(10, 3)
        ))
        XCTAssertEqual(session.documentSession.undoDepth, 3, "add, add and the drag")

        let payload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(spanLength(payload, 0), 10, accuracy: 1e-9, "the lock held")
        let dragged = payload.segments[0].controlPoints[1].vector
        // Model: one iteration, residual 2.201e-11, the shared vertex settles at
        // (9.789131452, 2.936739416) and the far end stays put. The premise is
        // that this is the same solver: a driving row, its Jacobian, the gauge.
        XCTAssertEqual(dragged.x, 9.789131452, accuracy: 1e-6)
        XCTAssertEqual(dragged.y, 2.936739416, accuracy: 1e-6)
        XCTAssertGreaterThan(
            abs(dragged.y - 0), 1,
            "the drag must actually move the sketch, not be swallowed by the lock"
        )
        XCTAssertEqual(payload.segments[1].controlPoints[1].vector.y, 4.6, accuracy: 1e-9)

        let updated = try XCTUnwrap(dimensions(session, nodeID).last)
        XCTAssertEqual(updated.value, 1.713256752, accuracy: 1e-6, "the readout followed the geometry")
        XCTAssertTrue(updated.isLocked == false)
        XCTAssertEqual(try XCTUnwrap(dimensions(session, nodeID).first).value, 10, accuracy: 1e-12)

        XCTAssertTrue(session.undo())
        let restored = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(spanLength(restored, 0), 10, accuracy: 1e-9)
        XCTAssertEqual(restored.segments[0].controlPoints[1].vector.distance(to: point(10, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(dimensions(session, nodeID).last).value, 4.604345773, accuracy: 1e-6)
    }

    func testAnUnlockedDimensionIsAReadoutNotAHardRow() throws {
        // The same fixture, but the second dimension is unlocked and the first is
        // too. A drag with no lock moves the sketch and both readouts follow.
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(10, 0.4), point(10.2, 5),
        ])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: false)
        ))
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(1), to: .point(2)), isLocked: false)
        ))
        XCTAssertTrue(session.moveCurveControlPoint(
            nodeID: nodeID,
            segment: 0,
            point: 1,
            to: point(10, 3.4)
        ))
        // No lock means the plain point move: the first span is no longer 10 mm,
        // and both readouts have followed the geometry they describe.
        let payload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        let first = spanLength(payload, 0)
        let second = spanLength(payload, 1)
        XCTAssertEqual(first, (100.0 + 3.4 * 3.4).squareRoot(), accuracy: 1e-9)
        XCTAssertGreaterThan(abs(first - 10), 0.5, "with no lock the drag is not corrected")
        let stored = dimensions(session, nodeID)
        XCTAssertEqual(stored[0].value, first, accuracy: 1e-9, "a readout follows the geometry")
        XCTAssertEqual(stored[1].value, second, accuracy: 1e-9)
    }

    // MARK: - Locking and refusals

    func testLockingDrivesTheStoredValueAndUnlockingStopsIt() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(8.4, 0.6)])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: false)
        ))
        let id = try XCTUnwrap(dimensions(session, nodeID).first?.id)

        XCTAssertTrue(session.applyDimension(nodeID: nodeID, command: .setLocked(id, true)))
        XCTAssertTrue(try XCTUnwrap(dimensions(session, nodeID).first).isLocked)
        let lockedPayload = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(
            spanLength(lockedPayload, 0),
            8.421401,
            accuracy: 1e-6,
            "locking holds the measured value, it does not change it"
        )

        XCTAssertTrue(session.applyDimension(nodeID: nodeID, command: .setLocked(id, false)))
        XCTAssertFalse(try XCTUnwrap(dimensions(session, nodeID).first).isLocked)
        XCTAssertEqual(
            session.document.curvePayload(forNodeID: nodeID)?.fingerprint,
            lockedPayload.fingerprint,
            "unlocking changes the record, not the shape"
        )
    }

    func testAConflictingLockIsRefusedAndWritesNothing() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(10, 0)])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: true)
        ))
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: false)
        ))
        let second = try XCTUnwrap(dimensions(session, nodeID).last?.id)
        let before = try XCTUnwrap(session.document.curvePayload(forNodeID: nodeID)).fingerprint
        let depth = session.documentSession.undoDepth

        // Typing 12 on the second distance binds it beside the locked 10 mm, and
        // one span cannot be two lengths at once.
        XCTAssertFalse(session.applyDimension(nodeID: nodeID, command: .setValue(second, 12)))
        XCTAssertEqual(session.documentSession.undoDepth, depth)
        XCTAssertTrue((session.dimensionMessage ?? "").contains("over-constrains"))
        XCTAssertEqual(session.document.curvePayload(forNodeID: nodeID)?.fingerprint, before)
        XCTAssertEqual(try XCTUnwrap(dimensions(session, nodeID).last).value, 10, accuracy: 1e-12)
    }

    func testADimensionRefusesANonPositiveValue() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(10, 0)])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: true)
        ))
        let id = try XCTUnwrap(dimensions(session, nodeID).first?.id)

        XCTAssertFalse(session.applyDimension(nodeID: nodeID, command: .setValue(id, 0)))
        XCTAssertEqual(session.dimensionMessage, "A distance must be greater than zero")
        XCTAssertFalse(session.applyDimension(nodeID: nodeID, command: .setValue(id, -4)))
        XCTAssertEqual(session.dimensionMessage, "A distance must be greater than zero")
        XCTAssertEqual(session.documentSession.undoDepth, 1, "only the add was recorded")
    }

    func testADimensionRefusesAnAngleOutsideTheLineRange() throws {
        let (session, nodeID) = makeSketchSession([
            point(0, 0), point(5, 0), point(4.3, 2.5),
        ])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.angle(first: 0, second: 1), isLocked: true)
        ))
        let id = try XCTUnwrap(dimensions(session, nodeID).first?.id)
        XCTAssertFalse(session.applyDimension(nodeID: nodeID, command: .setValue(id, 120)))
        XCTAssertEqual(
            session.dimensionMessage,
            "An angle of 120.0° is outside 0-90 degrees, the angle two lines meet at"
        )
        XCTAssertEqual(try XCTUnwrap(dimensions(session, nodeID).first).value, 74.357754, accuracy: 1e-6)
    }

    func testAnUnknownDimensionIsRefused() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(10, 0)])
        XCTAssertFalse(session.applyDimension(
            nodeID: nodeID,
            command: .setValue(UUID(), 12)
        ))
        XCTAssertEqual(session.dimensionMessage, "That dimension is not on this sketch")
        XCTAssertEqual(session.documentSession.undoDepth, 0)
    }

    func testANonSketchNodeCannotBeDimensioned() throws {
        var document = FFDocument(name: "Phase 53 mesh")
        let node = FFNode(
            name: "Stone",
            geometry: .mesh(FFMeshPayload(positions: [], triangles: [])),
            kind: .stone,
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        let session = FFEditorSession(document: document)
        XCTAssertFalse(session.applyDimension(
            nodeID: node.id,
            command: .add(.radius(circle: 0), isLocked: false)
        ))
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertFalse((session.dimensionMessage ?? "").isEmpty)
    }

    // MARK: - The document

    func testADimensionedSketchSurvivesSaveAndReopen() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(10, 0), point(10, 6)])
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.distance(from: .point(0), to: .point(1)), isLocked: true)
        ))
        XCTAssertTrue(session.applyDimension(
            nodeID: nodeID,
            command: .add(.angle(first: 0, second: 1), isLocked: false)
        ))
        let stored = dimensions(session, nodeID)
        XCTAssertEqual(stored.count, 2)

        let data = try JSONEncoder().encode(session.document)
        let reopened = try JSONDecoder().decode(FFDocument.self, from: data)
        let decoded = reopened.dimensionAnnotations(forNodeID: nodeID)
        XCTAssertEqual(decoded, stored)
        XCTAssertTrue(decoded[0].isLocked)
        XCTAssertFalse(decoded[1].isLocked)

        // The reopened document still drives: a typed 4 on the distance moves the
        // payload, which is what makes the record live state rather than a note.
        let fresh = FFEditorSession(document: reopened)
        XCTAssertTrue(fresh.applyDimension(nodeID: nodeID, command: .setValue(decoded[0].id, 4)))
        let payload = try XCTUnwrap(fresh.document.curvePayload(forNodeID: nodeID))
        XCTAssertEqual(spanLength(payload, 0), 4, accuracy: 1e-6)
    }

    func testADocumentWithoutDimensionsKeepsItsCanonicalShape() throws {
        let (session, nodeID) = makeSketchSession([point(0, 0), point(10, 0)])
        XCTAssertTrue(session.document.curvePayload(forNodeID: nodeID) != nil)
        let data = try JSONEncoder().encode(session.document)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(
            text.contains("\"dimensions\""),
            "an untouched document must not gain a field it never used"
        )
        XCTAssertNil(session.document.node(withID: nodeID)?.dimensions)
    }
}
