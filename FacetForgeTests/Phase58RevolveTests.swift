import Foundation
import XCTest
@testable import FacetForge

/// Phase 58's acceptance: a revolved torus matches its analytic volume within
/// 0.5%, and a full turn is watertight.
///
/// The rows are read from the product, not from a model: `FFRevolve` builds the
/// mesh, `FFRingBody` is the primitive, `FFDocument.addRevolve` and
/// `FFDocument.addRingBody` are the document mutations, and the session is the
/// same one the card drives. The volume the tests compare against is Pappus's
/// theorem, which is exact for a plane area revolved about an external axis.
final class Phase58RevolveTests: XCTestCase {

    // MARK: - The row's acceptance

    func testARevolvedTorusMatchesTheAnalyticVolumeAndIsWatertight() throws {
        let body = FFRingBody(majorRadius: 12, minorRadius: 3)
        XCTAssertTrue(body.isValid)

        // Eight exact arcs, not four: the section's span count is what keeps the
        // inscribed tube inside the row's 0.5%, and this asserts the design
        // decision rather than leaving it to a comment.
        XCTAssertEqual(try body.sectionPayload().segments.count, 8)

        let mesh = try body.mesh()
        let analytic = body.analyticVolume

        // Pappus for a torus: (pi r^2) * (2 pi R).
        XCTAssertEqual(analytic, 2 * Double.pi * Double.pi * 12 * 9, accuracy: 1e-9)

        XCTAssertTrue(mesh.isWatertight, "a 360-degree revolution has no boundary")
        XCTAssertEqual(mesh.positions.count, 4_608)
        XCTAssertEqual(mesh.triangles.count, 9_216)

        let volume = mesh.signedVolume()
        XCTAssertGreaterThan(volume, 0, "the body is wound outward")
        let error = abs(volume - analytic) / analytic
        XCTAssertLessThan(
            error,
            0.005,
            "the revolved torus was \(error * 100)% under its analytic volume, "
                + "outside the row's 0.5% (\(volume) against \(analytic))"
        )
        // The mesh is inscribed, so it approaches the analytic volume from
        // below. A mesh that overshot would mean the winding or the section
        // radius was wrong, not merely coarse.
        XCTAssertLessThan(volume, analytic)
    }

    func testAFullTurnRevolveIsWatertightAndConvergesOnPappus() throws {
        let profile = try squareProfile(low: point(10, -15), high: point(28, 15))
        let parameters = FFRevolveParameters(angleDegrees: 360)
        let revolve = FFRevolve(profile: profile, parameters: parameters)

        XCTAssertEqual(revolve.steps, 48, "a full turn keeps the Phase 54 resolution")
        let mesh = try revolve.mesh()

        XCTAssertEqual(mesh.positions.count, 192)
        XCTAssertEqual(mesh.triangles.count, 384)
        XCTAssertEqual(mesh.triangles.count, revolve.estimatedTriangles)
        XCTAssertTrue(mesh.isWatertight, "a full revolution closes at the seam")

        // Pappus: area 18 x 30, centroid 19 mm from the axis.
        let analytic = 2 * Double.pi * 19 * (18 * 30)
        let error = abs(mesh.signedVolume() - analytic) / analytic
        XCTAssertLessThan(error, 0.005, "full turn was \(error * 100)% under Pappus")
    }

    func testAQuarterTurnIsCappedOrOpenAtTheChoicesTheCardShows() throws {
        let profile = try squareProfile(low: point(10, -15), high: point(28, 15))
        let quarter = 2 * Double.pi * 19 * (18 * 30) / 4

        let capped = try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 90, caps: .capped)
        ).mesh()
        XCTAssertEqual(capped.positions.count, 52)
        XCTAssertEqual(capped.triangles.count, 100)
        XCTAssertTrue(capped.isWatertight)
        let cappedError = abs(capped.signedVolume() - quarter) / quarter
        XCTAssertLessThan(cappedError, 0.005)

        let open = try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 90, caps: .open)
        ).mesh()
        XCTAssertEqual(open.positions.count, 52)
        XCTAssertEqual(open.triangles.count, 96, "an open body drops the two caps")
        XCTAssertFalse(open.isWatertight)
        XCTAssertEqual(
            open.edgeUseCounts.values.filter { $0 == 1 }.count,
            8,
            "the open ends keep one boundary ring each"
        )
    }

    func testTheReversedDirectionMirrorsTheBodyAndKeepsItsVolume() throws {
        let profile = try squareProfile(low: point(10, -15), high: point(28, 15))
        let forward = try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 90)
        ).mesh()
        let reversed = try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 90, direction: .reversed)
        ).mesh()

        XCTAssertEqual(reversed.positions.count, forward.positions.count)
        XCTAssertEqual(reversed.triangles.count, forward.triangles.count)
        XCTAssertTrue(reversed.isWatertight)
        XCTAssertTrue(
            reversed.positions.allSatisfy { $0.z <= 1e-9 },
            "a reversed revolution lies on the sketch plane's -Z side"
        )
        XCTAssertTrue(
            forward.positions.allSatisfy { $0.z >= -1e-9 },
            "a forward revolution lies on its +Z side"
        )
        XCTAssertGreaterThan(forward.positions.map(\.z).max() ?? 0, 1)
        XCTAssertLessThan(reversed.positions.map(\.z).min() ?? 0, -1)

        let forwardVolume = forward.signedVolume()
        let reversedVolume = reversed.signedVolume()
        XCTAssertGreaterThan(forwardVolume, 0)
        XCTAssertGreaterThan(reversedVolume, 0)
        XCTAssertEqual(
            reversedVolume,
            forwardVolume,
            accuracy: abs(forwardVolume) * 1e-9,
            "mirroring and reversing the winding must not change the volume"
        )
    }

    func testAFullTurnHasNoEndsToCap() throws {
        let profile = try squareProfile(low: point(10, -15), high: point(28, 15))
        let capped = try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 360, caps: .capped)
        ).mesh()
        let open = try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 360, caps: .open)
        ).mesh()
        XCTAssertEqual(capped, open, "a full turn has no ends, so the choice is moot")
    }

    // MARK: - Refusals

    func testARevolutionRefusesAnAngleOutsideItsRangeAndAProfileOnBothSides() throws {
        let profile = try squareProfile(low: point(10, -15), high: point(28, 15))

        XCTAssertThrowsError(try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 0)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFRevolveError, .nonPositiveAngle)
        }

        XCTAssertThrowsError(try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 2)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFRevolveError, .angleOutOfRange(2))
        }

        XCTAssertThrowsError(try FFRevolve(
            profile: profile,
            parameters: FFRevolveParameters(angleDegrees: 400)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFRevolveError, .angleOutOfRange(400))
        }

        // A section that straddles the axis would sweep through itself, so it is
        // refused with a sentence rather than committed with crossing walls.
        let straddling = try squareProfile(low: point(-5, -5), high: point(5, 5))
        XCTAssertThrowsError(try FFRevolve(
            profile: straddling,
            parameters: FFRevolveParameters(angleDegrees: 90)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFRevolveError, .profileCrossesAxis)
            XCTAssertTrue(
                (error as? FFRevolveError)?.errorDescription?.contains("axis") == true
            )
        }
    }

    // MARK: - The commit

    func testCommittingARevolveIsOneNodeAndOneUndo() throws {
        let (session, nodeID) = makeSession()
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        XCTAssertTrue(session.setSurfacePreviewMode(.revolve))
        XCTAssertTrue(session.setSurfacePreviewAngle(360))
        let before = session.document
        let previewMesh = try XCTUnwrap(session.surfacePreview?.mesh)

        let solid = try XCTUnwrap(session.commitRevolve())
        XCTAssertEqual(session.document.rootNodes.count, 2)
        XCTAssertEqual(session.selection.selectedIDs, Set([solid]))
        XCTAssertNil(session.surfacePreview, "the preview closes when its body is committed")

        let node = try XCTUnwrap(session.document.node(withID: solid))
        XCTAssertEqual(node.kind, .solid)
        XCTAssertEqual(node.name, "Revolve")
        let mesh = try XCTUnwrap(node.geometry?.mesh?.mesh)
        XCTAssertTrue(mesh.isWatertight)
        XCTAssertEqual(
            mesh,
            previewMesh,
            "the commit bakes the body the ghost was showing, not a second one"
        )

        let info = try XCTUnwrap(session.document.revolveInfo(for: solid))
        XCTAssertEqual(info.definition.parameters.angleDegrees, 360, accuracy: 1e-9)
        XCTAssertEqual(info.definition.parameters.direction, .forward)
        XCTAssertEqual(info.definition.sourceNodeID, nodeID)
        XCTAssertNil(info.definition.angularSegments, "an ordinary revolve derives its steps")

        // The record regenerates exactly the body that was committed, which is
        // what makes the parameters more than a label.
        XCTAssertEqual(try info.definition.mesh(), mesh)

        XCTAssertTrue(session.documentSession.canUndo)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document, before, "one command, one undo step")
        XCTAssertNil(session.document.node(withID: solid))
        XCTAssertEqual(session.document.rootNodes.count, 1)
    }

    func testTheCommitBakesTheAngleDirectionAndCapsTheCardWasShowing() throws {
        let (session, nodeID) = makeSession()
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        XCTAssertTrue(session.setSurfacePreviewMode(.revolve))
        XCTAssertTrue(session.setSurfacePreviewAngle(90))
        XCTAssertTrue(session.setRevolveDirection(.reversed))
        XCTAssertTrue(session.setRevolveCaps(.open))

        let preview = try XCTUnwrap(session.surfacePreview)
        XCTAssertEqual(preview.revolve?.angleDegrees ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(preview.revolve?.direction, FFRevolveDirection.reversed)
        XCTAssertEqual(preview.revolve?.caps, FFRevolveCaps.open)
        XCTAssertTrue(preview.summary(unit: .millimetres).contains("reversed"))
        XCTAssertTrue(preview.summary(unit: .millimetres).contains("open"))

        let solid = try XCTUnwrap(session.commitRevolve())
        let node = try XCTUnwrap(session.document.node(withID: solid))
        let mesh = try XCTUnwrap(node.geometry?.mesh?.mesh)

        XCTAssertTrue(
            mesh.positions.allSatisfy { $0.z <= 1e-9 },
            "the reversed direction puts the body on the other side of the plane"
        )
        XCTAssertFalse(mesh.isWatertight, "the card chose an open body")
        XCTAssertEqual(mesh.edgeUseCounts.values.filter { $0 == 1 }.count, 8)

        let info = try XCTUnwrap(session.document.revolveInfo(for: solid))
        XCTAssertEqual(info.definition.parameters.angleDegrees, 90, accuracy: 1e-9)
        XCTAssertEqual(info.definition.parameters.direction, .reversed)
        XCTAssertEqual(info.definition.parameters.caps, .open)
        XCTAssertEqual(try info.definition.mesh(), mesh)
    }

    func testACommitNeedsAnOpenRevolvePreview() throws {
        let (session, nodeID) = makeSession()
        XCTAssertNil(session.commitRevolve(), "nothing is previewed yet")

        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        // The default mode is extrude, so the revolve commit must refuse even
        // though a preview exists.
        XCTAssertNil(session.commitRevolve())
        XCTAssertFalse(session.documentSession.canUndo)

        XCTAssertTrue(session.setSurfacePreviewMode(.revolve))
        session.endSurfacePreview()
        XCTAssertNil(session.commitRevolve(), "a closed preview commits nothing")
        XCTAssertFalse(session.documentSession.canUndo)
    }

    func testTheCardClampsAnAngleAndKeepsTheLastGoodBodyWhenItRefuses() throws {
        let (session, nodeID) = makeSession()
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        XCTAssertTrue(session.setSurfacePreviewMode(.revolve))

        // The card clamps, exactly as the draft and height fields do, so a held
        // stepper stops at the limit instead of filling the card with an error.
        XCTAssertTrue(session.setSurfacePreviewAngle(400))
        XCTAssertEqual(session.surfacePreview?.angleDegrees ?? 0, 360, accuracy: 1e-9)
        XCTAssertNil(session.surfacePreviewMessage)

        XCTAssertTrue(session.setSurfacePreviewAngle(1))
        XCTAssertEqual(session.surfacePreview?.angleDegrees ?? 0, 5, accuracy: 1e-9)

        // A profile that straddles the axis is refused, and the last good body
        // stays on screen with the reason beside it.
        let (straddling, straddlingID) = makeSession(
            points: [point(-5, -5), point(5, -5), point(5, 5), point(-5, 5)]
        )
        straddling.selection.select([straddlingID])
        XCTAssertTrue(straddling.beginSurfacePreview())
        let updates = try XCTUnwrap(straddling.surfacePreview).updates
        XCTAssertFalse(straddling.setSurfacePreviewMode(.revolve))
        XCTAssertNotNil(straddling.surfacePreviewMessage)
        XCTAssertEqual(straddling.surfacePreview?.mode, FFSweepMode.extrude)
        XCTAssertEqual(straddling.surfacePreview?.updates, updates)
        XCTAssertFalse(straddling.documentSession.canUndo)
    }

    // MARK: - The ring body primitive

    func testTheRingBodyPrimitiveIsOneSolidAndOneUndo() throws {
        let (session, _) = makeSession()
        let before = session.document

        let bodyID = try XCTUnwrap(session.addRingBody())
        XCTAssertEqual(session.document.rootNodes.count, 2)
        XCTAssertEqual(session.selection.selectedIDs, Set([bodyID]))

        let node = try XCTUnwrap(session.document.node(withID: bodyID))
        XCTAssertEqual(node.kind, .solid)
        XCTAssertEqual(node.name, "Ring body")
        let mesh = try XCTUnwrap(node.geometry?.mesh?.mesh)
        XCTAssertTrue(mesh.isWatertight)

        let body = FFRingBody()
        let error = abs(mesh.signedVolume() - body.analyticVolume) / body.analyticVolume
        XCTAssertLessThan(error, 0.005)

        let info = try XCTUnwrap(session.document.revolveInfo(for: bodyID))
        XCTAssertNil(info.definition.sourceNodeID, "a primitive has no source curve")
        XCTAssertEqual(info.definition.parameters.angleDegrees, 360, accuracy: 1e-9)
        XCTAssertEqual(info.definition.angularSegments, FFRingBody.defaultAngularSegments)
        XCTAssertEqual(try info.definition.mesh(), mesh)
        XCTAssertEqual(info.definition.parameters.caps, .capped)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document, before, "one command, one undo step")
        XCTAssertNil(session.document.node(withID: bodyID))
    }

    func testARingBodyThatCannotBeBuiltRefusesAndCommitsNothing() throws {
        let (session, _) = makeSession()
        XCTAssertNil(session.addRingBody(majorRadius: 3, minorRadius: 3))
        XCTAssertEqual(session.documentStatus, FFRingBodyError.tubeFillsBore.errorDescription)

        XCTAssertNil(session.addRingBody(majorRadius: 0, minorRadius: 1))
        XCTAssertEqual(session.documentStatus, FFRingBodyError.nonPositiveRadius.errorDescription)

        XCTAssertFalse(session.documentSession.canUndo)
        XCTAssertEqual(session.document.rootNodes.count, 1)
    }

    // MARK: - Format

    func testTheRecordSurvivesEncodeAndDecodeWithItsBody() throws {
        let (session, nodeID) = makeSession()
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        XCTAssertTrue(session.setSurfacePreviewMode(.revolve))
        XCTAssertTrue(session.setSurfacePreviewAngle(180))
        XCTAssertTrue(session.setRevolveDirection(.reversed))
        _ = try XCTUnwrap(session.commitRevolve())

        let encoded = try session.document.encoded()
        let decoded = try FFDocument.decoded(from: encoded)
        XCTAssertEqual(decoded, session.document)

        let solid = try XCTUnwrap(decoded.rootNodes.last?.id)
        let info = try XCTUnwrap(decoded.revolveInfo(for: solid))
        XCTAssertEqual(info.definition.parameters.angleDegrees, 180, accuracy: 1e-9)
        XCTAssertEqual(info.definition.parameters.direction, .reversed)
        let rebuilt = try info.definition.mesh()
        let stored = try XCTUnwrap(decoded.node(withID: solid)?.geometry?.mesh?.mesh)
        XCTAssertEqual(rebuilt, stored)
    }

    func testADocumentWithoutARevolveEncodesExactlyAsBefore() throws {
        var document = FFDocument(name: "Phase 58")
        document.rootNodes = [FFNode(
            name: "Profile",
            geometry: .curve(straightPayload(squarePoints(low: point(10, -15), high: point(28, 15)), isClosed: true)),
            kind: .curve,
            layerID: document.currentLayerID
        )]
        let data = try document.encoded()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(
            json.contains("\"revolve\""),
            "an untouched document must not grow a null field for this phase"
        )
    }

    // MARK: - Fixtures

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    private func squarePoints(low: Vec2, high: Vec2) -> [Vec2] {
        [
            point(low.x, low.y),
            point(high.x, low.y),
            point(high.x, high.y),
            point(low.x, high.y)
        ]
    }

    /// The row's profile: a closed section entirely off the axis.
    private func squareProfile(low: Vec2, high: Vec2) throws -> FFSurfaceSweepProfile {
        try FFSurfaceSweepProfile(points: squarePoints(low: low, high: high), isClosed: true)
    }

    private func straightPayload(_ points: [Vec2], isClosed: Bool) -> FFCurvePayload {
        var segments: [FFCurveSegment] = []
        for index in 0..<(isClosed ? points.count : points.count - 1) {
            let start = points[index]
            let end = points[(index + 1) % points.count]
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(start), FFPoint2(end)]
            ))
        }
        return FFCurvePayload(segments: segments, isClosed: isClosed)
    }

    private func makeSession() -> (FFEditorSession, UUID) {
        makeSession(points: squarePoints(low: point(10, -15), high: point(28, 15)))
    }

    private func makeSession(points: [Vec2]) -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 58")
        let node = FFNode(
            name: "Revolve profile",
            geometry: .curve(straightPayload(points, isClosed: true)),
            kind: .curve,
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        return (FFEditorSession(document: document), node.id)
    }
}
