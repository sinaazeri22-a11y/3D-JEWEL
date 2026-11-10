import Foundation
import XCTest
@testable import FacetForge

/// Phase 41's acceptance: each primitive is editable by its parameters, and a
/// radius, diameter or side-count change preserves the primitive's position and
/// plane.
///
/// The geometry tests pin the generated payload to the primitive's own closed
/// form — every sampled circle point is `radius` from the centre, every ellipse
/// point satisfies its implicit equation, every polygon vertex is on the
/// circumcircle — so an edit cannot pass by merely producing a different curve.
final class Phase41PrimitiveTests: XCTestCase {
    private let store = FFDocumentStore()
    private let fileManager = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase41-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func curvePayloads(in document: FFDocument) -> [FFCurvePayload] {
        document.rootNodes.compactMap { $0.geometry?.curve }
    }

    private func samples(of segment: FFCurveSegment, count: Int = 8) throws -> [Vec2] {
        let curve = try XCTUnwrap(segment.curve)
        return (0...count).map { index in
            curve.point(at: Double(index) / Double(count))
        }
    }

    // MARK: - Exact primitives

    func testCircleStaysExactlyOnItsRadiusAcrossFifteenCases() throws {
        for index in 0..<15 {
            let center = Vec2(x: Double(index) * 3.7 - 22, y: Double(index) * -2.3 + 6)
            let radius = 0.4 + Double(index) * 1.35
            let primitive = FFCurvePrimitive(kind: .circle, center: FFPoint2(center), radius: radius)
            let payload = try primitive.payload()

            XCTAssertEqual(payload.segments.count, 4, "case \(index)")
            XCTAssertTrue(payload.isClosed)
            for segment in payload.segments {
                XCTAssertEqual(segment.kind, .nurbs)
                XCTAssertEqual(segment.degree, 2)
                XCTAssertEqual(segment.weights[1], cos(Double.pi / 4), accuracy: 1e-12)
                for sample in try samples(of: segment) {
                    XCTAssertEqual(
                        (sample - center).length,
                        radius,
                        accuracy: 1e-9,
                        "case \(index) left the circle"
                    )
                }
            }
            let first = try XCTUnwrap(payload.segments.first?.controlPoints.first)
            XCTAssertEqual(first.x, center.x + radius, accuracy: 1e-12)
            XCTAssertEqual(first.y, center.y, accuracy: 1e-12)
        }
    }

    func testEllipseMatchesItsImplicitEquationAcrossFifteenCases() throws {
        for index in 0..<15 {
            let center = Vec2(x: Double(index) * -2.9 + 14, y: Double(index) * 1.7 - 9)
            let width = 3 + Double(index) * 2.1
            let height = 1.5 + Double(index) * 1.4
            let primitive = FFCurvePrimitive(
                kind: .ellipse,
                center: FFPoint2(center),
                width: width,
                height: height
            )
            let payload = try primitive.payload()
            XCTAssertEqual(payload.segments.count, 4, "case \(index)")

            let a = width / 2
            let b = height / 2
            for segment in payload.segments {
                for sample in try samples(of: segment) {
                    let x = (sample.x - center.x) / a
                    let y = (sample.y - center.y) / b
                    XCTAssertEqual(x * x + y * y, 1, accuracy: 1e-9, "case \(index) left the ellipse")
                }
            }
        }
    }

    func testRectangleKeepsItsFourCornersAndCentreAcrossFifteenCases() throws {
        for index in 0..<15 {
            let center = Vec2(x: Double(index) * 1.9 - 8, y: Double(index) * -3.1 + 20)
            let width = 4 + Double(index) * 1.6
            let height = 2 + Double(index) * 1.1
            let primitive = FFCurvePrimitive(
                kind: .rectangle,
                center: FFPoint2(center),
                width: width,
                height: height
            )
            let payload = try primitive.payload()
            XCTAssertEqual(payload.segments.count, 4, "case \(index)")
            XCTAssertTrue(payload.isClosed)

            let halfWidth = width / 2
            let halfHeight = height / 2
            let expected = [
                Vec2(x: center.x - halfWidth, y: center.y - halfHeight),
                Vec2(x: center.x + halfWidth, y: center.y - halfHeight),
                Vec2(x: center.x + halfWidth, y: center.y + halfHeight),
                Vec2(x: center.x - halfWidth, y: center.y + halfHeight),
            ]
            for (segmentIndex, segment) in payload.segments.enumerated() {
                XCTAssertEqual(segment.kind, .bezier)
                let start = try XCTUnwrap(segment.controlPoints.first).vector
                let end = try XCTUnwrap(segment.controlPoints.last).vector
                XCTAssertEqual(start.x, expected[segmentIndex].x, accuracy: 1e-12)
                XCTAssertEqual(start.y, expected[segmentIndex].y, accuracy: 1e-12)
                XCTAssertEqual(end.x, expected[(segmentIndex + 1) % 4].x, accuracy: 1e-12)
                XCTAssertEqual(end.y, expected[(segmentIndex + 1) % 4].y, accuracy: 1e-12)
            }
        }
    }

    func testRoundedRectangleHonoursItsCornerRadius() throws {
        for index in 0..<12 {
            let center = Vec2(x: Double(index) * 2.2 - 10, y: Double(index) * -1.3 + 4)
            let width = 10 + Double(index)
            let height = 6 + Double(index) * 0.5
            let cornerRadius = min(width, height) * 0.5 * (0.1 + 0.4 * Double(index) / 11)
            let primitive = FFCurvePrimitive(
                kind: .roundedRectangle,
                center: FFPoint2(center),
                width: width,
                height: height,
                cornerRadius: cornerRadius
            )
            let payload = try primitive.payload()
            XCTAssertEqual(payload.segments.count, 8, "case \(index)")

            let halfWidth = width / 2
            let halfHeight = height / 2
            let corners = [
                Vec2(x: center.x + halfWidth - cornerRadius, y: center.y - halfHeight + cornerRadius),
                Vec2(x: center.x + halfWidth - cornerRadius, y: center.y + halfHeight - cornerRadius),
                Vec2(x: center.x - halfWidth + cornerRadius, y: center.y + halfHeight - cornerRadius),
                Vec2(x: center.x - halfWidth + cornerRadius, y: center.y - halfHeight + cornerRadius),
            ]
            for (segmentIndex, segment) in payload.segments.enumerated() {
                if segmentIndex.isMultiple(of: 2) {
                    XCTAssertEqual(segment.kind, .bezier, "case \(index) edge \(segmentIndex)")
                } else {
                    let corner = corners[(segmentIndex - 1) / 2]
                    for sample in try samples(of: segment) {
                        XCTAssertEqual(
                            (sample - corner).length,
                            cornerRadius,
                            accuracy: 1e-9,
                            "case \(index) corner \(segmentIndex)"
                        )
                    }
                }
            }

            // A zero corner is the plain rectangle rather than four degenerate
            // arcs, so the shape never becomes a curve with no radius.
            var square = primitive
            XCTAssertTrue(square.set(.cornerRadius, to: 0))
            XCTAssertEqual(try square.payload().segments.count, 4)
        }
    }

    func testPolygonHasOneEdgePerSideAndItsCircumradius() throws {
        for sides in [3, 4, 5, 6, 8, 12, 16] {
            let center = Vec2(x: 7, y: -11)
            let radius = 9.25
            let primitive = FFCurvePrimitive(
                kind: .polygon,
                center: FFPoint2(center),
                radius: radius,
                sides: sides
            )
            let payload = try primitive.payload()
            XCTAssertEqual(payload.segments.count, sides)
            XCTAssertTrue(payload.isClosed)

            for segment in payload.segments {
                XCTAssertEqual(segment.kind, .bezier)
                XCTAssertEqual(segment.controlPoints.count, 2)
                for point in segment.controlPoints {
                    XCTAssertEqual((point.vector - center).length, radius, accuracy: 1e-12)
                }
            }
            let first = try XCTUnwrap(payload.segments.first?.controlPoints.first).vector
            XCTAssertEqual(first.x, center.x, accuracy: 1e-12)
            XCTAssertEqual(first.y, center.y + radius, accuracy: 1e-12)
        }
    }

    // MARK: - Editing after creation

    func testEachPrimitiveIsEditableByItsParametersAndKeepsPositionAndPlane() throws {
        let session = FFEditorSession(document: FFDocument(name: "Primitive edits"))
        let kinds: [FFCurvePrimitiveKind] = [.circle, .ellipse, .rectangle, .roundedRectangle, .polygon]

        for kind in kinds {
            let created = try XCTUnwrap(session.addPrimitive(kind: kind), "\(kind.label) was not created")
            let node = try XCTUnwrap(session.document.node(withID: created))
            let info = try XCTUnwrap(session.primitiveInfo(), "\(kind.label) is not selectable")
            XCTAssertEqual(info.nodeID, created)
            XCTAssertEqual(node.transform, .identity, "\(kind.label) did not start on its plane")
            XCTAssertEqual(session.curveNodes.count, kinds.firstIndex(of: kind)! + 1)

            let radiusBefore = node.curvePrimitive?.radius

            switch kind {
            case .circle:
                XCTAssertTrue(session.setPrimitiveField(.radius, to: 7.5))
                XCTAssertEqual(
                    try XCTUnwrap(session.primitiveInfo()).primitive.radius,
                    7.5,
                    accuracy: 1e-12
                )
                XCTAssertTrue(session.setPrimitiveField(.diameter, to: 20))
                XCTAssertEqual(
                    try XCTUnwrap(session.primitiveInfo()).primitive.radius,
                    10,
                    accuracy: 1e-12
                )
                let payload = try XCTUnwrap(curvePayloads(in: session.document).last)
                for segment in payload.segments {
                    for sample in try samples(of: segment) {
                        XCTAssertEqual((sample - Vec2(x: 0, y: 0)).length, 10, accuracy: 1e-9)
                    }
                }
            case .ellipse:
                XCTAssertTrue(session.setPrimitiveField(.width, to: 22))
                XCTAssertTrue(session.setPrimitiveField(.height, to: 6))
                XCTAssertEqual(
                    try XCTUnwrap(session.primitiveInfo()).primitive.width,
                    22,
                    accuracy: 1e-12
                )
                XCTAssertEqual(
                    try XCTUnwrap(session.primitiveInfo()).primitive.height,
                    6,
                    accuracy: 1e-12
                )
            case .rectangle:
                XCTAssertTrue(session.setPrimitiveField(.width, to: 18))
                XCTAssertTrue(session.setPrimitiveField(.height, to: 4))
            case .roundedRectangle:
                XCTAssertTrue(session.setPrimitiveField(.cornerRadius, to: 2.25))
                XCTAssertEqual(
                    try XCTUnwrap(session.primitiveInfo()).primitive.cornerRadius,
                    2.25,
                    accuracy: 1e-12
                )
            case .polygon:
                XCTAssertTrue(session.setPrimitiveField(.sides, to: 9))
                XCTAssertEqual(session.primitiveInfo()?.primitive.sides, 9)
                XCTAssertEqual(try XCTUnwrap(session.primitiveInfo()).primitive.payload().segments.count, 9)
                XCTAssertEqual(session.primitiveInfo()?.primitive.radius, radiusBefore)
            }

            let edited = try XCTUnwrap(session.document.node(withID: created))
            XCTAssertEqual(edited.transform, .identity, "\(kind.label) left its plane after editing")
            XCTAssertEqual(edited.curvePrimitive?.center, info.primitive.center, "\(kind.label) moved")
            XCTAssertEqual(edited.curvePrimitive?.kind, kind)

            // One undo reverts the last parameter edit and restores the payload
            // that edit replaced; the node itself and its position stay.
            let beforeUndo = try XCTUnwrap(edited.curvePrimitive)
            XCTAssertTrue(session.undo())
            let restored = try XCTUnwrap(session.document.node(withID: created))
            XCTAssertNotEqual(restored.curvePrimitive, beforeUndo)
            XCTAssertEqual(restored.transform, .identity)
            XCTAssertEqual(restored.curvePrimitive?.center, beforeUndo.center)
        }
    }

    func testEditsRefuseOutOfRangeValuesWithoutTouchingTheDocument() throws {
        let session = FFEditorSession(document: FFDocument(name: "Refusals"))
        let circle = try XCTUnwrap(session.addPrimitive(kind: .circle))
        let before = session.document.stateHash
        let undoBefore = session.documentSession.canUndo

        XCTAssertFalse(session.setPrimitiveField(.radius, to: 0))
        XCTAssertFalse(session.setPrimitiveField(.radius, to: -3))
        XCTAssertFalse(session.setPrimitiveField(.radius, to: .nan))
        XCTAssertFalse(session.setPrimitiveField(.diameter, to: 0))
        XCTAssertFalse(session.setPrimitiveField(.sides, to: 6), "a circle has no sides")
        XCTAssertEqual(session.document.stateHash, before)
        XCTAssertEqual(session.documentSession.canUndo, undoBefore)
        XCTAssertFalse(session.documentStatus.isEmpty)

        let polygon = try XCTUnwrap(session.addPrimitive(kind: .polygon))
        let polygonBefore = session.document.stateHash
        XCTAssertFalse(session.setPrimitiveField(.sides, to: 2))
        XCTAssertFalse(session.setPrimitiveField(.sides, to: 4.5))
        XCTAssertFalse(session.setPrimitiveField(.sides, to: 2000))
        XCTAssertEqual(session.document.stateHash, polygonBefore)
        XCTAssertNotNil(session.document.node(withID: polygon))

        let rounded = try XCTUnwrap(session.addPrimitive(kind: .roundedRectangle))
        let roundedBefore = session.document.stateHash
        XCTAssertFalse(session.setPrimitiveField(.cornerRadius, to: -1))
        XCTAssertFalse(session.setPrimitiveField(.cornerRadius, to: 100))
        XCTAssertEqual(session.document.stateHash, roundedBefore)
        XCTAssertNotNil(session.document.node(withID: rounded))

        // A document-level build refuses the same records, so there is one rule.
        var document = session.document
        XCTAssertNil(document.addPrimitive(
            FFCurvePrimitive(kind: .polygon, sides: 2),
            name: "Broken"
        ))
        XCTAssertNil(document.addPrimitive(
            FFCurvePrimitive(kind: .circle, radius: 0),
            name: "Broken"
        ))
        XCTAssertNotNil(session.document.node(withID: circle))
    }

    func testPrimitiveRoundTripsThroughFFPWithItsParameters() throws {
        let session = FFEditorSession(document: FFDocument(name: "Primitive round trip"))
        for kind in FFCurvePrimitiveKind.allCases {
            _ = session.addPrimitive(kind: kind)
        }
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Primitives.ffp")
        try store.save(session.document, to: url)

        let loaded = try store.load(from: url)
        XCTAssertEqual(loaded.stateHash, session.document.stateHash)
        XCTAssertEqual(
            loaded.rootNodes.compactMap(\.curvePrimitive),
            session.document.rootNodes.compactMap(\.curvePrimitive)
        )
        XCTAssertEqual(curvePayloads(in: loaded), curvePayloads(in: session.document))

        let reopened = FFEditorSession(document: loaded)
        reopened.selection.select([try XCTUnwrap(loaded.rootNodes.first?.id)])
        XCTAssertTrue(reopened.setPrimitiveField(.diameter, to: 30))
        XCTAssertEqual(
            try XCTUnwrap(reopened.primitiveInfo()).primitive.radius,
            15,
            accuracy: 1e-12
        )
    }

    func testDocumentsWithoutPrimitivesCarryNoPrimitiveKey() throws {
        let payload = try FFArcTool.payload(
            for: FFArc2D.through(
                Vec2(x: 0, y: 0),
                Vec2(x: 5, y: 3),
                Vec2(x: 10, y: 0)
            )
        )
        let document = FFDocument(
            rootNodes: [FFNode(name: "Arc", geometry: .curve(payload), kind: .curve)]
        )
        let data = try JSONEncoder().encode(document)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("curvePrimitive"))
        XCTAssertTrue(json.contains("\"Arc\""))
    }
}
