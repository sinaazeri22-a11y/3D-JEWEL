import Foundation
import XCTest
@testable import FacetForge

/// Phase 50's acceptance: sketching on a tilted face produces curves in that
/// plane, and cancelling removes all sketch geometry in one undo.
///
/// The expected numbers are derived before the assertions exist. A local model of
/// the exact `T * Rz * Ry * Rx * S` composition measured the plane-to-node
/// placement at 1.2e-16 rotation error on the six axis-aligned normals (four of
/// which take `FFTransform`'s pinned-roll branch), 2.8e-15 over 20,000 random
/// frames, and 1.1e-13 mm for a placed sketch point at coordinates up to 80 mm.
/// The geometry assertions therefore sit at 1e-9 mm and the rotation assertions at
/// 1e-12 — four orders above that measured noise, never at the ideal geometry.
/// The camera-resolved checks get their own 1e-6 bound because the camera's
/// inverse is what produces those numbers, not the plane maths.
final class Phase50SketchPlaneTests: XCTestCase {
    /// A deterministic generator, so a failing frame is reproducible from the log.
    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func double(in range: ClosedRange<Double>) -> Double {
            let unit = Double(next() >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }

        mutating func vector(component: ClosedRange<Double>) -> Vec3 {
            Vec3(
                x: double(in: component),
                y: double(in: component),
                z: double(in: component)
            )
        }
    }

    private let store = FFDocumentStore()
    private let fileManager = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase50-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func curvePayloads(in document: FFDocument) -> [FFCurvePayload] {
        document.rootNodes.compactMap { $0.geometry?.curve }
    }

    /// A ray that comes straight down the plane's normal at one of its points, so
    /// its hit is that point with no camera in the way.
    private func normalRay(_ plane: FFPlane3D, at point: Vec2, above: Double = 40) -> Ray? {
        Ray(origin: plane.embed(point) + plane.normal * above, direction: plane.normal * -1)
    }

    /// The six axis-aligned normals plus a set the generator produces. The
    /// axis-aligned ones matter because four of them take the decomposition's
    /// pinned-roll branch.
    private func frames(count: Int) -> [(String, FFPlane3D)] {
        var result: [(String, FFPlane3D)] = []
        let axisAligned: [(String, Vec3)] = [
            ("+X", Vec3(x: 1, y: 0, z: 0)),
            ("-X", Vec3(x: -1, y: 0, z: 0)),
            ("+Y", Vec3(x: 0, y: 1, z: 0)),
            ("-Y", Vec3(x: 0, y: -1, z: 0)),
            ("+Z", Vec3(x: 0, y: 0, z: 1)),
            ("-Z", Vec3(x: 0, y: 0, z: -1)),
        ]
        for (name, normal) in axisAligned {
            if let plane = try? FFPlane3D.facePlane(
                origin: Vec3(x: 7, y: -3, z: 2),
                normal: normal
            ) {
                result.append((name, plane))
            }
        }
        var generator = Generator(seed: 0x50_2026_11_11)
        for index in 0..<count {
            let normal = generator.vector(component: -1...1)
            let origin = generator.vector(component: -100...100)
            if let plane = try? FFPlane3D.facePlane(origin: origin, normal: normal) {
                result.append(("random \(index)", plane))
            }
        }
        return result
    }

    // MARK: - Three sources

    func testFaceSourceKeepsTheFacePlane() throws {
        let normal = Vec3(x: 0.3, y: 0.6, z: 0.8)
        let origin = Vec3(x: 4, y: -2, z: 3)
        let plane = try FFPlane3D.workPlane(.face(origin: origin, normal: normal))

        XCTAssertEqual(plane.origin, origin)
        XCTAssertEqual(plane.normal.length, 1, accuracy: 1e-12)
        // Parallel to the face normal, in whichever sign the frame chose.
        XCTAssertEqual(abs(plane.normal.dot(normal.normalized() ?? normal)), 1, accuracy: 1e-12)
        XCTAssertEqual(plane.signedDistance(of: origin), 0, accuracy: 1e-12)
    }

    func testAxisSourceIsPerpendicularToTheAxis() throws {
        let axis = Vec3(x: 0.2, y: 0.1, z: 1)
        let origin = Vec3(x: 2, y: 3, z: -7)
        let plane = try FFPlane3D.workPlane(.axis(origin: origin, direction: axis))

        // The premise, stated in the source: an axis alone names the plane
        // perpendicular to it, because the planes containing a line are a
        // one-parameter family.
        XCTAssertEqual(plane.normal.cross(axis.normalized() ?? axis).length, 0, accuracy: 1e-12)
        XCTAssertEqual(abs(plane.normal.dot(axis.normalized() ?? axis)), 1, accuracy: 1e-12)
        XCTAssertEqual(plane.signedDistance(of: origin), 0, accuracy: 1e-12)
        // The axis is the plane's normal, so it projects onto the plane's own
        // origin: a point one axis-length along it has no in-plane component.
        // (A point along an in-plane direction is the one that stays at zero.)
        let alongAxis = plane.coordinates(of: origin + axis)
        XCTAssertEqual(alongAxis.x, 0, accuracy: 1e-12)
        XCTAssertEqual(alongAxis.y, 0, accuracy: 1e-12)
        XCTAssertEqual(plane.signedDistance(of: origin + plane.xAxis), 0, accuracy: 1e-12)
    }

    func testThreePointSourceContainsAllThreePoints() throws {
        let first = Vec3(x: 1, y: 2, z: 3)
        let second = Vec3(x: 11, y: 2, z: 3)
        let third = Vec3(x: 1, y: 2, z: 13)
        let plane = try FFPlane3D.workPlane(.threePoints(first, second, third))

        XCTAssertEqual(plane.origin, first)
        for point in [first, second, third] {
            XCTAssertEqual(plane.signedDistance(of: point), 0, accuracy: 1e-9)
        }
        // a -> b is the x axis, so the second point sits on +x at its own length.
        XCTAssertEqual(plane.coordinates(of: second).x, 10, accuracy: 1e-12)
        XCTAssertEqual(plane.coordinates(of: second).y, 0, accuracy: 1e-12)
        XCTAssertEqual(plane.coordinates(of: third).x, 0, accuracy: 1e-12)
        XCTAssertEqual(plane.coordinates(of: third).y, 10, accuracy: 1e-12)
    }

    func testEveryFrameIsOrthonormalAndRightHanded() {
        for (name, plane) in frames(count: 60) {
            XCTAssertEqual(plane.xAxis.length, 1, accuracy: 1e-12, name)
            XCTAssertEqual(plane.yAxis.length, 1, accuracy: 1e-12, name)
            XCTAssertEqual(plane.normal.length, 1, accuracy: 1e-12, name)
            XCTAssertEqual(plane.xAxis.dot(plane.yAxis), 0, accuracy: 1e-12, name)
            XCTAssertEqual(plane.xAxis.cross(plane.yAxis).cross(plane.normal).length, 0, accuracy: 1e-12, name)
        }
    }

    // MARK: - Refusals

    func testRefusalsCarrySentences() {
        let zero = Vec3(x: 0, y: 0, z: 0)
        let first = Vec3(x: 0, y: 0, z: 0)
        let second = Vec3(x: 10, y: 0, z: 0)

        XCTAssertThrowsError(try FFPlane3D.workPlane(.face(origin: .zero, normal: zero))) { error in
            XCTAssertEqual(error as? FFWorkPlaneError, FFWorkPlaneError.degenerateNormal)
        }
        XCTAssertThrowsError(try FFPlane3D.workPlane(.axis(origin: .zero, direction: zero))) { error in
            XCTAssertEqual(error as? FFWorkPlaneError, FFWorkPlaneError.degenerateAxis)
        }
        XCTAssertThrowsError(try FFPlane3D.workPlane(.threePoints(first, first, second))) { error in
            XCTAssertEqual(error as? FFWorkPlaneError, FFWorkPlaneError.coincidentPoints(1, 2))
        }
        XCTAssertThrowsError(try FFPlane3D.workPlane(.threePoints(first, second, first))) { error in
            XCTAssertEqual(error as? FFWorkPlaneError, FFWorkPlaneError.coincidentPoints(1, 3))
        }
        // Collinear, and near-collinear inside the curve kernel's join tolerance:
        // both have no normal that is not noise.
        XCTAssertThrowsError(
            try FFPlane3D.workPlane(.threePoints(first, second, Vec3(x: 5, y: 0, z: 0)))
        ) { error in
            XCTAssertEqual(error as? FFWorkPlaneError, FFWorkPlaneError.collinearPoints)
        }
        XCTAssertThrowsError(
            try FFPlane3D.workPlane(.threePoints(first, second, Vec3(x: 5, y: 1e-8, z: 0)))
        ) { error in
            XCTAssertEqual(error as? FFWorkPlaneError, FFWorkPlaneError.collinearPoints)
        }
        XCTAssertThrowsError(
            try FFPlane3D.workPlane(.face(origin: Vec3(x: .nan, y: 0, z: 0), normal: Vec3(x: 0, y: 0, z: 1)))
        ) { error in
            XCTAssertEqual(error as? FFWorkPlaneError, FFWorkPlaneError.nonFiniteInput)
        }

        let sentences = [
            FFWorkPlaneError.degenerateNormal,
            .degenerateAxis,
            .coincidentPoints(1, 2),
            .collinearPoints,
            .nonFiniteInput,
            .unreachablePlane,
            .sketchNotLocked,
        ].compactMap(\.errorDescription)
        XCTAssertEqual(sentences.count, 7)
        XCTAssertEqual(Set(sentences).count, 7, "every refusal needs its own sentence")
        XCTAssertTrue(sentences.allSatisfy { !$0.isEmpty })
    }

    func testThreePointDraftRemovesARefusedTap() throws {
        var draft = FFSketchPlaneDraft()
        draft.begin(.threePoints)
        let first = Vec3(x: 0, y: 0, z: 0)
        let second = Vec3(x: 10, y: 0, z: 0)
        let third = Vec3(x: 0, y: 10, z: 0)

        XCTAssertNil(try draft.add(first))
        XCTAssertNil(try draft.add(second))
        XCTAssertEqual(draft.tapCount, 2)
        XCTAssertThrowsError(try draft.add(first)) { error in
            XCTAssertEqual(error as? FFWorkPlaneError, FFWorkPlaneError.coincidentPoints(1, 3))
        }
        XCTAssertEqual(draft.tapCount, 2, "a refused tap must be removed again")
        let plane = try XCTUnwrap(try draft.add(third))
        XCTAssertTrue(draft.isComplete)
        XCTAssertEqual(draft.plane, plane)
        for point in [first, second, third] {
            XCTAssertEqual(plane.signedDistance(of: point), 0, accuracy: 1e-9)
        }

        draft.cancel()
        XCTAssertTrue(draft.points.isEmpty)
        XCTAssertNil(draft.plane)
    }

    func testDraftResolvesFaceAndAxisWithoutTaps() throws {
        var draft = FFSketchPlaneDraft()
        draft.begin(.threePoints)
        let face = try draft.takeFace(
            origin: Vec3(x: 1, y: 1, z: 1),
            normal: Vec3(x: 0, y: 0, z: 1)
        )
        XCTAssertEqual(draft.mode, .face)
        XCTAssertEqual(draft.plane, face)
        XCTAssertTrue(draft.isComplete)

        let axis = try draft.takeAxis(
            origin: Vec3(x: 0, y: 0, z: 0),
            direction: Vec3(x: 0, y: 1, z: 0)
        )
        XCTAssertEqual(draft.mode, .axis)
        XCTAssertEqual(draft.plane, axis)
        XCTAssertEqual(abs(axis.normal.y), 1, accuracy: 1e-12)
    }

    // MARK: - Plane to node placement

    func testPlacementRoundTripsEverySketchPoint() {
        let probes = [Vec2(x: 0, y: 0), Vec2(x: 12, y: -7), Vec2(x: -45, y: 33), Vec2(x: 70, y: 10)]
        var worstPoint = 0.0
        var worstColumn = 0.0

        for (name, plane) in frames(count: 40) {
            let placement = plane.nodePlacement
            let matrix = placement.matrix
            let columns: [(Vec3, Vec3)] = [
                (plane.xAxis, Vec3(x: matrix.m00, y: matrix.m10, z: matrix.m20)),
                (plane.yAxis, Vec3(x: matrix.m01, y: matrix.m11, z: matrix.m21)),
                (plane.normal, Vec3(x: matrix.m02, y: matrix.m12, z: matrix.m22)),
            ]
            for (expected, actual) in columns {
                for component in [actual.x - expected.x, actual.y - expected.y, actual.z - expected.z] {
                    worstColumn = max(worstColumn, abs(component))
                }
            }
            for probe in probes {
                let placed = matrix.transformedPoint(Vec3(x: probe.x, y: probe.y, z: 0))
                let embedded = plane.embed(probe)
                let error = max(
                    abs(placed.x - embedded.x),
                    abs(placed.y - embedded.y),
                    abs(placed.z - embedded.z)
                )
                worstPoint = max(worstPoint, error)
                XCTAssertLessThanOrEqual(error, 1e-9, "\(name) at \(probe)")
            }
        }

        // The local model measured 2.8e-15 rotation error and 1.1e-13 mm for a
        // placed point; these are budgets four orders above the measurement, not
        // the measurement restated.
        XCTAssertLessThanOrEqual(worstColumn, 1e-12)
        XCTAssertLessThanOrEqual(worstPoint, 1e-9)
    }

    func testPlacementHandlesThePinnedRollBranch() throws {
        // A normal along +X gives the frame a vertical x axis, which is exactly
        // the case `FFTransform(matrix:)` answers by pinning roll and putting the
        // whole turn in yaw. Four of the six axis-aligned normals do this.
        let plane = try FFPlane3D.facePlane(
            origin: Vec3(x: 5, y: -1, z: 2),
            normal: Vec3(x: 1, y: 0, z: 0)
        )
        XCTAssertEqual(abs(plane.xAxis.z), 1, accuracy: 1e-12)
        let placement = plane.nodePlacement
        XCTAssertEqual(abs(placement.rotation.x), 0, accuracy: 1e-15)
        XCTAssertEqual(abs(placement.rotation.y), Double.pi / 2, accuracy: 1e-12)

        for probe in [Vec2(x: 0, y: 0), Vec2(x: 9, y: -13), Vec2(x: -21, y: 4)] {
            let placed = placement.matrix.transformedPoint(Vec3(x: probe.x, y: probe.y, z: 0))
            let embedded = plane.embed(probe)
            XCTAssertLessThanOrEqual(placed.distance(to: embedded), 1e-9)
        }
    }

    func testRayHitsResolveToTheirOwnCoordinates() throws {
        let plane = try FFPlane3D.facePlane(
            origin: Vec3(x: 10, y: -4, z: 6),
            normal: Vec3(x: 0, y: 0.6, z: 0.8)
        )
        for probe in [Vec2(x: 0, y: 0), Vec2(x: 5, y: 5), Vec2(x: -30, y: 20), Vec2(x: 70, y: -10)] {
            let ray = try XCTUnwrap(normalRay(plane, at: probe))
            let resolved = try XCTUnwrap(plane.sketchPoint(of: ray))
            XCTAssertEqual(resolved.x, probe.x, accuracy: 1e-9)
            XCTAssertEqual(resolved.y, probe.y, accuracy: 1e-9)
        }

        // A parallel ray has no hit, and a ray pointing out of a plane behind it
        // has none either. Both are refused rather than clamped to the origin.
        XCTAssertNil(plane.sketchPoint(of: try XCTUnwrap(Ray(origin: plane.origin, direction: plane.xAxis))))
        XCTAssertNil(plane.sketchPoint(of: try XCTUnwrap(
            Ray(origin: plane.origin + plane.normal * 10, direction: plane.normal)
        )))
    }

    // MARK: - Sketching on a tilted face

    func testSketchingOnATiltedFaceProducesCurvesInThatPlane() throws {
        let session = FFEditorSession(document: FFDocument(name: "Tilted sketch"))
        let normal = Vec3(x: 0.3, y: 0.6, z: 0.8)
        let origin = Vec3(x: 4, y: -2, z: 3)
        let plane = try FFPlane3D.workPlane(.face(origin: origin, normal: normal))
        let taps = [Vec2(x: 0, y: 0), Vec2(x: 12, y: 0), Vec2(x: 12, y: 8)]

        XCTAssertTrue(session.defineSketchPlane(.face(origin: origin, normal: normal)))
        XCTAssertTrue(session.lockSketch())
        XCTAssertEqual(session.lockedSketchPlane, plane)
        for tap in taps {
            let ray = try XCTUnwrap(normalRay(plane, at: tap))
            let resolved = try XCTUnwrap(plane.sketchPoint(of: ray))
            XCTAssertTrue(session.tapSketch(at: resolved), session.sketchToolMessage ?? "no message")
        }
        XCTAssertTrue(session.finishSketchCurve(), session.sketchToolMessage ?? "no message")

        // The document holds one ordinary curve node whose payload is 2-D in the
        // plane's own coordinates, not world coordinates. That is what proves no
        // plane field reached the file format.
        XCTAssertEqual(session.document.rootNodes.count, 1)
        let node = try XCTUnwrap(session.document.rootNodes.first)
        let payload = try XCTUnwrap(node.geometry?.curve)
        XCTAssertEqual(payload.segments.count, 2)
        XCTAssertFalse(payload.isClosed)
        // Each segment stores both of its own endpoints, so a three-vertex chain
        // is two segments holding four control points and the middle vertex is
        // stored twice. The first version of this test assumed one control point
        // per vertex and asserted three; that premise was wrong, not the kernel.
        let stored = payload.segments.flatMap { $0.controlPoints.map(\.vector) }
        XCTAssertEqual(stored.count, 4)
        let expectedStored = [taps[0], taps[1], taps[1], taps[2]]
        for (index, tap) in expectedStored.enumerated() {
            XCTAssertEqual(stored[index].x, tap.x, accuracy: 1e-9)
            XCTAssertEqual(stored[index].y, tap.y, accuracy: 1e-9)
        }
        XCTAssertNotEqual(node.transform, .identity)

        // Every drawn point lies on the face, which is the row's first clause.
        let render = try XCTUnwrap(session.curveNodes.first)
        XCTAssertGreaterThanOrEqual(render.worldPoints.count, 3)
        for point in render.worldPoints {
            XCTAssertEqual(plane.signedDistance(of: point), 0, accuracy: 1e-9)
        }
        XCTAssertEqual(session.committedSketchCurves, 1)
    }

    func testCameraResolvedTapsLandOnTheLockedPlane() throws {
        let session = FFEditorSession(document: FFDocument(name: "Camera taps"))
        let plane = try FFPlane3D.facePlane(
            origin: Vec3(x: 2, y: 4, z: 8),
            normal: Vec3(x: 0.2, y: -0.5, z: 0.84)
        )
        let camera = FFCamera.standard
        let viewport = Vec2(x: 820, y: 1180)
        let taps = [Vec2(x: 0, y: 0), Vec2(x: 14, y: 0), Vec2(x: 14, y: 9)]

        XCTAssertTrue(session.defineSketchPlane(.face(origin: plane.origin, normal: plane.normal)))
        XCTAssertTrue(session.lockSketch())

        // The fixture is deliberately inside the grid's reach, so this test
        // cannot pass vacuously. Measured in a local model of this camera and
        // plane: a world Y-up grid point 2.0 mm off the locked plane projects
        // 2.63 pt from the first tap, inside the 12 pt finger tolerance. Without
        // the plane restriction the resolver answers it (`unconstrained`); with
        // the restriction it answers nothing and the placement falls through to
        // the exact ray-plane hit.
        let originScreen = try XCTUnwrap(camera.screenPoint(for: plane.origin, viewport: viewport))
        let geometry = FFSnapGeometry.features(of: .empty, selectedIDs: [])
        let unconstrained = try XCTUnwrap(FFSnapResolver.resolve(
            hover: originScreen,
            reference: nil,
            geometry: geometry,
            camera: camera,
            viewport: viewport,
            tolerance: FFLineChainPlacement.fingerTolerance
        ))
        XCTAssertEqual(unconstrained.best.kind, .grid)
        XCTAssertGreaterThan(abs(plane.signedDistance(of: unconstrained.best.position)), 1)
        XCTAssertNil(FFSnapResolver.resolve(
            hover: originScreen,
            reference: nil,
            geometry: geometry,
            camera: camera,
            viewport: viewport,
            tolerance: FFLineChainPlacement.fingerTolerance,
            on: plane
        ))

        for tap in taps {
            let world = plane.embed(tap)
            let screen = try XCTUnwrap(camera.screenPoint(for: world, viewport: viewport))
            let resolved = try XCTUnwrap(FFLineChainPlacement.point(
                at: screen,
                scene: .empty,
                camera: camera,
                viewport: viewport,
                plane: plane
            ))
            // The camera's own inverse produced this number, so the bound is the
            // camera's, not the plane's: 1e-6 mm is a nanometre, six orders
            // inside the 0.001 mm the interface displays.
            XCTAssertEqual(resolved.x, tap.x, accuracy: 1e-6)
            XCTAssertEqual(resolved.y, tap.y, accuracy: 1e-6)
            XCTAssertTrue(session.tapSketch(at: resolved))
        }
        XCTAssertTrue(session.finishSketchCurve())

        let render = try XCTUnwrap(session.curveNodes.first)
        for point in render.worldPoints {
            XCTAssertEqual(plane.signedDistance(of: point), 0, accuracy: 1e-9)
        }
    }

    // MARK: - Cancelling and committing

    func testCancellingASketchRemovesEveryCurveInOneUndo() throws {
        let session = FFEditorSession(document: FFDocument(name: "Cancel"))
        let plane = try FFPlane3D.facePlane(
            origin: Vec3(x: 0, y: 0, z: 12),
            normal: Vec3(x: 0.2, y: -0.5, z: 0.84)
        )

        XCTAssertTrue(session.defineSketchPlane(.face(origin: plane.origin, normal: plane.normal)))
        XCTAssertTrue(session.lockSketch())
        let depth = session.documentSession.undoDepth

        for index in 0..<3 {
            let start = Vec2(x: Double(index) * 5, y: 0)
            let end = Vec2(x: Double(index) * 5 + 4, y: 3)
            for tap in [start, end] {
                let ray = try XCTUnwrap(normalRay(plane, at: tap))
                XCTAssertTrue(session.tapSketch(at: try XCTUnwrap(plane.sketchPoint(of: ray))))
            }
            XCTAssertTrue(session.finishSketchCurve(), session.sketchToolMessage ?? "no message")
        }

        // Three curves, one history step, and the step is the sketch's own.
        XCTAssertEqual(session.curveNodes.count, 3)
        XCTAssertEqual(session.committedSketchCurves, 3)
        XCTAssertEqual(session.documentSession.undoDepth, depth + 1)
        XCTAssertEqual(session.documentSession.undoName, "Sketch curve")

        XCTAssertTrue(session.cancelSketch())
        XCTAssertTrue(session.document.rootNodes.isEmpty)
        XCTAssertTrue(session.curveNodes.isEmpty)
        XCTAssertEqual(session.documentSession.undoDepth, depth)
        XCTAssertNil(session.lockedSketchPlane)
        XCTAssertEqual(session.committedSketchCurves, 0)

        // The undo that cancelled the sketch is still redoable, which is the
        // ordinary history contract; the next edit clears redo as usual.
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.curveNodes.count, 3)
    }

    func testCancelWithNoCurvesLeavesHistoryAlone() throws {
        let session = FFEditorSession(document: FFDocument(name: "Empty cancel"))
        let plane = try FFPlane3D.facePlane(origin: .zero, normal: Vec3(x: 1, y: 0, z: 0))
        XCTAssertTrue(session.defineSketchPlane(.face(origin: .zero, normal: plane.normal)))
        XCTAssertTrue(session.lockSketch())
        let depth = session.documentSession.undoDepth

        XCTAssertTrue(session.cancelSketch())
        XCTAssertEqual(session.documentSession.undoDepth, depth)
        XCTAssertNil(session.lockedSketchPlane)
        XCTAssertTrue(session.document.rootNodes.isEmpty)
    }

    func testCommitKeepsTheSketchAndUnlocksTheMode() throws {
        let session = FFEditorSession(document: FFDocument(name: "Commit"))
        let first = try FFPlane3D.facePlane(origin: .zero, normal: Vec3(x: 0, y: 0, z: 1))
        XCTAssertTrue(session.defineSketchPlane(.face(origin: .zero, normal: first.normal)))
        XCTAssertTrue(session.lockSketch())
        for tap in [Vec2(x: 0, y: 0), Vec2(x: 10, y: 0)] {
            let ray = try XCTUnwrap(normalRay(first, at: tap))
            XCTAssertTrue(session.tapSketch(at: try XCTUnwrap(first.sketchPoint(of: ray))))
        }
        XCTAssertTrue(session.finishSketchCurve())
        XCTAssertTrue(session.commitSketch())

        XCTAssertEqual(session.curveNodes.count, 1)
        XCTAssertNil(session.lockedSketchPlane)
        XCTAssertEqual(session.committedSketchCurves, 0)
        // Committing wrote nothing, so history still holds one sketch step.
        XCTAssertEqual(session.documentSession.undoDepth, 1)

        // A second sketch on another plane is its own step, and the first stays.
        let second = try FFPlane3D.planePerpendicular(to: Vec3(x: 0, y: 1, z: 0), through: .zero)
        XCTAssertTrue(session.defineSketchPlane(.axis(origin: .zero, direction: Vec3(x: 0, y: 1, z: 0))))
        XCTAssertTrue(session.lockSketch())
        for tap in [Vec2(x: 0, y: 0), Vec2(x: 0, y: 6)] {
            let ray = try XCTUnwrap(normalRay(second, at: tap))
            XCTAssertTrue(session.tapSketch(at: try XCTUnwrap(second.sketchPoint(of: ray))))
        }
        XCTAssertTrue(session.finishSketchCurve())
        XCTAssertTrue(session.commitSketch())
        XCTAssertEqual(session.curveNodes.count, 2)
        XCTAssertEqual(session.documentSession.undoDepth, 2)
    }

    func testTwoSketchesKeepTheirOwnPlanes() throws {
        let session = FFEditorSession(document: FFDocument(name: "Two planes"))
        let first = try FFPlane3D.facePlane(
            origin: Vec3(x: 0, y: 0, z: 5),
            normal: Vec3(x: 0, y: 0, z: 1)
        )
        let second = try FFPlane3D.planePerpendicular(to: Vec3(x: 1, y: 0, z: 0), through: .zero)

        for plane in [first, second] {
            XCTAssertTrue(session.defineSketchPlane(.face(origin: plane.origin, normal: plane.normal)))
            XCTAssertTrue(session.lockSketch())
            for tap in [Vec2(x: 0, y: 0), Vec2(x: 6, y: 2)] {
                let ray = try XCTUnwrap(normalRay(plane, at: tap))
                XCTAssertTrue(session.tapSketch(at: try XCTUnwrap(plane.sketchPoint(of: ray))))
            }
            XCTAssertTrue(session.finishSketchCurve())
            XCTAssertTrue(session.commitSketch())
        }

        XCTAssertEqual(session.curveNodes.count, 2)
        for (index, plane) in [first, second].enumerated() {
            for point in session.curveNodes[index].worldPoints {
                XCTAssertEqual(
                    plane.signedDistance(of: point),
                    0,
                    accuracy: 1e-9,
                    "curve \(index) left its plane"
                )
            }
        }
    }

    // MARK: - The seam and the file

    func testSketchCurveIsAnOrdinaryEditableCurve() throws {
        let session = FFEditorSession(document: FFDocument(name: "Editable"))
        let plane = try FFPlane3D.facePlane(
            origin: Vec3(x: 1, y: 2, z: 3),
            normal: Vec3(x: 0, y: 1, z: 1)
        )
        XCTAssertTrue(session.defineSketchPlane(.face(origin: plane.origin, normal: plane.normal)))
        XCTAssertTrue(session.lockSketch())
        for tap in [Vec2(x: 0, y: 0), Vec2(x: 8, y: 0), Vec2(x: 8, y: 5)] {
            let ray = try XCTUnwrap(normalRay(plane, at: tap))
            XCTAssertTrue(session.tapSketch(at: try XCTUnwrap(plane.sketchPoint(of: ray))))
        }
        XCTAssertTrue(session.finishSketchCurve())
        XCTAssertTrue(session.commitSketch())

        // The document seam, not the sketch tool: the node is an ordinary curve,
        // so the Phase 43 control-point edit reaches it like any other payload.
        var document = session.document
        let id = try XCTUnwrap(document.rootNodes.first?.id)
        let before = try XCTUnwrap(document.curvePayload(forNodeID: id))
        let ray = try XCTUnwrap(normalRay(plane, at: Vec2(x: 8, y: 9)))
        let movedTo = try XCTUnwrap(plane.sketchPoint(of: ray))
        try document.editCurvePayload(nodeID: id) { payload in
            payload.segments[1].controlPoints[1] = FFPoint2(movedTo)
        }
        let after = try XCTUnwrap(document.curvePayload(forNodeID: id))
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.segments[1].controlPoints[1].vector.x, movedTo.x, accuracy: 1e-9)
    }

    func testSketchOnATiltedPlaneSurvivesTheFileRoundTrip() throws {
        let session = FFEditorSession(document: FFDocument(name: "Round trip"))
        let plane = try FFPlane3D.facePlane(
            origin: Vec3(x: -3, y: 5, z: 7),
            normal: Vec3(x: 0.1, y: 0.7, z: 0.7)
        )
        XCTAssertTrue(session.defineSketchPlane(.face(origin: plane.origin, normal: plane.normal)))
        XCTAssertTrue(session.lockSketch())
        for tap in [Vec2(x: 0, y: 0), Vec2(x: 9, y: 1), Vec2(x: 9, y: 7)] {
            let ray = try XCTUnwrap(normalRay(plane, at: tap))
            XCTAssertTrue(session.tapSketch(at: try XCTUnwrap(plane.sketchPoint(of: ray))))
        }
        XCTAssertTrue(session.finishSketchCurve())
        XCTAssertTrue(session.commitSketch())

        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Sketch.ffp")
        try store.save(session.document, to: url)
        let loaded = try store.load(from: url)

        XCTAssertEqual(loaded.stateHash, session.document.stateHash)
        XCTAssertEqual(curvePayloads(in: loaded), curvePayloads(in: session.document))
        XCTAssertEqual(loaded.curveRenders(), session.document.curveRenders())
        for point in loaded.curveRenders().flatMap(\.worldPoints) {
            XCTAssertEqual(plane.signedDistance(of: point), 0, accuracy: 1e-9)
        }
    }

    // MARK: - Tool refusals

    func testSketchToolRefusalsCarrySentences() throws {
        let session = FFEditorSession(document: FFDocument(name: "Refusals"))

        XCTAssertFalse(session.lockSketch())
        XCTAssertTrue(session.sketchToolMessage?.contains("Define a work plane") == true)

        XCTAssertFalse(session.tapSketch(at: nil))
        XCTAssertEqual(session.sketchToolMessage, FFWorkPlaneError.unreachablePlane.errorDescription)

        XCTAssertFalse(session.finishSketchCurve())
        XCTAssertEqual(session.sketchToolMessage, FFWorkPlaneError.sketchNotLocked.errorDescription)

        XCTAssertFalse(session.cancelSketch())
        XCTAssertTrue(session.sketchToolMessage?.contains("No sketch is open") == true)

        let plane = try FFPlane3D.facePlane(origin: .zero, normal: Vec3(x: 0, y: 0, z: 1))
        XCTAssertTrue(session.defineSketchPlane(.face(origin: .zero, normal: plane.normal)))
        XCTAssertTrue(session.lockSketch())
        XCTAssertFalse(session.lockSketch())
        XCTAssertTrue(session.sketchToolMessage?.contains("already locked") == true)

        XCTAssertTrue(session.tapSketch(at: Vec2(x: 0, y: 0)))
        // A tap on the first vertex would be a zero-length segment; the Phase 39
        // refusal is reused rather than restated.
        XCTAssertFalse(session.tapSketch(at: Vec2(x: 0, y: 0)))
        XCTAssertTrue(session.sketchToolMessage?.contains("previous vertex") == true)
        XCTAssertEqual(session.sketchDraft.pointCount, 1)

        // A single vertex is not a curve.
        XCTAssertFalse(session.finishSketchCurve())
        XCTAssertTrue(session.sketchToolMessage?.contains("at least two vertices") == true)
        XCTAssertTrue(session.curveNodes.isEmpty)

        // The three-point source refuses a repeated tap through the session too.
        session.beginSketchPlane(.threePoints)
        XCTAssertTrue(session.tapSketchPlanePoint(Vec3(x: 0, y: 0, z: 0)))
        XCTAssertTrue(session.tapSketchPlanePoint(Vec3(x: 10, y: 0, z: 0)))
        XCTAssertFalse(session.tapSketchPlanePoint(Vec3(x: 10, y: 0, z: 0)))
        XCTAssertTrue(session.sketchToolMessage?.contains("same place") == true)
        XCTAssertEqual(session.sketchPlaneDraft.tapCount, 2)
        XCTAssertTrue(session.tapSketchPlanePoint(Vec3(x: 0, y: 10, z: 4)))
        XCTAssertNotNil(session.sketchPlane)
    }

    func testSketchPreviewStaysOnTheLockedPlane() throws {
        let session = FFEditorSession(document: FFDocument(name: "Preview"))
        let plane = try FFPlane3D.facePlane(
            origin: Vec3(x: 2, y: 2, z: 2),
            normal: Vec3(x: 0, y: 0.8, z: 0.6)
        )
        XCTAssertTrue(session.defineSketchPlane(.face(origin: plane.origin, normal: plane.normal)))
        XCTAssertTrue(session.lockSketch())
        XCTAssertTrue(session.sketchPreview.isEmpty)

        XCTAssertTrue(session.tapSketch(at: Vec2(x: 0, y: 0)))
        XCTAssertTrue(session.tapSketch(at: Vec2(x: 10, y: 4)))
        XCTAssertEqual(session.sketchPreview.count, 2)
        for point in session.sketchPreview {
            XCTAssertEqual(plane.signedDistance(of: point), 0, accuracy: 1e-9)
        }
    }
}
