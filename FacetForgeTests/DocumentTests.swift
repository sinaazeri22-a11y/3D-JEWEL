import XCTest
@testable import FacetForge

final class DocumentTests: XCTestCase {
    // MARK: - Fixtures

    private func emptyDocument() -> FFDocument {
        FFDocument(
            name: "Empty Bench",
            rootNodes: [FFNode(name: "Bench")]
        )
    }

    private func curveDocument() throws -> FFDocument {
        let bezier = try XCTUnwrap(Bezier2D([
            Vec2(x: 0, y: 0),
            Vec2(x: 3, y: 4),
            Vec2(x: 7, y: 4),
            Vec2(x: 10, y: 0),
        ]))
        let nurbs = try XCTUnwrap(NURBSCurve2D(
            degree: 1,
            controlPoints: [Vec2(x: 10, y: 0), Vec2(x: 20, y: 0)],
            weights: [1, 1],
            knots: [0, 0, 1, 1]
        ))
        let path = try XCTUnwrap(CurvePath2D.joining([.bezier(bezier), .nurbs(nurbs)]))

        let material = FFMaterial(name: "18k Yellow Gold", baseColor: .gold, metallic: 1, roughness: 0.2)
        let transform = FFTransform(
            translation: FFPoint3(x: 1, y: 2, z: 3),
            rotation: FFPoint3(x: 0.1, y: 0.2, z: 0.3),
            scale: FFPoint3(x: 1.5, y: 1, z: 0.8)
        )
        let prongBezier = try XCTUnwrap(Bezier2D([
            Vec2(x: 2, y: 2),
            Vec2(x: 4, y: 6),
            Vec2(x: 0, y: 6),
            Vec2(x: 2, y: 2),
        ]))
        let prongGeometry = FFNodeGeometry.curve(FFCurvePayload(
            segments: [FFCurveSegment(.bezier(prongBezier))],
            isClosed: true
        ))

        return FFDocument(
            name: "Solitaire",
            displayUnit: .millimetres,
            materials: [material],
            rootNodes: [
                FFNode(
                    name: "Shank",
                    transform: transform,
                    geometry: .curve(FFCurvePayload(path)),
                    materialID: material.id,
                    children: [FFNode(name: "Prong", geometry: prongGeometry)]
                )
            ]
        )
    }

    private func meshDocument() throws -> FFDocument {
        let positions = [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 10, y: 0, z: 0),
            Vec3(x: 0, y: 10, z: 0),
            Vec3(x: 0, y: 0, z: 10),
        ]
        let mesh = try XCTUnwrap(IndexedMesh(positions: positions, indices: [
            0, 2, 1,
            0, 1, 3,
            0, 3, 2,
            1, 2, 3,
        ]))
        let material = FFMaterial(name: "Platinum", baseColor: FFRGBA(red: 0.9, green: 0.9, blue: 0.92))
        return FFDocument(
            name: "Tetra",
            materials: [material],
            rootNodes: [
                FFNode(name: "Body", geometry: .mesh(FFMeshPayload(mesh)), materialID: material.id)
            ]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent(
            "DocumentTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Round trips

    func testEmptyDocumentRoundTripsThroughCanonicalJSON() throws {
        let document = emptyDocument()
        let data = try document.encoded()
        let loaded = try FFDocument.decoded(from: data)

        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded.stateHash, document.stateHash)
        XCTAssertEqual(loaded.schemaVersion, FFDocument.currentSchemaVersion)
        XCTAssertEqual(loaded.nodeCount, 1)
        XCTAssertEqual(loaded.name, "Empty Bench")
    }

    func testCurveDocumentRoundTripsWithTransformsAndMaterials() throws {
        let document = try curveDocument()
        let loaded = try FFDocument.decoded(from: try document.encoded())

        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded.stateHash, document.stateHash)
        XCTAssertEqual(loaded.nodeCount, 2)
        XCTAssertEqual(loaded.curveNodeCount, 2)
        XCTAssertEqual(loaded.meshNodeCount, 0)

        let shank = try XCTUnwrap(loaded.rootNodes.first)
        let material = try XCTUnwrap(loaded.material(withID: try XCTUnwrap(shank.materialID)))
        XCTAssertEqual(material.name, "18k Yellow Gold")
        XCTAssertEqual(shank.transform.matrix.transformedPoint(Vec3.zero), Vec3(x: 1, y: 2, z: 3))

        let payload = try XCTUnwrap(shank.geometry?.curve)
        let path = try XCTUnwrap(payload.path())
        XCTAssertEqual(path.curves.count, 2)
        XCTAssertFalse(path.isClosed())

        let prongPayload = try XCTUnwrap(shank.children.first?.geometry?.curve)
        XCTAssertTrue(prongPayload.isClosed)
        XCTAssertTrue(try XCTUnwrap(prongPayload.path()).isClosed())
    }

    func testMeshDocumentRoundTripsAndRebuildsTheKernelMesh() throws {
        let document = try meshDocument()
        let loaded = try FFDocument.decoded(from: try document.encoded())

        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded.meshNodeCount, 1)
        XCTAssertEqual(loaded.nodeCount, 1)

        let payload = try XCTUnwrap(loaded.rootNodes.first?.geometry?.mesh)
        let mesh = try XCTUnwrap(payload.mesh)
        XCTAssertEqual(mesh.positions.count, 4)
        XCTAssertEqual(mesh.triangleCount, 4)
        XCTAssertEqual(mesh.bounds?.minimum, Vec3.zero)
        XCTAssertEqual(mesh.bounds?.maximum, Vec3(x: 10, y: 10, z: 10))
    }

    // MARK: - Store

    func testStoreSavesAtomicallyAndLoadsTheSameDocument() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FFDocumentStore()
        let url = directory.appendingPathComponent("solitaire.fdoc")
        var document = try curveDocument()

        try store.save(document, to: url)
        XCTAssertEqual(try store.load(from: url), document)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["solitaire.fdoc"],
            "one save should leave exactly the bundle"
        )

        var renamed = document
        renamed.name = "Solitaire v2"
        try store.save(renamed, to: url)
        XCTAssertEqual(try store.load(from: url).name, "Solitaire v2")
        // Phase 26 keeps the previous bundle for recovery, so a second save
        // leaves exactly one hidden sibling beside the primary. No temporary
        // directory may survive either save.
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(entries, [".solitaire.fdoc.previous", "solitaire.fdoc"])
        XCTAssertFalse(entries.contains { $0.contains(".tmp") })
        document = renamed
        XCTAssertEqual(try store.load(from: url).stateHash, document.stateHash)
    }

    func testUnsupportedSchemaVersionIsRejected() throws {
        let document = emptyDocument()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try document.encoded()) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try FFDocument.decoded(from: futureData)) { error in
            XCTAssertEqual(error as? FFDocumentError, .unsupportedSchemaVersion(99))
        }
    }

    // MARK: - Payload validation

    func testInvalidCurvePayloadIsRejectedInsteadOfSilentlyLoaded() {
        let badWeights = FFCurveSegment(
            kind: .nurbs,
            controlPoints: [FFPoint2(x: 0, y: 0), FFPoint2(x: 1, y: 0), FFPoint2(x: 2, y: 0)],
            weights: [1, 1],
            degree: 2,
            knots: [0, 0, 0, 1, 1, 1]
        )
        XCTAssertNil(badWeights.curve)
        XCTAssertNil(FFCurvePayload(segments: [badWeights]).path())

        let bezierWithWeights = FFCurveSegment(
            kind: .bezier,
            controlPoints: [FFPoint2(x: 0, y: 0), FFPoint2(x: 1, y: 1)],
            weights: [1, 1]
        )
        XCTAssertNil(bezierWithWeights.curve)
    }

    func testInvalidMeshPayloadIsRejected() {
        let outOfRange = FFMeshPayload(
            positions: [FFPoint3(x: 0, y: 0, z: 0), FFPoint3(x: 1, y: 0, z: 0), FFPoint3(x: 0, y: 1, z: 0)],
            triangles: [FFTriangleIndex(a: 0, b: 1, c: 7)]
        )
        XCTAssertNil(outOfRange.mesh)

        let degenerate = FFMeshPayload(
            positions: [FFPoint3(x: 0, y: 0, z: 0), FFPoint3(x: 1, y: 0, z: 0), FFPoint3(x: 0, y: 1, z: 0)],
            triangles: [FFTriangleIndex(a: 0, b: 1, c: 1)]
        )
        XCTAssertNil(degenerate.mesh)
    }

    // MARK: - Command stack

    func testNoOpEditIsNotRecorded() throws {
        let session = FFDocumentSession(document: emptyDocument())
        let changed = session.perform("Rename") { draft in
            draft.name = draft.name
        }

        XCTAssertFalse(changed)
        XCTAssertEqual(session.appliedChangeCount, 0)
        XCTAssertEqual(session.undoDepth, 0)
        XCTAssertFalse(session.canUndo)
    }

    func testCoalescedEditsCollapseIntoOneUndoStep() throws {
        let session = FFDocumentSession(document: emptyDocument())
        let nodeID = try XCTUnwrap(session.document.rootNodes.first?.id)
        let originalName = session.document.rootNodes[0].name

        for index in 0..<40 {
            session.perform("Rename", coalescingKey: "node-\(nodeID)-name") { draft in
                draft.updateNode(withID: nodeID) { $0.name = "Ring \(index)" }
            }
        }

        XCTAssertEqual(session.appliedChangeCount, 40)
        XCTAssertEqual(session.undoDepth, 1)
        XCTAssertEqual(session.document.rootNodes[0].name, "Ring 39")
        XCTAssertEqual(session.undoName, "Rename")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes[0].name, originalName)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.redoDepth, 1)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.document.rootNodes[0].name, "Ring 39")
    }

    func testEditAfterUndoStartsANewStepInsteadOfMerging() throws {
        let session = FFDocumentSession(document: emptyDocument())
        let nodeID = try XCTUnwrap(session.document.rootNodes.first?.id)

        session.perform("Append A") { draft in
            draft.rootNodes.append(FFNode(name: "A"))
        }
        session.perform("Append B") { draft in
            draft.rootNodes.append(FFNode(name: "B"))
        }
        XCTAssertEqual(session.undoDepth, 2)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.redoDepth, 1)
        XCTAssertEqual(session.document.rootNodes.count, 2)

        session.perform("Rename", coalescingKey: "node-\(nodeID)-name") { draft in
            draft.updateNode(withID: nodeID) { $0.name = "Bench 2" }
        }

        XCTAssertEqual(session.redoDepth, 0)
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(session.undoDepth, 2)
        XCTAssertEqual(session.document.rootNodes.map(\.name), ["Bench 2", "A"])

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes.map(\.name), ["Bench", "A"])
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes.map(\.name), ["Bench"])
    }

    func testHistoryKeepsOnlyTheNewestHundredSteps() throws {
        let fixture = emptyDocument()
        let session = FFDocumentSession(document: fixture)

        for index in 0..<150 {
            session.perform("Append \(index)") { draft in
                draft.rootNodes.append(FFNode(name: "N\(index)"))
            }
        }

        XCTAssertEqual(session.appliedChangeCount, 150)
        XCTAssertEqual(session.undoDepth, 100)
        XCTAssertEqual(session.document.nodeCount, 151)

        var undone = 0
        while session.undo() { undone += 1 }
        XCTAssertEqual(undone, 100)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.document.nodeCount, 51)
        XCTAssertEqual(session.document.rootNodes.first?.name, "Bench")
        XCTAssertEqual(session.document.rootNodes.last?.name, "N49")
    }

    func testHundredRandomEditsUndoAndRedoToTheSameStateHashes() throws {
        let fixture = try curveDocument()
        let session = FFDocumentSession(document: fixture)
        let initialHash = session.document.stateHash
        var generator = LinearCongruential(state: 0x9E37_79B9_7F4A_7C15)
        var attempts = 0

        while session.appliedChangeCount < 100 && attempts < 1_000 {
            attempts += 1
            applyRandomEdit(index: attempts, to: session, using: &generator)
        }

        XCTAssertEqual(session.appliedChangeCount, 100)
        XCTAssertEqual(session.undoDepth, 100)
        let editedHash = session.document.stateHash
        XCTAssertNotEqual(editedHash, initialHash)

        for _ in 0..<100 {
            XCTAssertTrue(session.undo())
        }
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.document.stateHash, initialHash)
        XCTAssertEqual(session.document, fixture)

        for _ in 0..<100 {
            XCTAssertTrue(session.redo())
        }
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(session.document.stateHash, editedHash)
    }

    // MARK: - Random editing

    private func applyRandomEdit(
        index: Int,
        to session: FFDocumentSession,
        using generator: inout LinearCongruential
    ) {
        let choice = Int.random(in: 0..<6, using: &generator)
        let rootID = session.document.rootNodes.first?.id

        switch choice {
        case 0:
            session.perform("Append \(index)") { draft in
                draft.rootNodes.append(FFNode(name: "Node \(index)"))
            }
        case 1:
            guard let rootID else { return }
            session.perform("Rename \(index)", coalescingKey: nil) { draft in
                draft.updateNode(withID: rootID) { $0.name = "Bench \(index)" }
            }
        case 2:
            guard let rootID else { return }
            // No coalescing key: this test needs exactly one undo step per
            // applied edit so the 100-step history is exercised end to end.
            session.perform("Move \(index)", coalescingKey: nil) { draft in
                draft.updateNode(withID: rootID) { node in
                    node.transform.translation.x += Double(index % 7) * 0.25
                }
            }
        case 3:
            guard let rootID else { return }
            session.perform("Visibility \(index)") { draft in
                draft.updateNode(withID: rootID) { $0.isVisible.toggle() }
            }
        case 4:
            session.perform("Material \(index)") { draft in
                draft.materials.append(FFMaterial(name: "Alloy \(index)"))
            }
        default:
            guard let rootID else { return }
            session.perform("Rotate \(index)") { draft in
                draft.updateNode(withID: rootID) { node in
                    node.transform.rotation.z += 0.05
                }
            }
        }
    }
}

/// Deterministic generator so a hundred-edit undo/redo run is reproducible on
/// every machine; `SystemRandomNumberGenerator` would make failures unrepeatable.
private struct LinearCongruential: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
