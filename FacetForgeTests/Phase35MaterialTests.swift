import Foundation
import XCTest
@testable import FacetForge

/// Phase 35's acceptance at the document boundary. A material assigned to a
/// subset of a mesh's faces is saved and reopened with the same triangle set,
/// an alloy preset rewrites every face that references the material, and the
/// OBJ writer emits the same material-to-face assignment for another reader.
final class Phase35MaterialTests: XCTestCase {
    private let fileManager = FileManager.default

    // MARK: - Face subset persistence

    func testAssigningAFaceSubsetPersistsThroughSaveAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let gold = goldMaterial()
        let rose = roseMaterial()
        let node = FFNode(
            name: "Shank",
            geometry: .mesh(quadMesh()),
            materialID: gold.id
        )
        let session = FFEditorSession(
            document: FFDocument(materials: [gold, rose], rootNodes: [node]),
            autosaveInterval: 0
        )
        XCTAssertFalse(
            String(decoding: try session.document.encoded(), as: UTF8.self)
                .contains("\"faceGroups\""),
            "a document without face groups gained the Phase 35 key"
        )

        session.selection.select([node.id])
        let beforeDepth = session.documentSession.undoDepth
        let groupID = try XCTUnwrap(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Lower faces",
                materialID: rose.id,
                triangles: [0, 1]
            )
        )
        XCTAssertEqual(session.documentSession.undoDepth, beforeDepth + 1)

        let savedNode = try XCTUnwrap(session.document.node(withID: node.id))
        XCTAssertEqual(savedNode.faceGroups?.count, 1)
        XCTAssertEqual(savedNode.faceGroups?.first?.id, groupID)
        XCTAssertEqual(savedNode.faceGroups?.first?.triangles, [0, 1])
        XCTAssertEqual(savedNode.faceGroups?.first?.materialID, rose.id)
        XCTAssertEqual(savedNode.materialID, gold.id, "the base material must be untouched")

        let encoded = String(decoding: try session.document.encoded(), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"faceGroups\""))
        XCTAssertTrue(encoded.contains("\"triangles\":[0,1]"))

        let scene = try XCTUnwrap(session.scene.nodes.first)
        XCTAssertEqual(scene.parts.count, 2, "two materials must draw as two parts")
        let rosePart = try XCTUnwrap(
            scene.parts.first(where: { $0.material.baseColor == rose.baseColor })
        )
        XCTAssertEqual(rosePart.triangleCount, 2)
        XCTAssertEqual(rosePart.mesh.triangleCount, 2)
        let goldPart = try XCTUnwrap(
            scene.parts.first(where: { $0.material.baseColor == gold.baseColor })
        )
        XCTAssertEqual(goldPart.triangleCount, 2, "unassigned faces keep the base material")

        let url = directory.appendingPathComponent("Materials.ffp")
        try session.save(to: url)
        let reopened = FFEditorSession(autosaveInterval: 0)
        try reopened.reopen(from: url)

        let reopenedNode = try XCTUnwrap(reopened.document.node(withID: node.id))
        XCTAssertEqual(reopenedNode.faceGroups, savedNode.faceGroups)
        XCTAssertEqual(reopenedNode.materialID, gold.id)
        let reopenedPart = try XCTUnwrap(
            reopened.scene.nodes.first?.parts.first(
                where: { $0.material.baseColor == rose.baseColor }
            )
        )
        XCTAssertEqual(reopenedPart.triangleCount, 2)
    }

    func testReassigningASubsetMovesFacesBetweenGroups() throws {
        let gold = goldMaterial()
        let rose = roseMaterial()
        let platinum = platinumMaterial()
        let node = FFNode(
            name: "Shank",
            geometry: .mesh(quadMesh()),
            materialID: gold.id
        )
        let session = FFEditorSession(
            document: FFDocument(materials: [gold, rose, platinum], rootNodes: [node]),
            autosaveInterval: 0
        )
        session.selection.select([node.id])

        XCTAssertNotNil(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "All faces",
                materialID: gold.id,
                triangles: [0, 1, 2, 3]
            )
        )
        let splitID = try XCTUnwrap(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Lower faces",
                materialID: rose.id,
                triangles: [0, 1]
            )
        )
        var groups = try XCTUnwrap(session.document.node(withID: node.id)?.faceGroups)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "All faces")
        XCTAssertEqual(groups[0].triangles, [2, 3], "assigned faces must leave the old group")
        XCTAssertEqual(groups[1].id, splitID)
        XCTAssertEqual(groups[1].triangles, [0, 1])

        let depthAfterSplit = session.documentSession.undoDepth
        XCTAssertNotNil(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Top faces",
                materialID: platinum.id,
                triangles: [0, 1]
            )
        )
        XCTAssertEqual(
            session.documentSession.undoDepth,
            depthAfterSplit + 1,
            "reassigning an identical subset is one edit"
        )
        groups = try XCTUnwrap(session.document.node(withID: node.id)?.faceGroups)
        XCTAssertEqual(groups.count, 2, "an identical triangle set must update its group, not duplicate it")
        XCTAssertEqual(groups[1].id, splitID)
        XCTAssertEqual(groups[1].name, "Top faces")
        XCTAssertEqual(groups[1].materialID, platinum.id)

        XCTAssertTrue(session.undo())
        groups = try XCTUnwrap(session.document.node(withID: node.id)?.faceGroups)
        XCTAssertEqual(groups[1].name, "Lower faces")
        XCTAssertEqual(groups[1].materialID, rose.id)
        XCTAssertTrue(session.undo())
        groups = try XCTUnwrap(session.document.node(withID: node.id)?.faceGroups)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].triangles, [0, 1, 2, 3])
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.document.node(withID: node.id)?.faceGroups?.count, 2)
    }

    // MARK: - Alloy presets

    /// The row's second criterion: a preset edit reaches every linked face. The
    /// node's base material and two named groups all reference gold, and the
    /// projection merges them into one three-triangle part; the fourth face
    /// belongs to rose and must not move.
    func testChangingAPresetUpdatesEveryLinkedFaceAndLeavesOtherMaterialsAlone() throws {
        let gold = goldMaterial()
        let rose = roseMaterial()
        let node = FFNode(
            name: "Shank",
            geometry: .mesh(quadMesh()),
            materialID: gold.id
        )
        let session = FFEditorSession(
            document: FFDocument(materials: [gold, rose], rootNodes: [node]),
            autosaveInterval: 0
        )
        session.selection.select([node.id])

        XCTAssertNotNil(
            session.assignFaceGroup(nodeID: node.id, name: "Face 0", materialID: gold.id, triangles: [0])
        )
        XCTAssertNotNil(
            session.assignFaceGroup(nodeID: node.id, name: "Face 1", materialID: gold.id, triangles: [1])
        )
        XCTAssertNotNil(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Rose face",
                materialID: rose.id,
                triangles: [2]
            )
        )

        var parts = try XCTUnwrap(session.scene.nodes.first?.parts)
        let goldPart = try XCTUnwrap(parts.first(where: { $0.material.baseColor == gold.baseColor }))
        let rosePart = try XCTUnwrap(parts.first(where: { $0.material.baseColor == rose.baseColor }))
        XCTAssertEqual(goldPart.triangleCount, 3)
        XCTAssertEqual(rosePart.triangleCount, 1)

        let depth = session.documentSession.undoDepth
        XCTAssertTrue(session.setMaterialPreset(gold.id, preset: .platinum950))
        XCTAssertEqual(session.documentSession.undoDepth, depth + 1)

        let preset = FFAlloyPreset.platinum950
        let updated = try XCTUnwrap(session.document.material(withID: gold.id))
        XCTAssertEqual(updated.preset, preset)
        XCTAssertEqual(updated.baseColor, preset.baseColor)
        XCTAssertEqual(updated.metallic, preset.metallic)
        XCTAssertEqual(updated.roughness, preset.roughness)

        parts = try XCTUnwrap(session.scene.nodes.first?.parts)
        let changedPart = try XCTUnwrap(
            parts.first(where: { $0.material.baseColor == preset.baseColor })
        )
        XCTAssertEqual(changedPart.triangleCount, 3, "every face linked to gold changed")
        let unchangedRose = try XCTUnwrap(
            parts.first(where: { $0.material.baseColor == rose.baseColor })
        )
        XCTAssertEqual(unchangedRose.triangleCount, 1)
        XCTAssertEqual(unchangedRose.material.roughness, rose.roughness)

        let info = session.materialInfo()
        XCTAssertEqual(
            info.materials.first(where: { $0.id == gold.id })?.faceCount,
            3,
            "the inspector must count base and grouped faces once each"
        )
        XCTAssertEqual(
            info.materials.first(where: { $0.id == rose.id })?.faceCount,
            1
        )

        XCTAssertTrue(session.undo())
        let restored = try XCTUnwrap(session.document.material(withID: gold.id))
        XCTAssertNil(restored.preset)
        XCTAssertEqual(restored.baseColor, gold.baseColor)
        parts = try XCTUnwrap(session.scene.nodes.first?.parts)
        XCTAssertEqual(parts.first(where: { $0.material.baseColor == gold.baseColor })?.triangleCount, 3)
    }

    func testAlloyPresetsRoundTripAndDirectEditsClearThePreset() throws {
        var document = FFDocument(
            materials: [goldMaterial()],
            rootNodes: []
        )
        let materialID = try XCTUnwrap(document.materials.first?.id)
        for preset in FFAlloyPreset.allCases {
            XCTAssertTrue(document.setMaterialPreset(materialID, preset: preset))
            let material = try XCTUnwrap(document.material(withID: materialID))
            XCTAssertEqual(material.preset, preset)
            XCTAssertEqual(material.baseColor, preset.baseColor)
            XCTAssertEqual(material.metallic, preset.metallic)
            XCTAssertEqual(material.roughness, preset.roughness)
        }

        let encoded = try document.encoded()
        let decoded = try FFDocument.decoded(from: encoded)
        XCTAssertEqual(
            decoded.material(withID: materialID)?.preset,
            FFAlloyPreset.allCases.last
        )

        XCTAssertTrue(
            document.setMaterialParameters(materialID, metallic: 0.5, roughness: 0.6)
        )
        let custom = try XCTUnwrap(document.material(withID: materialID))
        XCTAssertNil(custom.preset, "a hand-adjusted surface is custom, not the named alloy")
        XCTAssertEqual(custom.metallic, 0.5)
        XCTAssertEqual(custom.roughness, 0.6)
        XCTAssertEqual(custom.baseColor, FFAlloyPreset.sterlingSilver.baseColor)

        XCTAssertTrue(document.setMaterialPreset(materialID, preset: .whiteGold18K))
        XCTAssertEqual(document.material(withID: materialID)?.preset, .whiteGold18K)
        XCTAssertEqual(
            document.material(withID: materialID)?.roughness,
            FFAlloyPreset.whiteGold18K.roughness
        )
    }

    // MARK: - OBJ interchange

    func testOBJExportCarriesPerFaceGroupMaterialsThroughReopen() throws {
        let gold = goldMaterial()
        let rose = roseMaterial()
        let node = FFNode(
            name: "Shank",
            geometry: .mesh(quadMesh()),
            materialID: gold.id
        )
        var document = FFDocument(materials: [gold, rose], rootNodes: [node])
        XCTAssertNotNil(
            document.assignFaceGroup(
                nodeID: node.id,
                name: "Lower faces",
                materialID: rose.id,
                triangles: [0, 1]
            )
        )

        let obj = FFOBJExporter.obj(for: document)
        let mtl = FFOBJExporter.mtl(for: document)
        XCTAssertEqual(
            obj.components(separatedBy: "usemtl ").count - 1,
            2,
            "each material must start its own usemtl section"
        )
        XCTAssertTrue(obj.contains("usemtl Gold"))
        XCTAssertTrue(obj.contains("usemtl Rose Gold"))
        XCTAssertEqual(
            obj.split(separator: "\n").filter { $0.hasPrefix("f ") }.count,
            4,
            "splitting by material must not drop or duplicate a face"
        )
        XCTAssertTrue(mtl.contains("newmtl Gold"))
        XCTAssertTrue(mtl.contains("newmtl Rose Gold"))

        let asset = try FFOBJImporter.parse(obj, materialLibrary: mtl)
        XCTAssertEqual(asset.groups.map(\.name), ["Shank"])
        let submeshes = asset.groups.flatMap(\.submeshes)
        XCTAssertEqual(submeshes.count, 2)
        XCTAssertEqual(
            submeshes.reduce(0) { $0 + $1.mesh.triangleCount },
            4
        )
        XCTAssertEqual(Set(submeshes.compactMap(\.material)), ["Gold", "Rose Gold"])

        let built = FFOBJDocumentBuilder.build(asset, layerID: document.currentLayerID)
        let materialNames = Dictionary(
            uniqueKeysWithValues: built.materials.map { ($0.id, $0.name) }
        )
        var facesByMaterial: [String: Int] = [:]
        for root in built.nodes {
            for imported in root.flattenedNodes() {
                guard imported.geometry?.mesh != nil,
                      let materialID = imported.materialID,
                      let name = materialNames[materialID]
                else { continue }
                facesByMaterial[name, default: 0] += imported.meshTriangleCount
            }
        }
        XCTAssertEqual(facesByMaterial["Gold"], 2)
        XCTAssertEqual(facesByMaterial["Rose Gold"], 2)
    }

    // MARK: - Refusals and projection

    func testMaterialCommandsRefuseLockedLayersAndInvalidInput() throws {
        let gold = goldMaterial()
        let rose = roseMaterial()
        let node = FFNode(
            name: "Shank",
            geometry: .mesh(quadMesh()),
            materialID: gold.id
        )
        let session = FFEditorSession(
            document: FFDocument(materials: [gold, rose], rootNodes: [node]),
            autosaveInterval: 0
        )
        session.selection.select([node.id])
        let layerID = try XCTUnwrap(session.document.layer(forNodeID: node.id)?.id)

        session.setLayerLocked(layerID, isLocked: true)
        let lockedHash = session.document.stateHash
        XCTAssertNil(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Locked",
                materialID: rose.id,
                triangles: [0]
            )
        )
        XCTAssertFalse(session.assignMaterialToNode(node.id, materialID: rose.id))
        XCTAssertFalse(session.removeFaceGroup(nodeID: node.id, groupID: UUID()))
        XCTAssertEqual(session.document.stateHash, lockedHash)

        session.setLayerLocked(layerID, isLocked: false)
        session.selection.select([node.id])
        let unlockedHash = session.document.stateHash
        XCTAssertNil(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Empty",
                materialID: rose.id,
                triangles: []
            )
        )
        XCTAssertNil(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Out of range",
                materialID: rose.id,
                triangles: [99]
            )
        )
        XCTAssertNil(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Missing material",
                materialID: UUID(),
                triangles: [0]
            )
        )
        XCTAssertFalse(session.assignMaterialToNode(node.id, materialID: UUID()))
        XCTAssertEqual(session.document.stateHash, unlockedHash)

        let groupID = try XCTUnwrap(
            session.assignFaceGroup(
                nodeID: node.id,
                name: "Only group",
                materialID: rose.id,
                triangles: [0]
            )
        )
        XCTAssertTrue(session.removeFaceGroup(nodeID: node.id, groupID: groupID))
        XCTAssertNil(
            session.document.node(withID: node.id)?.faceGroups,
            "removing the last group must restore the pre-Phase-35 encoding"
        )
        XCTAssertFalse(
            String(decoding: try session.document.encoded(), as: UTF8.self)
                .contains("\"faceGroups\"")
        )
    }

    func testMaterialInfoCountsUsageGroupsAndUnassignedFaces() throws {
        let gold = goldMaterial()
        let rose = roseMaterial()
        let gem = gemMaterial()
        let node = FFNode(
            name: "Shank",
            geometry: .mesh(quadMesh()),
            materialID: gold.id
        )
        var document = FFDocument(
            materials: [gold, rose, gem],
            rootNodes: [node]
        )
        XCTAssertNotNil(
            document.assignFaceGroup(
                nodeID: node.id,
                name: "Lower",
                materialID: rose.id,
                triangles: [0]
            )
        )
        XCTAssertNotNil(
            document.assignFaceGroup(
                nodeID: node.id,
                name: "Middle",
                materialID: rose.id,
                triangles: [1, 2]
            )
        )

        let info = document.materialInfo(for: node.id, isLocked: false)
        XCTAssertEqual(info.materials.count, 3)
        XCTAssertEqual(info.materials.first(where: { $0.id == gold.id })?.faceCount, 1)
        XCTAssertEqual(info.materials.first(where: { $0.id == gold.id })?.nodeCount, 1)
        XCTAssertEqual(info.materials.first(where: { $0.id == rose.id })?.faceCount, 3)
        XCTAssertEqual(info.materials.first(where: { $0.id == rose.id })?.nodeCount, 1)
        XCTAssertEqual(info.materials.first(where: { $0.id == gem.id })?.faceCount, 0)
        XCTAssertEqual(info.selectedNodeID, node.id)
        XCTAssertEqual(info.selectedNodeMaterialID, gold.id)
        XCTAssertEqual(info.selectedNodeTriangleCount, 4)
        XCTAssertEqual(info.faceGroups.count, 2)
        XCTAssertEqual(info.faceGroups.map(\.materialName), ["Rose Gold", "Rose Gold"])
        XCTAssertEqual(info.unassignedTriangleCount, 1)
        XCTAssertTrue(info.canEditSelection)

        XCTAssertFalse(
            document.materialInfo(for: node.id, isLocked: true).canEditSelection
        )
        let noSelection = document.materialInfo(for: nil, isLocked: false)
        XCTAssertNil(noSelection.selectedNodeID)
        XCTAssertEqual(noSelection.materials.first(where: { $0.id == rose.id })?.faceCount, 3)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase35-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func goldMaterial() -> FFMaterial {
        FFMaterial(
            name: "Gold",
            baseColor: .gold,
            metallic: 1,
            roughness: 0.24
        )
    }

    private func roseMaterial() -> FFMaterial {
        FFMaterial(
            name: "Rose Gold",
            baseColor: FFRGBA(red: 0.92, green: 0.55, blue: 0.40),
            metallic: 1,
            roughness: 0.20
        )
    }

    private func platinumMaterial() -> FFMaterial {
        FFMaterial(
            name: "Platinum",
            baseColor: FFRGBA(red: 0.75, green: 0.78, blue: 0.80),
            metallic: 1,
            roughness: 0.22
        )
    }

    private func gemMaterial() -> FFMaterial {
        FFMaterial(
            name: "Gem",
            baseColor: FFRGBA(red: 0.52, green: 0.84, blue: 0.96),
            metallic: 0.05,
            roughness: 0.08
        )
    }

    /// Two detached quads: four non-degenerate triangles, enough to split a
    /// subset in more than one way without sharing vertices across the cut.
    private func quadMesh() -> FFMeshPayload {
        FFMeshPayload(
            positions: [
                FFPoint3(x: 0, y: 0, z: 0),
                FFPoint3(x: 1, y: 0, z: 0),
                FFPoint3(x: 1, y: 1, z: 0),
                FFPoint3(x: 0, y: 1, z: 0),
                FFPoint3(x: 10, y: 0, z: 0),
                FFPoint3(x: 11, y: 0, z: 0),
                FFPoint3(x: 11, y: 1, z: 0),
                FFPoint3(x: 10, y: 1, z: 0),
            ],
            triangles: [
                FFTriangleIndex(a: 0, b: 1, c: 2),
                FFTriangleIndex(a: 0, b: 2, c: 3),
                FFTriangleIndex(a: 4, b: 5, c: 6),
                FFTriangleIndex(a: 4, b: 6, c: 7),
            ]
        )
    }
}
