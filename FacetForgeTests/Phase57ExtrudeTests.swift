import Foundation
import XCTest
@testable import FacetForge

/// Phase 57's acceptance: the volume of a 10 x 10 x 5 mm extrusion is 500 mm3
/// to a thousandth, and the draft angle is verified on a section.
///
/// The section is read out of the mesh the kernel actually built, not out of
/// the offset function that built it, so a ring that was emitted in the wrong
/// place fails even when the helper that computed it is right. The commit tests
/// then drive the session's own commands, because the row is a solid a jeweller
/// gets, not a mesh a test can construct.
final class Phase57ExtrudeTests: XCTestCase {
    // MARK: - The row's own numbers

    func testATenByTenFiveMillimetreExtrusionHasTheExactVolume() throws {
        let profile = try squareProfile(side: 10)
        let parameters = FFExtrusionParameters(height: 5)
        let mesh = try FFExtrusion(profile: profile, parameters: parameters).mesh()

        XCTAssertEqual(mesh.positions.count, 8)
        XCTAssertEqual(mesh.triangles.count, 12)
        XCTAssertEqual(mesh.signedVolume(), 500, accuracy: 0.001)
        XCTAssertTrue(mesh.isWatertight, "a capped extrusion has no boundary edges")
        let span = parameters.zRange
        XCTAssertEqual(span.low, 0, accuracy: 1e-12)
        XCTAssertEqual(span.high, 5, accuracy: 1e-12)
        XCTAssertEqual(mesh.positions.map(\.z).min() ?? 1, 0, accuracy: 1e-12)
        XCTAssertEqual(mesh.positions.map(\.z).max() ?? -1, 5, accuracy: 1e-12)
    }

    /// The row's second clause. The draft is measured back off the top ring of
    /// the mesh: the half-width it actually has, minus the profile's own
    /// half-width, over the height, is the tangent of the angle.
    func testTheDraftAngleIsMeasuredOnTheSectionTheMeshHas() throws {
        let profile = try squareProfile(side: 10)
        let parameters = FFExtrusionParameters(height: 5, draftDegrees: 3)
        let mesh = try FFExtrusion(profile: profile, parameters: parameters).mesh()

        XCTAssertEqual(mesh.positions.count, 8, "draft moves vertices, it does not add any")
        let baseHalfWidth = mesh.positions[0...3].map(\.x).map { Swift.abs($0) }.max() ?? 0
        let topHalfWidth = mesh.positions[4...7].map(\.x).map { Swift.abs($0) }.max() ?? 0
        XCTAssertEqual(baseHalfWidth, 5, accuracy: 1e-12, "the profile plane is unchanged")
        XCTAssertGreaterThan(topHalfWidth, baseHalfWidth, "positive draft widens the section")

        let measured = atan2(topHalfWidth - baseHalfWidth, parameters.height) * 180 / .pi
        XCTAssertEqual(measured, 3, accuracy: 1e-9, "the section must carry the angle it was asked for")

        // A drafted square is a prismatoid: the mesh's volume has to match the
        // exact integral of the linearly changing section, or the caps and the
        // walls disagree about where the body ends.
        let tangent = tan(FFMath.radians(3))
        let baseArea = 100.0
        let middleArea = pow(10 + 2 * tangent * 2.5, 2)
        let topArea = pow(10 + 2 * tangent * 5, 2)
        let analytic = parameters.height / 6 * (baseArea + 4 * middleArea + topArea)
        XCTAssertEqual(mesh.signedVolume(), analytic, accuracy: analytic * 1e-9)
        XCTAssertTrue(mesh.isWatertight)

        let reversed = try FFExtrusion(
            profile: profile,
            parameters: FFExtrusionParameters(height: 5, draftDegrees: -3)
        ).mesh()
        let narrowed = reversed.positions[4...7].map(\.x).map { Swift.abs($0) }.max() ?? 0
        XCTAssertLessThan(narrowed, 5, "a negative draft narrows the section")
        XCTAssertEqual(narrowed, 5 - 5 * tangent, accuracy: 1e-9)
    }

    func testForwardReversedAndSymmetricSitWhereTheParametersSay() throws {
        let profile = try squareProfile(side: 10)
        let forward = try FFExtrusion(
            profile: profile,
            parameters: FFExtrusionParameters(height: 5)
        ).mesh()
        let reversed = try FFExtrusion(
            profile: profile,
            parameters: FFExtrusionParameters(height: 5, direction: .reversed)
        ).mesh()
        let symmetric = try FFExtrusion(
            profile: profile,
            parameters: FFExtrusionParameters(height: 5, isSymmetric: true)
        ).mesh()

        XCTAssertEqual(forward.positions.map(\.z).min() ?? 1, 0, accuracy: 1e-12)
        XCTAssertEqual(forward.positions.map(\.z).max() ?? -1, 5, accuracy: 1e-12)
        XCTAssertEqual(reversed.positions.map(\.z).min() ?? 1, -5, accuracy: 1e-12)
        XCTAssertEqual(reversed.positions.map(\.z).max() ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(symmetric.positions.map(\.z).min() ?? 1, -2.5, accuracy: 1e-12)
        XCTAssertEqual(symmetric.positions.map(\.z).max() ?? -1, 2.5, accuracy: 1e-12)

        // Direction and symmetric mode move the body; none of them changes the
        // amount of metal in it.
        for mesh in [forward, reversed, symmetric] {
            XCTAssertEqual(mesh.signedVolume(), 500, accuracy: 0.001)
            XCTAssertTrue(mesh.isWatertight)
        }
    }

    func testACappedBodyClosesAndAnOpenOneLeavesItsEndsOff() throws {
        let profile = try squareProfile(side: 10)
        let open = try FFExtrusion(
            profile: profile,
            parameters: FFExtrusionParameters(height: 5, caps: .open)
        ).mesh()

        XCTAssertEqual(open.triangles.count, 8, "only the four walls are drawn")
        XCTAssertFalse(open.isWatertight)
        XCTAssertEqual(open.edgeUseCounts.values.filter { $0 == 1 }.count, 8)
        XCTAssertEqual(open.positions.count, 8, "the section is still two rings")
    }

    func testAnOpenProfileExtrudesAsARibbonAndRefusesDraft() throws {
        let profile = try FFSurfaceSweepProfile(
            points: [point(0, 0), point(10, 0), point(10, 6)],
            isClosed: false
        )
        let mesh = try FFExtrusion(
            profile: profile,
            parameters: FFExtrusionParameters(height: 4)
        ).mesh()

        XCTAssertEqual(mesh.positions.count, 6)
        XCTAssertEqual(mesh.triangles.count, 4)
        XCTAssertFalse(mesh.isWatertight)
        XCTAssertEqual(mesh.edgeUseCounts.values.filter { $0 == 1 }.count, 6)

        XCTAssertThrowsError(try FFExtrusion(
            profile: profile,
            parameters: FFExtrusionParameters(height: 4, draftDegrees: 3)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFExtrudeError, .draftNeedsClosedProfile)
        }
    }

    // MARK: - Refusals

    func testADraftThatWouldFoldTheProfileIsRefused() throws {
        // 1 mm wide and narrowed 20 degrees over 5 mm: each wall travels 1.82 mm
        // inward, so the top ring would turn inside out. The body is refused
        // instead of committed with crossing walls.
        let profile = try FFSurfaceSweepProfile(
            points: [point(-0.5, 0), point(0.5, 0), point(0.5, 20), point(-0.5, 20)],
            isClosed: true
        )
        XCTAssertThrowsError(try FFExtrusion(
            profile: profile,
            parameters: FFExtrusionParameters(height: 5, draftDegrees: -20)
        ).mesh()) { error in
            guard let refusal = error as? FFExtrudeError,
                  refusal == .draftCollapsesProfile || refusal == .draftTooSharp
            else {
                return XCTFail("expected a draft refusal, got \(error)")
            }
        }

        XCTAssertThrowsError(try FFExtrusion(
            profile: try squareProfile(side: 10),
            parameters: FFExtrusionParameters(height: 0)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFExtrudeError, .nonPositiveHeight)
        }

        XCTAssertThrowsError(try FFExtrusion(
            profile: try squareProfile(side: 10),
            parameters: FFExtrusionParameters(height: 5, draftDegrees: 60)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFExtrudeError, .draftOutOfRange(60))
        }
    }

    // MARK: - The commit

    func testCommittingAnExtrusionIsOneNodeAndOneUndo() throws {
        let (session, nodeID) = makeSession()
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        XCTAssertTrue(session.setSurfacePreviewHeight(5))
        let before = session.document

        let solid = try XCTUnwrap(session.commitExtrusion())
        XCTAssertEqual(session.document.rootNodes.count, 2)
        XCTAssertEqual(session.selection.selectedIDs, Set([solid]))
        XCTAssertNil(session.surfacePreview, "the preview closes when its body is committed")

        let node = try XCTUnwrap(session.document.node(withID: solid))
        XCTAssertEqual(node.kind, .solid)
        XCTAssertEqual(node.name, "Extrusion")
        let mesh = try XCTUnwrap(node.geometry?.mesh?.mesh)
        XCTAssertEqual(mesh.signedVolume(), 500, accuracy: 0.001)
        XCTAssertEqual(mesh.triangles.count, 12)

        let info = try XCTUnwrap(session.document.extrusionInfo(for: solid))
        XCTAssertEqual(info.definition.parameters.height, 5, accuracy: 1e-9)
        XCTAssertEqual(info.definition.parameters.draftDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(info.definition.sourceNodeID, nodeID)
        XCTAssertEqual(info.definition.profile.segments.count, 4)

        // The record regenerates exactly the body that was committed, which is
        // what makes the parameters more than a label.
        let rebuilt = try info.definition.mesh()
        XCTAssertEqual(rebuilt, mesh)

        XCTAssertTrue(session.documentSession.canUndo)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document, before, "one command, one undo step")
        XCTAssertNil(session.document.node(withID: solid))
        XCTAssertEqual(session.document.rootNodes.count, 1)
    }

    func testTheCommitBakesTheDraftDirectionAndCapsTheCardWasShowing() throws {
        let (session, nodeID) = makeSession()
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        XCTAssertTrue(session.setSurfacePreviewHeight(5))
        XCTAssertTrue(session.setExtrusionDraft(3))
        XCTAssertTrue(session.setExtrusionDirection(.reversed))

        let preview = try XCTUnwrap(session.surfacePreview)
        XCTAssertEqual(preview.extrusion?.draftDegrees ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(preview.extrusion?.direction, .reversed)
        XCTAssertTrue(preview.summary(unit: .millimetres).contains("draft"))

        let solid = try XCTUnwrap(session.commitExtrusion())
        let node = try XCTUnwrap(session.document.node(withID: solid))
        let mesh = try XCTUnwrap(node.geometry?.mesh?.mesh)

        XCTAssertEqual(mesh.positions.map(\.z).max() ?? 1, 0, accuracy: 1e-12)
        XCTAssertEqual(mesh.positions.map(\.z).min() ?? 1, -5, accuracy: 1e-12)
        let tangent = tan(FFMath.radians(3))
        let topHalfWidth = mesh.positions[0...3].map(\.x).map { Swift.abs($0) }.max() ?? 0
        XCTAssertEqual(topHalfWidth, 5 + 5 * tangent, accuracy: 1e-9)

        let info = try XCTUnwrap(session.document.extrusionInfo(for: solid))
        XCTAssertEqual(info.definition.parameters.draftDegrees, 3, accuracy: 1e-9)
        XCTAssertEqual(info.definition.parameters.direction, .reversed)

        // A second body from the same profile, this time uncapped. The card is
        // reopened because a commit closes the preview it consumed.
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        XCTAssertTrue(session.setSurfacePreviewHeight(5))
        XCTAssertTrue(session.setExtrusionCaps(.open))
        let open = try XCTUnwrap(session.commitExtrusion())
        let openMesh = try XCTUnwrap(session.document.node(withID: open)?.geometry?.mesh?.mesh)
        XCTAssertFalse(openMesh.isWatertight)
    }

    func testTheCardClampsADraftAndAKeepsTheLastGoodBodyWhenItCollapses() throws {
        let (session, nodeID) = makeSession()
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())

        // The card clamps, exactly as the Phase 54 height field does, so a held
        // stepper stops at the limit instead of filling the card with an error
        // the user cannot clear.
        XCTAssertTrue(session.setExtrusionDraft(60))
        XCTAssertEqual(session.surfacePreview?.extrusion?.draftDegrees ?? 0, 45, accuracy: 1e-9)
        XCTAssertNil(session.surfacePreviewMessage)

        // A draft the geometry cannot take is refused, and the last good body
        // stays on screen with the reason beside it.
        let (thin, thinID) = makeSession(
            points: [point(-0.5, 0), point(0.5, 0), point(0.5, 20), point(-0.5, 20)]
        )
        thin.selection.select([thinID])
        XCTAssertTrue(thin.beginSurfacePreview())
        let updates = try XCTUnwrap(thin.surfacePreview).updates

        XCTAssertFalse(thin.setExtrusionDraft(-45))
        XCTAssertNotNil(thin.surfacePreviewMessage)
        XCTAssertEqual(thin.surfacePreview?.extrusion?.draftDegrees ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(thin.surfacePreview?.updates, updates)
        XCTAssertFalse(thin.documentSession.canUndo)
    }

    func testACommitNeedsAnOpenExtrusionPreview() throws {
        let (session, nodeID) = makeSession()
        XCTAssertNil(session.commitExtrusion(), "nothing is previewed yet")

        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        session.endSurfacePreview()
        XCTAssertNil(session.commitExtrusion(), "a closed preview commits nothing")
        XCTAssertFalse(session.documentSession.canUndo)

        // Revolve is still preview-only in this phase, so its card must not be
        // able to bake a body the row did not ask for.
        let (revolveSession, revolveID) = makeSession(
            points: [point(10, 0), point(20, 0), point(20, 10), point(10, 10)]
        )
        revolveSession.selection.select([revolveID])
        XCTAssertTrue(revolveSession.beginSurfacePreview())
        XCTAssertTrue(revolveSession.setSurfacePreviewMode(.revolve))
        XCTAssertNil(revolveSession.commitExtrusion())
        XCTAssertFalse(revolveSession.documentSession.canUndo)
    }

    // MARK: - Format

    func testTheRecordSurvivesEncodeAndDecodeWithItsBody() throws {
        let (session, nodeID) = makeSession()
        session.selection.select([nodeID])
        XCTAssertTrue(session.beginSurfacePreview())
        XCTAssertTrue(session.setSurfacePreviewHeight(5))
        XCTAssertTrue(session.setExtrusionDraft(2))
        _ = try XCTUnwrap(session.commitExtrusion())

        let encoded = try session.document.encoded()
        let decoded = try FFDocument.decoded(from: encoded)
        XCTAssertEqual(decoded, session.document)

        let info = try XCTUnwrap(
            decoded.extrusionInfo(for: decoded.rootNodes[1].id)
        )
        XCTAssertEqual(info.definition.parameters.draftDegrees, 2, accuracy: 1e-9)
        XCTAssertEqual(info.definition.parameters.height, 5, accuracy: 1e-9)
        let rebuilt = try info.definition.mesh()
        let stored = try XCTUnwrap(
            session.document.node(withID: info.nodeID)?.geometry?.mesh?.mesh
        )
        XCTAssertEqual(rebuilt, stored)
    }

    func testADocumentWithoutAnExtrusionEncodesExactlyAsBefore() throws {
        var document = FFDocument(name: "Phase 57")
        document.rootNodes = [FFNode(
            name: "Profile",
            geometry: .curve(straightPayload(squarePoints(side: 10), isClosed: true)),
            kind: .curve,
            layerID: document.currentLayerID
        )]
        let data = try document.encoded()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(
            json.contains("\"extrusion\""),
            "an untouched document must not grow a null field for this phase"
        )
    }

    // MARK: - Fixtures

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    private func squarePoints(side: Double) -> [Vec2] {
        let half = side / 2
        return [
            point(-half, 0),
            point(half, 0),
            point(half, side),
            point(-half, side)
        ]
    }

    /// A ten millimetre square, which is the row's section.
    private func squareProfile(side: Double) throws -> FFSurfaceSweepProfile {
        try FFSurfaceSweepProfile(points: squarePoints(side: side), isClosed: true)
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
        makeSession(points: squarePoints(side: 10))
    }

    private func makeSession(points: [Vec2]) -> (FFEditorSession, UUID) {
        var document = FFDocument(name: "Phase 57")
        let node = FFNode(
            name: "Extrude profile",
            geometry: .curve(straightPayload(points, isClosed: true)),
            kind: .curve,
            layerID: document.currentLayerID
        )
        document.rootNodes = [node]
        return (FFEditorSession(document: document), node.id)
    }
}
