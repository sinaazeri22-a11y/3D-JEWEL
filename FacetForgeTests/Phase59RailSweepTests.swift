import Foundation
import XCTest
@testable import FacetForge

/// Phase 59's acceptance: a section swept along a rail carries the row's
/// expected volume, self-intersecting rails are refused rather than committed,
/// and the parametric record rebuilds exactly the body that was written.
///
/// The rows are read from the product, not from a model: `FFRailSweep` builds
/// the mesh, `FFRailSweepDefinition` is the document record, and the session is
/// the same one a later panel will drive. The expected volume is the section's
/// own area times the rail's length, which is exact for an untwisted,
/// untapered sweep along a straight rail.
final class Phase59RailSweepTests: XCTestCase {
    // MARK: - Geometry

    func testACircleSweptAlongFiftyMillimetresHasTheExpectedVolume() throws {
        let radius = 4.0
        let rail = try FFRailPath(payload: straightPayload(
            [point(0, 0), point(50, 0)],
            isClosed: false
        ))
        XCTAssertEqual(rail.length, 50, accuracy: 1e-9)

        let profile = try FFSurfaceSweepProfile(payload: straightPayload(
            circlePoints(radius: radius, count: 64),
            isClosed: true
        ))
        let sweep = FFRailSweep(
            profile: profile,
            rail: rail,
            parameters: FFRailSweepParameters()
        )
        let mesh = try sweep.mesh()

        let area = 0.5 * 64 * radius * radius * sin(2 * Double.pi / 64)
        let expected = area * rail.length
        let error = abs(mesh.signedVolume() - expected) / expected
        XCTAssertLessThan(error, 0.01, "the row allows 1 % on a 50 mm rail")
        XCTAssertEqual(mesh.triangles.count, 252, "2 rings, 64 sides, two 64-gon caps")
        XCTAssertTrue(mesh.isWatertight)
        XCTAssertEqual(mesh.classification.boundaryEdgeCount, 0)
    }

    func testAnOpenProfileIsARibbonWithNoCaps() throws {
        let profile = try FFSurfaceSweepProfile(
            points: [point(0, 0), point(10, 0), point(10, 5)],
            isClosed: false
        )
        let rail = try FFRailPath(points: [point(0, 0), point(50, 0)])
        let open = try FFRailSweep(
            profile: profile,
            rail: rail,
            parameters: FFRailSweepParameters(caps: .capped)
        ).mesh()
        XCTAssertEqual(open.triangles.count, 4, "two spans, one quad each")
        XCTAssertGreaterThan(open.classification.boundaryEdgeCount, 0, "a ribbon has an open border")

        let cappedSquare = try FFRailSweep(
            profile: try FFSurfaceSweepProfile(
                points: [point(0, 0), point(10, 0), point(10, 6), point(0, 6)],
                isClosed: true
            ),
            rail: rail,
            parameters: FFRailSweepParameters(caps: .capped)
        ).mesh()
        let openSquare = try FFRailSweep(
            profile: try FFSurfaceSweepProfile(
                points: [point(0, 0), point(10, 0), point(10, 6), point(0, 6)],
                isClosed: true
            ),
            rail: rail,
            parameters: FFRailSweepParameters(caps: .open)
        ).mesh()
        XCTAssertEqual(cappedSquare.triangles.count - openSquare.triangles.count, 4)
        XCTAssertEqual(cappedSquare.classification.boundaryEdgeCount, 0)
        XCTAssertGreaterThan(openSquare.classification.boundaryEdgeCount, 0)
        XCTAssertEqual(openSquare.triangles.count, 8)
    }

    func testAFixedSectionOnlyTranslatesAlongTheRail() throws {
        let profile = try FFSurfaceSweepProfile(
            points: [point(0, 0), point(10, 0), point(10, 6), point(0, 6)],
            isClosed: true
        )
        let rail = try FFRailPath(points: [point(0, 0), point(50, 0)])
        let mesh = try FFRailSweep(
            profile: profile,
            rail: rail,
            parameters: FFRailSweepParameters(orientation: .fixed)
        ).mesh()

        // The profile's vertex average is (5, 3), so the section is centred on
        // the rail: every station sits 3 mm below it.
        assertVec3(mesh.positions[0], Vec3(x: -5, y: -3, z: 0))
        assertVec3(mesh.positions[4], Vec3(x: 45, y: -3, z: 0))
    }

    func testTwistRotatesTheFarSectionButNotTheNearOne() throws {
        let profile = try FFSurfaceSweepProfile(
            points: [point(0, 0), point(10, 0), point(10, 6), point(0, 6)],
            isClosed: true
        )
        let rail = try FFRailPath(points: [point(0, 0), point(50, 0)])
        let plain = try FFRailSweep(
            profile: profile,
            rail: rail,
            parameters: FFRailSweepParameters()
        ).mesh()
        let twisted = try FFRailSweep(
            profile: profile,
            rail: rail,
            parameters: FFRailSweepParameters(twistDegrees: 90)
        ).mesh()

        assertVec3(twisted.positions[0], plain.positions[0])
        XCTAssertGreaterThan(twisted.positions[4].distance(to: plain.positions[4]), 1)
        XCTAssertEqual(twisted.signedVolume(), plain.signedVolume(), accuracy: 1e-6)
    }

    func testEndScaleGrowsTheFarSectionAboutTheCentreline() throws {
        let profile = try FFSurfaceSweepProfile(
            points: [point(0, 0), point(10, 0), point(10, 6), point(0, 6)],
            isClosed: true
        )
        let rail = try FFRailPath(points: [point(0, 0), point(50, 0)])
        let mesh = try FFRailSweep(
            profile: profile,
            rail: rail,
            parameters: FFRailSweepParameters(endScale: 2)
        ).mesh()
        assertVec3(mesh.positions[0], Vec3(x: -5, y: -3, z: 0))
        assertVec3(mesh.positions[4], Vec3(x: 40, y: -6, z: 0))
    }

    // MARK: - Refusals

    func testAClosedRailIsRefused() {
        XCTAssertThrowsError(try FFRailPath(payload: straightPayload(
            [point(0, 0), point(10, 0), point(10, 10), point(0, 10)],
            isClosed: true
        ))) { error in
            XCTAssertEqual(error as? FFRailSweepError, .railIsClosed)
        }
    }

    func testASelfIntersectingRailIsRefused() {
        XCTAssertThrowsError(try FFRailPath(points: [
            point(0, 0), point(10, 10), point(0, 10), point(10, 0)
        ])) { error in
            XCTAssertEqual(error as? FFRailSweepError, .railSelfIntersects)
        }
    }

    func testARailThatDoublesBackIsRefused() {
        XCTAssertThrowsError(try FFRailPath(points: [
            point(0, 0), point(10, 0), point(0, 0)
        ])) { error in
            XCTAssertEqual(error as? FFRailSweepError, .railSelfIntersects)
        }
    }

    func testATwistOrScaleOutsideItsRangeIsRefused() throws {
        let profile = try FFSurfaceSweepProfile(
            points: [point(0, 0), point(10, 0), point(10, 6), point(0, 6)],
            isClosed: true
        )
        let rail = try FFRailPath(points: [point(0, 0), point(50, 0)])
        XCTAssertThrowsError(try FFRailSweep(
            profile: profile,
            rail: rail,
            parameters: FFRailSweepParameters(twistDegrees: 361)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFRailSweepError, .twistOutOfRange(361))
        }
        XCTAssertThrowsError(try FFRailSweep(
            profile: profile,
            rail: rail,
            parameters: FFRailSweepParameters(endScale: 0)
        ).mesh()) { error in
            XCTAssertEqual(error as? FFRailSweepError, .scaleOutOfRange(0))
        }
    }

    // MARK: - Document and session

    func testCommittingARailSweepAddsOneBodyAboveTheProfileAndOneUndoStep() throws {
        let (session, profileID, railID) = makeSession()
        let before = session.document

        let bodyID = try XCTUnwrap(session.sweepAlongRail(
            profileNodeID: profileID,
            railNodeID: railID
        ))
        XCTAssertEqual(session.document.rootNodes.count, 3)
        XCTAssertEqual(session.document.rootNodes[1].id, bodyID, "the body sits above its profile")
        XCTAssertEqual(session.document.rootNodes[2].id, railID, "the rail stays in the document")
        XCTAssertEqual(session.selection.selectedIDs, Set([bodyID]))

        let info = try XCTUnwrap(session.document.railSweepInfo(for: bodyID))
        XCTAssertEqual(info.definition.sourceProfileNodeID, profileID)
        XCTAssertEqual(info.definition.sourceRailNodeID, railID)
        XCTAssertEqual(info.definition.parameters, FFRailSweepParameters())
        XCTAssertEqual(info.triangleCount, 12)
        let stored = try XCTUnwrap(session.document.node(withID: bodyID)?.geometry?.mesh?.mesh)
        XCTAssertEqual(try info.definition.mesh(), stored, "the record rebuilds its body")
        XCTAssertTrue(session.documentStatus.hasPrefix("Rail sweep · 50"))

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document, before, "one command, one undo step")
        XCTAssertNil(session.document.node(withID: bodyID))
    }

    func testTheRecordSurvivesEncodeAndDecodeWithItsBody() throws {
        let (session, profileID, railID) = makeSession()
        XCTAssertNotNil(session.sweepAlongRail(
            profileNodeID: profileID,
            railNodeID: railID,
            parameters: FFRailSweepParameters(
                twistDegrees: 45,
                endScale: 1.5,
                orientation: .fixed,
                caps: .open
            )
        ))
        let encoded = try session.document.encoded()
        let decoded = try FFDocument.decoded(from: encoded)
        XCTAssertEqual(decoded, session.document)

        let bodyID = try XCTUnwrap(decoded.rootNodes.first { $0.railSweep != nil }?.id)
        let info = try XCTUnwrap(decoded.railSweepInfo(for: bodyID))
        XCTAssertEqual(info.definition.parameters.twistDegrees, 45, accuracy: 1e-9)
        XCTAssertEqual(info.definition.parameters.endScale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(info.definition.parameters.orientation, .fixed)
        XCTAssertEqual(info.definition.parameters.caps, .open)
        let stored = try XCTUnwrap(decoded.node(withID: bodyID)?.geometry?.mesh?.mesh)
        XCTAssertEqual(try info.definition.mesh(), stored)
    }

    func testADocumentWithoutARailSweepEncodesExactlyAsBefore() throws {
        var document = FFDocument(name: "Phase 59")
        document.rootNodes = [FFNode(
            name: "Profile",
            geometry: .curve(straightPayload(
                [point(0, 0), point(10, 0), point(10, 6), point(0, 6)],
                isClosed: true
            )),
            kind: .curve,
            layerID: document.currentLayerID
        )]
        let data = try document.encoded()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(
            json.contains("\"railSweep\""),
            "an untouched document must not grow a null field for this phase"
        )
    }

    func testARefusedSweepWritesNothing() throws {
        let (session, profileID, railID) = makeSession()
        let before = session.document

        XCTAssertNil(session.sweepAlongRail(
            profileNodeID: profileID,
            railNodeID: profileID
        ))
        XCTAssertEqual(session.documentStatus, "Choose two different curves: one profile and one rail")

        XCTAssertNil(session.sweepAlongRail(
            profileNodeID: profileID,
            railNodeID: UUID()
        ))
        XCTAssertEqual(session.documentStatus, "That rail is no longer in the document")

        var crossing = session.document
        let crossingNode = FFNode(
            name: "Crossing rail",
            geometry: .curve(straightPayload(
                [point(0, 0), point(10, 10), point(0, 10), point(10, 0)],
                isClosed: false
            )),
            kind: .curve,
            layerID: crossing.currentLayerID
        )
        crossing.rootNodes.append(crossingNode)
        let crossingSession = FFEditorSession(document: crossing)
        let crossingBefore = crossingSession.document
        XCTAssertNil(crossingSession.sweepAlongRail(
            profileNodeID: profileID,
            railNodeID: crossingNode.id
        ))
        XCTAssertEqual(
            crossingSession.documentStatus,
            FFRailSweepError.railSelfIntersects.errorDescription
        )
        XCTAssertEqual(crossingSession.document, crossingBefore)
        XCTAssertFalse(crossingSession.documentSession.canUndo)
        XCTAssertNotNil(session.document.node(withID: railID))
        XCTAssertEqual(session.document, before, "the refusal attempted no edit")
        XCTAssertFalse(session.documentSession.canUndo)
    }

    func testALockedProfileIsRefused() throws {
        var document = makeDocument()
        document.layers[0].isLocked = true
        let session = FFEditorSession(document: document)
        let profileID = try XCTUnwrap(document.rootNodes.first?.id)
        let railID = try XCTUnwrap(document.rootNodes.last?.id)

        XCTAssertNil(session.sweepAlongRail(profileNodeID: profileID, railNodeID: railID))
        XCTAssertEqual(session.documentStatus, "That profile is on a locked layer")
        XCTAssertEqual(session.document, document)
        XCTAssertFalse(session.documentSession.canUndo)
    }

    // MARK: - Fixtures

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    private func circlePoints(radius: Double, count: Int) -> [Vec2] {
        (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return point(radius * cos(angle), radius * sin(angle))
        }
    }

    private func squarePoints() -> [Vec2] {
        [point(0, 0), point(10, 0), point(10, 6), point(0, 6)]
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

    /// A closed square profile and a straight 50 mm rail, both real curve nodes
    /// in one document.
    private func makeDocument() -> FFDocument {
        var document = FFDocument(name: "Phase 59")
        let profile = FFNode(
            name: "Sweep profile",
            geometry: .curve(straightPayload(squarePoints(), isClosed: true)),
            kind: .curve,
            layerID: document.currentLayerID
        )
        let rail = FFNode(
            name: "Sweep rail",
            geometry: .curve(straightPayload(
                [point(0, -20), point(50, -20)],
                isClosed: false
            )),
            kind: .curve,
            layerID: document.currentLayerID
        )
        document.rootNodes = [profile, rail]
        return document
    }

    private func makeSession() -> (FFEditorSession, UUID, UUID) {
        let document = makeDocument()
        let profileID = document.rootNodes[0].id
        let railID = document.rootNodes[1].id
        return (FFEditorSession(document: document), profileID, railID)
    }

    private func assertVec3(
        _ actual: Vec3,
        _ expected: Vec3,
        accuracy: Double = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
