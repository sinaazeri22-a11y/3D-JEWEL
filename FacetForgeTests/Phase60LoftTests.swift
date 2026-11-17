import Foundation
import XCTest
@testable import FacetForge

/// Phase 60's acceptance: a loft through three circles has the expected
/// mid-section radius, a smooth loft's surface normals are continuous to 1e-3
/// across an interior section, and a ruled loft is the same shape without that
/// continuity.
///
/// The rows are read from the product, not from a model: `FFLoft` builds the
/// mesh, `FFLoftSampler` resamples a real curve payload, `FFLoftDefinition` is
/// the document record and `FFEditorSession.loft` is the command a later panel
/// will drive. Every radius assertion is a closed-form number derived from the
/// three input circles rather than measured off the mesh.
final class Phase60LoftTests: XCTestCase {
    // MARK: - Geometry

    func testLoftThroughThreeCirclesHitsTheMiddleRadius() throws {
        let sections = [
            try section(radius: 5, at: 0),
            try section(radius: 8, at: 12),
            try section(radius: 4, at: 24),
        ]
        let parameters = FFLoftParameters(mode: .smooth, ringCount: 64, subdivisions: 8)
        let loft = try FFLoft(sections: sections, parameters: parameters)

        XCTAssertEqual(loft.stationCount, 3)
        XCTAssertEqual(loft.vertexCount, 64)
        XCTAssertEqual(loft.estimatedTriangles, 2_172)

        let middle = loft.ring(atStation: 1)
        XCTAssertEqual(middle.count, 64)
        for vertex in middle {
            // The row's own fixture: a circle of radius 8 at z = 12, and the
            // smooth loft passes exactly through its section.
            XCTAssertEqual((vertex.x * vertex.x + vertex.y * vertex.y).squareRoot(), 8, accuracy: 1e-9)
            XCTAssertEqual(vertex.z, 12, accuracy: 1e-9)
        }

        let mesh = try loft.mesh()
        XCTAssertEqual(mesh.triangles.count, loft.estimatedTriangles)
        XCTAssertEqual(mesh.positions.count, 17 * 64)
        XCTAssertTrue(mesh.isWatertight)
        XCTAssertEqual(mesh.classification.boundaryEdgeCount, 0)
        XCTAssertGreaterThan(mesh.signedVolume(), 0, "the body faces outward")
    }

    func testARuledLoftIsStraightBetweenItsStations() throws {
        let loft = try FFLoft(
            sections: [
                try section(radius: 5, at: 0),
                try section(radius: 8, at: 12),
                try section(radius: 4, at: 24),
            ],
            parameters: FFLoftParameters(mode: .ruled, ringCount: 64)
        )
        XCTAssertEqual(loft.crossSectionCount, 3)
        XCTAssertEqual(loft.estimatedTriangles, 380)

        // Halfway from r 5 to r 8 is r 6.5 exactly; a ruled band is a straight
        // side, so the midpoint cannot bulge the way a smooth band can.
        let halfway = loft.ring(atStation: 0.5)
        let radius = halfway.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }
        XCTAssertEqual(radius.max() ?? 0, 6.5, accuracy: 1e-9)
        XCTAssertEqual(radius.min() ?? 0, 6.5, accuracy: 1e-9)

        // Two bands of a ruled loft really are two frusta: the volume is the
        // exact prismatoid integral per band for a 64-gon, and the mesh has to
        // agree with it.
        let area: (Double) -> Double = { radius in
            0.5 * 64 * radius * radius * sin(2 * Double.pi / 64)
        }
        let frustum: (Double, Double, Double) -> Double = { lower, upper, height in
            height / 3 * (area(lower) + area(upper) + (area(lower) * area(upper)).squareRoot())
        }
        let expected = frustum(5, 8, 12) + frustum(8, 4, 12)
        let volume = try loft.mesh().signedVolume()
        XCTAssertEqual(volume, expected, accuracy: 1e-6)
    }

    func testSmoothNormalsAreContinuousAcrossAnInteriorSection() throws {
        let loft = try FFLoft(
            sections: [
                try section(radius: 5, at: 0),
                try section(radius: 8, at: 12),
                try section(radius: 4, at: 24),
            ],
            parameters: FFLoftParameters(mode: .smooth, ringCount: 64)
        )

        var worst = 0.0
        for vertex in 0..<loft.vertexCount {
            let before = loft.normal(atStation: 1 - 1e-6, ringIndex: vertex)
            let after = loft.normal(atStation: 1 + 1e-6, ringIndex: vertex)
            worst = max(worst, (before - after).length)
        }
        XCTAssertLessThanOrEqual(
            worst,
            1e-3,
            "the row allows 1e-3 of normal discontinuity on a smooth loft"
        )
    }

    func testRuledNormalsJumpAtAnInteriorSection() throws {
        // The same three circles with straight sides: the crease is the point of
        // the mode, so the test above cannot pass by accident.
        let loft = try FFLoft(
            sections: [
                try section(radius: 5, at: 0),
                try section(radius: 8, at: 12),
                try section(radius: 4, at: 24),
            ],
            parameters: FFLoftParameters(mode: .ruled, ringCount: 64)
        )

        var worst = 0.0
        for vertex in 0..<loft.vertexCount {
            let before = loft.normal(atStation: 1 - 1e-6, ringIndex: vertex)
            let after = loft.normal(atStation: 1 + 1e-6, ringIndex: vertex)
            worst = max(worst, (before - after).length)
        }
        XCTAssertGreaterThan(
            worst,
            1e-3,
            "a ruled loft creases at an interior section; a smooth one does not"
        )
    }

    func testPerpendicularEndTangencyLeavesTheEndAlongItsNormal() throws {
        let sections = [
            try section(radius: 5, at: 0),
            try section(radius: 8, at: 12),
            try section(radius: 4, at: 24),
        ]
        let squared = try FFLoft(
            sections: sections,
            parameters: FFLoftParameters(mode: .smooth, ringCount: 64, endTangency: .perpendicular)
        )
        let natural = try FFLoft(
            sections: sections,
            parameters: FFLoftParameters(mode: .smooth, ringCount: 64, endTangency: .natural)
        )

        for vertex in 0..<squared.vertexCount {
            let tangent = squared.tangent(atStation: 0, ringIndex: vertex)
            XCTAssertEqual(tangent.x, 0, accuracy: 1e-9)
            XCTAssertEqual(tangent.y, 0, accuracy: 1e-9)
            XCTAssertEqual(tangent.z, 1, accuracy: 1e-9)
        }

        // The natural end tangent is the chord to the next station, which leans
        // outwards wherever the radius grows. Vertex 0 sits on +X, so its chord
        // has a real x component.
        let leaning = natural.tangent(atStation: 0, ringIndex: 0)
        XCTAssertGreaterThan(abs(leaning.x), 1e-3)
    }

    func testAnOpenLoftIsARibbonWithNoCaps() throws {
        let sections = (0..<3).map { index in
            FFLoftSection(
                payload: straightPayload(
                    [point(-5, -2), point(5, -2)],
                    isClosed: false
                ),
                origin: FFPoint3(x: 0, y: 0, z: Double(index) * 5),
                xAxis: FFPoint3(x: 1, y: 0, z: 0),
                yAxis: FFPoint3(x: 0, y: 1, z: 0)
            )
        }
        let loft = try FFLoft(
            sections: sections,
            parameters: FFLoftParameters(mode: .smooth, ringCount: 64, caps: .capped)
        )
        XCTAssertFalse(loft.isClosed)
        XCTAssertEqual(loft.edgeCount, 63)
        XCTAssertEqual(loft.estimatedTriangles, 16 * 63 * 2)

        let mesh = try loft.mesh()
        XCTAssertEqual(mesh.triangles.count, loft.estimatedTriangles)
        XCTAssertGreaterThan(mesh.classification.boundaryEdgeCount, 0, "a ribbon has an open border")
    }

    func testAnOpenLoftIsNotCappedEvenWhenCapsAreAskedFor() throws {
        let open = FFLoftSection(
            payload: straightPayload([point(-5, 0), point(5, 0)], isClosed: false),
            origin: FFPoint3(x: 0, y: 0, z: 0),
            xAxis: FFPoint3(x: 1, y: 0, z: 0),
            yAxis: FFPoint3(x: 0, y: 1, z: 0)
        )
        let capped = try FFLoft(
            sections: [open, shifted(open, z: 5), shifted(open, z: 10)],
            parameters: FFLoftParameters(mode: .ruled, ringCount: 32, caps: .capped)
        )
        let uncapped = try FFLoft(
            sections: [open, shifted(open, z: 5), shifted(open, z: 10)],
            parameters: FFLoftParameters(mode: .ruled, ringCount: 32, caps: .open)
        )
        XCTAssertEqual(
            try capped.mesh().triangles.count,
            try uncapped.mesh().triangles.count,
            "an open section has no inside to cap"
        )
    }

    // MARK: - Refusals

    func testEveryUnusableSetOfSectionsIsRefusedInWords() throws {
        let twoSections = [
            try section(radius: 5, at: 0),
            try section(radius: 8, at: 12),
        ]
        assertRefusal(
            try FFLoft(sections: twoSections, parameters: FFLoftParameters()),
            equals: .notEnoughSections(2)
        )

        let mixed = FFLoftSection(
            payload: straightPayload([point(-5, 0), point(5, 0)], isClosed: false),
            origin: FFPoint3(x: 0, y: 0, z: 12),
            xAxis: FFPoint3(x: 1, y: 0, z: 0),
            yAxis: FFPoint3(x: 0, y: 1, z: 0)
        )
        assertRefusal(
            try FFLoft(
                sections: [try section(radius: 5, at: 0), mixed, try section(radius: 4, at: 24)],
                parameters: FFLoftParameters()
            ),
            equals: .mixedSectionStyles
        )

        assertRefusal(
            try FFLoft(
                sections: [
                    try section(radius: 5, at: 0),
                    try section(radius: 8, at: 0),
                    try section(radius: 4, at: 24),
                ],
                parameters: FFLoftParameters()
            ),
            equals: .coincidentSections(1)
        )

        assertRefusal(
            try FFLoft(
                sections: [
                    try section(radius: 5, at: 0),
                    try section(radius: 8, at: 12),
                    try section(radius: 4, at: 24),
                ],
                parameters: FFLoftParameters(ringCount: 4)
            ),
            equals: .ringCountOutOfRange(4)
        )

        assertRefusal(
            try FFLoft(
                sections: [
                    try section(radius: 5, at: 0),
                    try section(radius: 8, at: 12),
                    try section(radius: 4, at: 24),
                ],
                parameters: FFLoftParameters(subdivisions: 0)
            ),
            equals: .subdivisionOutOfRange(0)
        )

        let collapsed = FFLoftSection(
            payload: straightPayload([point(0, 0), point(0, 0)], isClosed: false),
            origin: FFPoint3(x: 0, y: 0, z: 12),
            xAxis: FFPoint3(x: 1, y: 0, z: 0),
            yAxis: FFPoint3(x: 0, y: 1, z: 0)
        )
        assertRefusal(
            try FFLoft(
                sections: [try section(radius: 5, at: 0), collapsed, try section(radius: 4, at: 24)],
                parameters: FFLoftParameters()
            ),
            equals: .degenerateSection(1)
        )
    }

    func testARefusalReadsAsASentence() {
        XCTAssertEqual(
            FFLoftError.coincidentSections(1).errorDescription,
            "Sections 1 and 2 sit on top of each other, so the loft has no height there"
        )
        XCTAssertEqual(
            FFLoftError.ringCountOutOfRange(4).errorDescription,
            "4 vertices is outside 8-512"
        )
        XCTAssertFalse(
            (FFLoftError.sectionNotSimple(2).errorDescription ?? "").isEmpty
        )
    }

    // MARK: - The record

    func testTheRecordRebuildsTheCommittedBody() throws {
        let definition = FFLoftDefinition(
            sections: [
                try section(radius: 5, at: 0),
                try section(radius: 8, at: 12),
                try section(radius: 4, at: 24),
            ],
            parameters: FFLoftParameters(mode: .smooth, ringCount: 48, subdivisions: 4)
        )
        let direct = try FFLoft(
            sections: definition.sections,
            parameters: definition.parameters
        ).mesh()
        let rebuilt = try definition.mesh()
        XCTAssertEqual(rebuilt.positions.count, direct.positions.count)
        XCTAssertEqual(rebuilt.triangles.count, direct.triangles.count)
        for index in 0..<direct.positions.count {
            XCTAssertEqual(rebuilt.positions[index].x, direct.positions[index].x, accuracy: 1e-12)
            XCTAssertEqual(rebuilt.positions[index].y, direct.positions[index].y, accuracy: 1e-12)
            XCTAssertEqual(rebuilt.positions[index].z, direct.positions[index].z, accuracy: 1e-12)
        }
    }

    func testTheRecordSurvivesEncodeAndDecode() throws {
        let definition = FFLoftDefinition(
            sections: [
                try section(radius: 5, at: 0),
                try section(radius: 8, at: 12),
                try section(radius: 4, at: 24),
            ],
            parameters: FFLoftParameters(mode: .ruled, ringCount: 32, subdivisions: 2, caps: .open),
            sourceSectionNodeIDs: [UUID(), UUID(), UUID()]
        )
        let data = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(FFLoftDefinition.self, from: data)
        XCTAssertEqual(decoded, definition)
        XCTAssertEqual(
            try decoded.mesh().triangles.count,
            try definition.mesh().triangles.count
        )
    }

    func testTheLoftCommandIsOneNodeAndOneUndo() throws {
        var document = FFDocument(name: "Phase 60")
        var nodes: [FFNode] = []
        for (index, radius) in [5.0, 8.0, 4.0].enumerated() {
            nodes.append(FFNode(
                name: "Section \(index + 1)",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 0, z: Double(index) * 12),
                    rotation: FFPoint3(x: 0, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .curve(try circlePayload(radius: radius)),
                kind: .curve,
                layerID: document.currentLayerID
            ))
        }
        document.rootNodes = nodes
        let session = FFEditorSession(document: document)
        let before = session.document

        let created = session.loft(
            sectionNodeIDs: nodes.map(\.id),
            parameters: FFLoftParameters(mode: .smooth, ringCount: 64)
        )
        let createdID = try XCTUnwrap(created)
        XCTAssertEqual(session.document.rootNodes.count, 4, "the sections stay in the document")
        XCTAssertEqual(session.document.rootNodes[3].id, createdID)
        XCTAssertNotNil(session.document.rootNodes[3].loft)
        XCTAssertEqual(session.document.rootNodes[3].kind, .solid)
        XCTAssertEqual(session.selection.selectedIDs, Set([createdID]))

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document, before, "one command, one undo step")
    }

    func testACommitThroughTheSessionBakesTheSectionsItWasShown() throws {
        var document = FFDocument(name: "Phase 60 UI")
        var nodes: [FFNode] = []
        for (index, radius) in [5.0, 8.0, 4.0].enumerated() {
            nodes.append(FFNode(
                name: "Section \(index + 1)",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 0, z: Double(index) * 12),
                    rotation: FFPoint3(x: 0, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .curve(try circlePayload(radius: radius)),
                kind: .curve,
                layerID: document.currentLayerID
            ))
        }
        document.rootNodes = nodes
        let session = FFEditorSession(document: document)

        let created = try XCTUnwrap(session.loft(
            sectionNodeIDs: nodes.map(\.id),
            parameters: FFLoftParameters(mode: .ruled, ringCount: 32)
        ))
        let node = try XCTUnwrap(session.document.node(withID: created))
        let mesh = try XCTUnwrap(node.geometry?.mesh?.mesh)
        let middle = mesh.positions.filter { abs($0.z - 12) < 1e-9 }
        XCTAssertEqual(middle.count, 32)
        for vertex in middle {
            XCTAssertEqual((vertex.x * vertex.x + vertex.y * vertex.y).squareRoot(), 8, accuracy: 1e-9)
        }
        XCTAssertFalse(session.documentStatus.isEmpty)
    }

    func testTheSessionRefusesTwoSectionsWithoutWritingHistory() throws {
        var document = FFDocument(name: "Phase 60 refusal")
        let first = FFNode(
            name: "Section 1",
            geometry: .curve(try circlePayload(radius: 5)),
            kind: .curve,
            layerID: document.currentLayerID
        )
        let second = FFNode(
            name: "Section 2",
            transform: FFTransform(
                translation: FFPoint3(x: 0, y: 0, z: 12),
                rotation: FFPoint3(x: 0, y: 0, z: 0),
                scale: FFPoint3(x: 1, y: 1, z: 1)
            ),
            geometry: .curve(try circlePayload(radius: 8)),
            kind: .curve,
            layerID: document.currentLayerID
        )
        document.rootNodes = [first, second]
        let session = FFEditorSession(document: document)
        let before = session.document

        XCTAssertNil(session.loft(sectionNodeIDs: [first.id, second.id]))
        XCTAssertEqual(session.documentStatus, "A loft needs at least 3 sections; 2 given")
        XCTAssertFalse(session.documentSession.canUndo)
        XCTAssertEqual(session.document, before)
    }

    func testADocumentWithoutALoftEncodesNoLoftKey() throws {
        var document = FFDocument(name: "Phase 60 empty")
        document.rootNodes = [FFNode(
            name: "Ring",
            geometry: .curve(try circlePayload(radius: 5)),
            kind: .curve
        )]
        let data = try JSONEncoder().encode(document)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"loft\""))
    }

    // MARK: - Fixtures

    private func point(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x: x, y: y)
    }

    /// A circle of `radius` on the plane z = `z`, as four exact rational
    /// quadratic quarter spans.
    private func circlePayload(radius: Double) throws -> FFCurvePayload {
        let segments = (0..<4).map { index in
            FFPrimitiveGeometry.circularQuarter(
                center: .zero,
                radius: radius,
                startAngle: Double(index) * Double.pi / 2
            )
        }
        return FFCurvePayload(segments: segments, isClosed: true)
    }

    private func section(radius: Double, at height: Double) throws -> FFLoftSection {
        FFLoftSection(
            payload: try circlePayload(radius: radius),
            origin: FFPoint3(x: 0, y: 0, z: height),
            xAxis: FFPoint3(x: 1, y: 0, z: 0),
            yAxis: FFPoint3(x: 0, y: 1, z: 0)
        )
    }

    private func shifted(_ section: FFLoftSection, z: Double) -> FFLoftSection {
        var copy = section
        copy.origin = FFPoint3(x: section.origin.x, y: section.origin.y, z: z)
        return copy
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

    private func assertRefusal<T>(
        _ expression: @autoclosure () throws -> T,
        equals expected: FFLoftError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("expected \(expected), but the loft was built", file: file, line: line)
        } catch let error as FFLoftError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
