import Foundation
import XCTest
@testable import FacetForge

/// Phase 49's acceptance: each of the twelve library sections opens as one valid
/// closed curve, and the sweep preview works with every one of them.
///
/// Every proof states its premise. A section's area is not compared against the
/// builder's own idea of it: the expected area comes from the plane geometry of
/// that section — a box less its corner cuts, a circular segment over a chord, a
/// trapezoid — while the measured area is Green's theorem over a dense sampling
/// of the payload. A swept volume is not compared against the model that
/// produced it either: Pappus's theorem gives it from the same polygon, so the
/// only remaining difference is the angular chord of the preview mesh, and the
/// convergence test measures that rather than assuming a tolerance for it.
final class Phase49ProfileTests: XCTestCase {
    // MARK: - Fixtures

    private let standard = FFRingProfileParameters(
        boreRadius: 9.5,
        width: 2,
        thickness: 1.6
    )

    private func parameters(
        _ bore: Double,
        _ width: Double,
        _ thickness: Double
    ) -> FFRingProfileParameters {
        FFRingProfileParameters(boreRadius: bore, width: width, thickness: thickness)
    }

    private func payload(
        _ kind: FFRingProfileKind,
        _ parameters: FFRingProfileParameters
    ) throws -> FFCurvePayload {
        try FFRingProfile(kind: kind, parameters: parameters).payload()
    }

    /// The payload as a polygon: every span sampled uniformly, without repeating
    /// the closing point, in path order.
    private func samples(
        _ payload: FFCurvePayload,
        perSpan: Int = 512
    ) throws -> [Vec2] {
        var points: [Vec2] = []
        for segment in payload.segments {
            let curve = try XCTUnwrap(segment.curve)
            for step in 0..<perSpan {
                points.append(curve.point(at: Double(step) / Double(perSpan)))
            }
        }
        return points
    }

    /// Twice the signed area of the polygon through `points`, by Green's theorem.
    private func twiceArea(_ points: [Vec2]) -> Double {
        var total = 0.0
        for index in points.indices {
            let next = (index + 1) % points.count
            total += points[index].cross(points[next])
        }
        return total
    }

    private func area(_ points: [Vec2]) -> Double {
        abs(twiceArea(points)) / 2
    }

    /// The x coordinate of the polygon's area centroid, by the same theorem.
    private func centroidX(_ points: [Vec2]) -> Double {
        let doubled = twiceArea(points)
        guard abs(doubled) > 0 else { return 0 }
        var total = 0.0
        for index in points.indices {
            let next = (index + 1) % points.count
            let cross = points[index].cross(points[next])
            total += (points[index].x + points[next].x) * cross
        }
        return total / (3 * doubled)
    }

    /// The exact area of a circular segment whose chord is `2 * half` and whose
    /// sagitta is `sagitta`. Every curved face in the library is such an arc, so
    /// this one formula covers the crown, the bore relief and the fillets.
    private func segmentArea(sagitta: Double, half: Double) -> Double {
        let radius = (sagitta * sagitta + half * half) / (2 * sagitta)
        let angle = asin(min(1, half / radius))
        return radius * radius * (angle - sin(angle) * cos(angle))
    }

    /// The area of a section from its plane geometry alone, using the same
    /// design proportions the builder documents. Restating them here is the
    /// point: a builder proportion that drifts no longer matches its proof.
    private func analyticArea(
        _ kind: FFRingProfileKind,
        _ parameters: FFRingProfileParameters
    ) -> Double {
        let thickness = parameters.thickness
        let half = parameters.halfWidth
        let box = 2 * half * thickness
        switch kind {
        case .dShape:
            // Half an ellipse with semi-axes `thickness` and `half`.
            return Double.pi * thickness * half / 2
        case .flat:
            let corner = 0.15 * min(thickness, parameters.width)
            return box - corner * corner * (4 - Double.pi)
        case .comfortFit:
            // The bore is relieved to `bore + relief` at the band edges, so the
            // metal is the narrow box between the chord and the crest plus the
            // lobe the arc adds below the chord, less the two crest corners.
            let relief = 0.30 * min(thickness, half)
            let corner = 0.15 * min(thickness, half)
            return 2 * half * (thickness - relief)
                + segmentArea(sagitta: relief, half: half)
                - corner * corner * (2 - Double.pi / 2)
        case .comfortDome:
            // The relieved bore lobe plus half an ellipse from the same chord.
            let relief = 0.30 * min(thickness, half)
            return segmentArea(sagitta: relief, half: half)
                + Double.pi * (thickness - relief) * half / 2
        case .knifeEdge:
            return half * thickness
        case .knifeChamfer:
            return thickness * (half + 0.25 * half)
        case .cathedral:
            let radius = min(thickness / 2, half / 2)
            return box - radius * radius * (2 - Double.pi / 2)
        case .cathedralChamfer:
            let chamfer = min(0.4 * thickness, 0.4 * half)
            return box - chamfer * chamfer
        case .cathedralStep:
            return box - 2 * (0.35 * thickness) * (0.4 * half)
        case .oval:
            return Double.pi * (thickness / 2) * half
        case .cushion:
            let corner = 0.45 * min(thickness, parameters.width)
            return box - corner * corner * (4 - Double.pi)
        case .bevel:
            let chamfer = 0.2 * min(thickness, parameters.width)
            return box - 2 * chamfer * chamfer
        }
    }

    // MARK: - The library

    func testLibraryOffersTwelveDistinctSections() {
        XCTAssertEqual(FFRingProfileKind.allCases.count, 12)
        XCTAssertEqual(Set(FFRingProfileKind.allCases.map(\.rawValue)).count, 12)
        for kind in FFRingProfileKind.allCases {
            XCTAssertFalse(kind.label.isEmpty, "\(kind.rawValue) has no label")
            XCTAssertFalse(kind.detail.isEmpty, "\(kind.rawValue) has no description")
        }
    }

    func testEverySectionOpensAsOneClosedCurve() throws {
        for kind in FFRingProfileKind.allCases {
            let payload = try payload(kind, standard)
            XCTAssertTrue(payload.isClosed, "\(kind.label) is not closed")
            XCTAssertGreaterThanOrEqual(payload.segments.count, 2, "\(kind.label) is a single span")
            for segment in payload.segments {
                XCTAssertNotNil(
                    segment.curve,
                    "\(kind.label) has a span that cannot be rebuilt"
                )
            }
            for index in payload.segments.indices {
                let current = try XCTUnwrap(payload.segments[index].curve)
                let next = try XCTUnwrap(
                    payload.segments[(index + 1) % payload.segments.count].curve
                )
                XCTAssertLessThanOrEqual(
                    current.end.distance(to: next.start),
                    1e-9,
                    "\(kind.label) has a gap at span \(index)"
                )
            }
        }
    }

    func testEverySectionIsADistinctCurve() throws {
        var seen: [FFCurvePayload] = []
        for kind in FFRingProfileKind.allCases {
            let payload = try payload(kind, standard)
            XCTAssertFalse(seen.contains(payload), "\(kind.label) duplicates an earlier section")
            seen.append(payload)
        }
        XCTAssertEqual(seen.count, 12)
    }

    /// Every kind is built from the same three measurements, so a section that
    /// only works at the default proportions is not a library section. The band
    /// box is the invariant: a section may not cross the bore, pass the crest or
    /// leave a side face.
    func testEverySectionStaysInsideItsBandBox() throws {
        let sets = [
            standard,
            parameters(8.2, 1.4, 1.1),
            parameters(10.7, 2.8, 2.2),
            parameters(7.0, 3.2, 0.9),
            parameters(12.0, 1.0, 2.6),
            parameters(9.5, 2.0, 0.6),
        ]
        for kind in FFRingProfileKind.allCases {
            for parameters in sets {
                let points = try samples(try payload(kind, parameters), perSpan: 64)
                XCTAssertFalse(points.isEmpty, "\(kind.label) sampled nothing")
                for point in points {
                    XCTAssertGreaterThanOrEqual(
                        point.x,
                        parameters.boreRadius - 1e-9,
                        "\(kind.label) crosses the bore"
                    )
                    XCTAssertLessThanOrEqual(
                        point.x,
                        parameters.outerRadius + 1e-9,
                        "\(kind.label) passes the crest"
                    )
                    XCTAssertGreaterThanOrEqual(
                        point.y,
                        -parameters.halfWidth - 1e-9,
                        "\(kind.label) passes a side face"
                    )
                    XCTAssertLessThanOrEqual(
                        point.y,
                        parameters.halfWidth + 1e-9,
                        "\(kind.label) passes a side face"
                    )
                }
            }
        }
    }

    func testEverySectionReachesItsBoreCrestAndEdges() throws {
        for kind in FFRingProfileKind.allCases {
            let points = try samples(try payload(kind, standard), perSpan: 256)
            let minX = try XCTUnwrap(points.map(\.x).min())
            let maxX = try XCTUnwrap(points.map(\.x).max())
            let minY = try XCTUnwrap(points.map(\.y).min())
            let maxY = try XCTUnwrap(points.map(\.y).max())
            XCTAssertEqual(minX, standard.boreRadius, accuracy: 1e-9, "\(kind.label) bore")
            XCTAssertEqual(maxX, standard.outerRadius, accuracy: 1e-9, "\(kind.label) crest")
            XCTAssertEqual(minY, -standard.halfWidth, accuracy: 1e-9, "\(kind.label) edge")
            XCTAssertEqual(maxY, standard.halfWidth, accuracy: 1e-9, "\(kind.label) edge")
        }
    }

    // MARK: - Areas and centroids

    func testEverySectionAreaMatchesItsPlaneGeometry() throws {
        for kind in FFRingProfileKind.allCases {
            let points = try samples(try payload(kind, standard), perSpan: 512)
            let expected = analyticArea(kind, standard)
            XCTAssertEqual(
                area(points),
                expected,
                accuracy: max(1e-9, expected * 1e-5),
                "\(kind.label) area"
            )
        }
    }

    func testSymmetricSectionsCentreOnTheirBandMidline() throws {
        let symmetric: [FFRingProfileKind] = [.flat, .oval, .cushion, .bevel]
        let expected = standard.boreRadius + standard.thickness / 2
        for kind in symmetric {
            let points = try samples(try payload(kind, standard), perSpan: 512)
            XCTAssertEqual(centroidX(points), expected, accuracy: 1e-9, "\(kind.label) centroid")
        }
    }

    /// A knife edge is a triangle in section, so its centroid is a third of the
    /// thickness out from the bore rather than half of it.
    func testKnifeEdgeCentroidIsATriangleCentroid() throws {
        let points = try samples(try payload(.knifeEdge, standard), perSpan: 8)
        XCTAssertEqual(
            centroidX(points),
            standard.boreRadius + standard.thickness / 3,
            accuracy: 1e-9
        )
    }

    // MARK: - Sweep preview

    func testSweepPreviewMeshesEverySection() throws {
        for kind in FFRingProfileKind.allCases {
            let profile = FFRingProfile(kind: kind, parameters: standard)
            let sweep = try FFRingSweep(profile: profile, angularSegments: 96)
            let mesh = try XCTUnwrap(
                sweep.mesh(profileSamplesPerSpan: 8),
                "\(kind.label) has no preview mesh"
            )
            let spans = try payload(kind, standard).segments.count
            XCTAssertEqual(mesh.positions.count, spans * 8 * 96, "\(kind.label) vertex count")
            XCTAssertEqual(mesh.triangles.count, spans * 8 * 96 * 2, "\(kind.label) face count")

            let classification = mesh.classification
            XCTAssertTrue(classification.isWatertight, "\(kind.label) preview is not watertight")
            XCTAssertTrue(classification.isManifold, "\(kind.label) preview is not manifold")
            XCTAssertTrue(
                classification.isConsistentlyOriented,
                "\(kind.label) preview has inconsistent winding"
            )

            for position in mesh.positions {
                let radius = sweep.surface.radialDistance(of: position)
                let height = sweep.surface.axialCoordinate(of: position)
                XCTAssertGreaterThanOrEqual(radius, standard.boreRadius - 1e-9)
                XCTAssertLessThanOrEqual(radius, standard.outerRadius + 1e-9)
                XCTAssertGreaterThanOrEqual(height, -standard.halfWidth - 1e-9)
                XCTAssertLessThanOrEqual(height, standard.halfWidth + 1e-9)
            }
        }
    }

    /// Pappus: a plane area revolved about an axis outside it sweeps a volume of
    /// `2 pi * area * centroid distance`. Both terms come from the same polygon
    /// the mesh was built from, so the only difference left is the angular chord
    /// and the tolerance only has to cover that.
    func testSweepVolumeMatchesPappusForEverySection() throws {
        for kind in FFRingProfileKind.allCases {
            let profile = FFRingProfile(kind: kind, parameters: standard)
            let sweep = try FFRingSweep(profile: profile, angularSegments: 192)
            let volume = try XCTUnwrap(sweep.volume(profileSamplesPerSpan: 8))
            let points = try samples(try profile.payload(), perSpan: 8)
            let expected = 2 * Double.pi * area(points) * centroidX(points)
            XCTAssertEqual(
                abs(volume),
                expected,
                accuracy: expected * 2e-3,
                "\(kind.label) swept volume"
            )
        }
    }

    /// The same claim without the polygon: the analytic area of the section and
    /// the section's own centroid, sampled far enough that the profile's chord
    /// error is below the angular one.
    func testSweptVolumeMatchesTheAnalyticSolid() throws {
        let symmetric: [FFRingProfileKind] = [.flat, .oval, .cushion, .bevel]
        let midline = standard.boreRadius + standard.thickness / 2
        for kind in symmetric {
            let expected = 2 * Double.pi * analyticArea(kind, standard) * midline
            let sweep = try FFRingSweep(
                profile: FFRingProfile(kind: kind, parameters: standard),
                angularSegments: 192
            )
            let volume = try XCTUnwrap(sweep.volume(profileSamplesPerSpan: 32))
            XCTAssertEqual(abs(volume), expected, accuracy: expected * 2e-3, "\(kind.label)")
        }

        let knifeArea = analyticArea(.knifeEdge, standard)
        let knifeCentroid = standard.boreRadius + standard.thickness / 3
        let knifeExpected = 2 * Double.pi * knifeArea * knifeCentroid
        let knife = try FFRingSweep(profile: FFRingProfile(kind: .knifeEdge), angularSegments: 192)
        let knifeVolume = try XCTUnwrap(knife.volume(profileSamplesPerSpan: 32))
        XCTAssertEqual(abs(knifeVolume), knifeExpected, accuracy: knifeExpected * 2e-3)
    }

    /// The preview mesh is a display approximation, so its error must be the
    /// angle's, and it must fall as the angle count rises. Refining only the
    /// angle isolates that term: the profile polygon does not change.
    func testSweepVolumeConvergesAsTheAngleRefines() throws {
        for kind in [FFRingProfileKind.dShape, .cathedral] {
            let profile = FFRingProfile(kind: kind, parameters: standard)
            let points = try samples(try profile.payload(), perSpan: 8)
            let expected = 2 * Double.pi * area(points) * centroidX(points)

            func error(at segments: Int) throws -> Double {
                let sweep = try FFRingSweep(profile: profile, angularSegments: segments)
                let volume = try XCTUnwrap(sweep.volume(profileSamplesPerSpan: 8))
                return abs(abs(volume) - expected)
            }

            let coarse = try error(at: 48)
            let fine = try error(at: 96)
            let finer = try error(at: 192)
            XCTAssertLessThan(fine / coarse, 0.3, "\(kind.label) did not converge from 48 to 96")
            XCTAssertLessThan(finer / fine, 0.3, "\(kind.label) did not converge from 96 to 192")
            XCTAssertLessThan(finer, expected * 1e-3, "\(kind.label) preview error is too large")
        }
    }

    func testSweepPreviewWorksOffTheDefaultAxis() throws {
        let sweep = try FFRingSweep(
            profile: FFRingProfile(kind: .cathedral),
            axis: .unitX,
            angularSegments: 48
        )
        XCTAssertTrue(sweep.surface.profile.plane.contains(.zero))
        let mesh = try XCTUnwrap(sweep.mesh(profileSamplesPerSpan: 4))
        XCTAssertTrue(mesh.classification.isWatertight)
        for position in mesh.positions {
            let radius = sweep.surface.radialDistance(of: position)
            XCTAssertGreaterThanOrEqual(radius, standard.boreRadius - 1e-9)
            XCTAssertLessThanOrEqual(radius, standard.outerRadius + 1e-9)
        }
    }

    // MARK: - Opening a section in a document

    func testEverySectionOpensInTheDocument() throws {
        var document = FFDocument(name: "Library")
        for kind in FFRingProfileKind.allCases {
            let id = try XCTUnwrap(
                document.addProfile(FFRingProfile(kind: kind), name: kind.label),
                "\(kind.label) did not open"
            )
            XCTAssertEqual(document.node(withID: id)?.kind, .curve)
        }
        XCTAssertEqual(document.rootNodes.count, 12)
        XCTAssertEqual(Set(document.rootNodes.map(\.name)).count, 12)
        for kind in FFRingProfileKind.allCases {
            let node = try XCTUnwrap(document.rootNodes.first { $0.name == kind.label })
            XCTAssertEqual(
                node.geometry?.curve,
                try payload(kind, standard),
                "\(kind.label) opened as different geometry"
            )
        }
    }

    func testInsertingAProfileIsOneUndo() throws {
        let session = FFEditorSession(document: FFDocument(name: "Profiles"))
        let before = session.document.rootNodes.count
        let depth = session.documentSession.undoDepth

        let id = try XCTUnwrap(session.insertProfile(.cathedral))
        XCTAssertEqual(session.document.rootNodes.count, before + 1)
        XCTAssertEqual(session.documentSession.undoDepth, depth + 1)
        XCTAssertEqual(session.selection.selectedIDs.count, 1)
        XCTAssertTrue(session.selection.selectedIDs.contains(id))

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes.count, before)
        XCTAssertNil(session.document.node(withID: id))

        XCTAssertTrue(session.redo())
        XCTAssertNotNil(session.document.node(withID: id))
        XCTAssertEqual(session.documentSession.undoDepth, depth + 1)
    }

    /// What opens is an ordinary payload, not a locked blob: a weight edit goes
    /// through the same document seam every curve tool uses, the geometry
    /// changes, and the section stays closed because the edit moved no endpoint.
    func testOpenedProfileIsEditableCurveGeometry() throws {
        var document = FFDocument(name: "Edit")
        let id = try XCTUnwrap(document.addProfile(FFRingProfile(kind: .dShape), name: "D-shape"))
        let before = try XCTUnwrap(document.curvePayload(forNodeID: id))
        let spans = before.segments.count
        let crown = try XCTUnwrap(before.segments[1].curve)

        try document.editCurvePayload(nodeID: id) { payload in
            guard payload.segments.count > 1,
                  payload.segments[1].weights.count == 3
            else { return }
            payload.segments[1].weights[1] *= 0.9
        }

        let after = try XCTUnwrap(document.curvePayload(forNodeID: id))
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.segments.count, spans)
        XCTAssertNil(after.segments.first { $0.curve == nil })
        for index in after.segments.indices {
            let current = try XCTUnwrap(after.segments[index].curve)
            let next = try XCTUnwrap(after.segments[(index + 1) % after.segments.count].curve)
            XCTAssertLessThanOrEqual(current.end.distance(to: next.start), 1e-9)
        }
        let editedCrown = try XCTUnwrap(after.segments[1].curve)
        XCTAssertEqual(editedCrown.start.distance(to: crown.start), 0, accuracy: 1e-12)
        XCTAssertEqual(editedCrown.end.distance(to: crown.end), 0, accuracy: 1e-12)
    }

    /// The library must not need a schema field: a document holding all twelve
    /// sections survives the ordinary Codable round trip at the same version.
    func testProfileNeedsNoFormatChange() throws {
        var document = FFDocument(name: "Round trip")
        for kind in FFRingProfileKind.allCases {
            XCTAssertNotNil(document.addProfile(FFRingProfile(kind: kind), name: kind.label))
        }
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(FFDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.schemaVersion, FFDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.rootNodes.count, 12)
    }

    // MARK: - Refusals

    func testRefusalsCarrySentences() {
        let zeroThickness = FFRingProfileParameters(
            boreRadius: 9.5,
            width: 2,
            thickness: 0
        )
        XCTAssertFalse(zeroThickness.isValid)
        XCTAssertThrowsError(
            try FFRingProfile(kind: .flat, parameters: zeroThickness).payload()
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                FFRingProfileError.invalidParameters.errorDescription
            )
        }
        XCTAssertThrowsError(try FFRingProfile(kind: .flat).spatial(axis: .zero)) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                FFRingProfileError.invalidAxis.errorDescription
            )
        }
    }
}
