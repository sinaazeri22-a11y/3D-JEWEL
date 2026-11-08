import Foundation
import XCTest
@testable import FacetForge

/// Phase 33's acceptance at the model boundary. Grouping preserves every
/// child's world transform, rotating a group moves those children rigidly about
/// the group's pivot, and every pivot or rotation edit is one ordinary session
/// step that undo and the saved bundle both cover.
final class Phase33GroupingTests: XCTestCase {
    private let fileManager = FileManager.default

    // MARK: - Grouping

    func testGroupSelectionPreservesWorldTransformsAndIsOneUndoStep() throws {
        var document = FFDocument.benchSample.document
        let stone = try XCTUnwrap(document.rootNodes.first { $0.kind == .stone })
        let shank = try XCTUnwrap(document.rootNodes.first { $0.name == "Shank" })
        let nested = FFNode(
            name: "Nested",
            transform: FFTransform(
                translation: FFPoint3(x: 2, y: 3, z: 4),
                rotation: FFPoint3(x: 0.2, y: 0.4, z: 0.1),
                scale: FFPoint3(x: 1, y: 1, z: 1)
            ),
            geometry: .mesh(triangleMesh())
        )
        XCTAssertTrue(document.updateNode(withID: stone.id) { $0.children.append(nested) })

        let session = FFEditorSession(document: document, autosaveInterval: 0)
        let beforeHash = session.document.stateHash
        let beforeUndoDepth = session.documentSession.undoDepth
        let stoneBefore = try XCTUnwrap(session.document.worldMatrix(of: stone.id))
        let nestedBefore = try XCTUnwrap(session.document.worldMatrix(of: nested.id))
        let shankBefore = try XCTUnwrap(session.document.worldMatrix(of: shank.id))

        // Selection order is deliberately the reverse of document order.
        session.selection.select([stone.id, shank.id])
        XCTAssertTrue(session.canGroupSelection, "two unlocked sibling roots should be groupable")
        let groupID = try XCTUnwrap(session.groupSelection())

        XCTAssertEqual(session.documentSession.undoDepth, beforeUndoDepth + 1)
        XCTAssertEqual(session.selection.selectedIDs, Set([groupID]), "the new group should start selected")
        let group = try XCTUnwrap(session.document.node(withID: groupID))
        XCTAssertNil(group.geometry)
        XCTAssertEqual(group.children.map(\.id), [shank.id, stone.id], "children must keep document order")
        XCTAssertEqual(group.pivot, FFPoint3(group.localBounds?.center ?? Vec3(x: 0, y: 0, z: 0)))

        assertEqual(try XCTUnwrap(session.document.worldMatrix(of: shank.id)), shankBefore)
        assertEqual(try XCTUnwrap(session.document.worldMatrix(of: stone.id)), stoneBefore)
        assertEqual(try XCTUnwrap(session.document.worldMatrix(of: nested.id)), nestedBefore)
        XCTAssertNotEqual(session.document.stateHash, beforeHash)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.stateHash, beforeHash, "one undo must restore the exact document")
        XCTAssertNil(session.document.node(withID: groupID))
    }

    func testGroupRotationMovesChildrenRigidly() throws {
        let session = FFEditorSession(autosaveInterval: 0)
        let ids = session.document.rootNodes.map(\.id)
        let locals = try ids.map { try XCTUnwrap(session.document.node(withID: $0)?.transform) }
        session.selection.select(ids)
        let groupID = try XCTUnwrap(session.groupSelection())
        let pivot = try XCTUnwrap(session.document.node(withID: groupID)?.effectivePivot.vector)
        let before = try ids.map { try XCTUnwrap(session.document.worldMatrix(of: $0)) }

        session.selection.select([groupID])
        XCTAssertTrue(session.setRotation(groupID, degreesX: 0, degreesY: 30, degreesZ: 0))

        let angle = FFMath.radians(30)
        let aboutPivot = Mat4.translation(pivot)
            * Mat4.rotationY(angle)
            * Mat4.translation(Vec3(x: -pivot.x, y: -pivot.y, z: -pivot.z))
        for (index, id) in ids.enumerated() {
            let after = try XCTUnwrap(session.document.worldMatrix(of: id))
            assertEqual(after, aboutPivot * before[index], "a 30° group turn is a rigid turn about the pivot")
            XCTAssertEqual(
                session.document.node(withID: id)?.transform,
                locals[index],
                "a group rotation must not rewrite a child's local transform"
            )
        }

        // Pairwise distance is the rigid-body invariant that survives even a
        // composition this exact; origins are enough for two siblings.
        let beforeOrigins = before.map { $0.transformedPoint(Vec3(x: 0, y: 0, z: 0)) }
        let afterOrigins = try ids.map {
            try XCTUnwrap(session.document.worldMatrix(of: $0))
                .transformedPoint(Vec3(x: 0, y: 0, z: 0))
        }
        XCTAssertEqual(
            (beforeOrigins[0] - beforeOrigins[1]).length,
            (afterOrigins[0] - afterOrigins[1]).length,
            accuracy: 1e-9,
            "rotating a group changed the distance between its children"
        )
    }

    func testGroupRefusesMixedParentsAncestorsAndLockedLayers() throws {
        var document = FFDocument.benchSample.document
        let shank = try XCTUnwrap(document.rootNodes.first { $0.name == "Shank" })
        let stone = try XCTUnwrap(document.rootNodes.first { $0.kind == .stone })
        let stoneNode = try XCTUnwrap(document.detachNode(stone.id))
        XCTAssertTrue(document.updateNode(withID: shank.id) { $0.children.append(stoneNode) })
        let ancestorSession = FFEditorSession(document: document, autosaveInterval: 0)
        let ancestorHash = ancestorSession.document.stateHash
        ancestorSession.selection.select([shank.id, stone.id])
        XCTAssertFalse(
            ancestorSession.canGroupSelection,
            "a node and its own descendant cannot be grouped together"
        )
        XCTAssertNil(ancestorSession.groupSelection())
        XCTAssertEqual(ancestorSession.document.stateHash, ancestorHash)

        // Two children under different parents: grouping would have to invent a
        // parent, so it is refused rather than silently re-parenting one side.
        var split = FFDocument.benchSample.document
        let splitShank = try XCTUnwrap(split.rootNodes.first { $0.name == "Shank" })
        let splitStone = try XCTUnwrap(split.rootNodes.first { $0.kind == .stone })
        split.rootNodes = [
            FFNode(name: "Holder A", children: [splitShank]),
            FFNode(name: "Holder B", children: [splitStone]),
        ]
        let mixedSession = FFEditorSession(document: split, autosaveInterval: 0)
        let mixedHash = mixedSession.document.stateHash
        mixedSession.selection.select([splitShank.id, splitStone.id])
        XCTAssertFalse(mixedSession.canGroupSelection)
        XCTAssertNil(mixedSession.groupSelection())
        XCTAssertEqual(mixedSession.document.stateHash, mixedHash)

        // A locked layer rejects the edit before anything is detached.
        let lockedSession = FFEditorSession(autosaveInterval: 0)
        let lockedIDs = lockedSession.document.rootNodes.map(\.id)
        let layerID = try XCTUnwrap(lockedSession.document.rootNodes.first?.layerID)
        lockedSession.setLayerLocked(layerID, isLocked: true)
        let lockedHash = lockedSession.document.stateHash
        lockedSession.selection.select(lockedIDs)
        XCTAssertFalse(lockedSession.canGroupSelection)
        XCTAssertNil(lockedSession.groupSelection())
        XCTAssertEqual(lockedSession.document.stateHash, lockedHash)
    }

    func testUngroupRestoresWorldTransformsAndUndoRestoresTheGroup() throws {
        let session = FFEditorSession(autosaveInterval: 0)
        let ids = session.document.rootNodes.map(\.id)
        session.selection.select(ids)
        let groupID = try XCTUnwrap(session.groupSelection())
        XCTAssertTrue(session.setRotation(groupID, degreesX: 10, degreesY: 25, degreesZ: 0))
        let groupWorld = try XCTUnwrap(session.document.worldMatrix(of: groupID))
        let childrenBefore = try ids.map { try XCTUnwrap(session.document.worldMatrix(of: $0)) }
        let beforeUndoDepth = session.documentSession.undoDepth

        session.selection.select([groupID])
        XCTAssertTrue(session.canUngroupSelection())
        XCTAssertTrue(session.ungroupSelection())

        XCTAssertEqual(session.documentSession.undoDepth, beforeUndoDepth + 1)
        XCTAssertNil(session.document.node(withID: groupID))
        XCTAssertEqual(session.document.rootNodes.map(\.id), ids, "children return in document order")
        for (id, expected) in zip(ids, childrenBefore) {
            assertEqual(try XCTUnwrap(session.document.worldMatrix(of: id)), expected, accuracy: 1e-8)
        }

        XCTAssertTrue(session.undo())
        let restored = try XCTUnwrap(session.document.node(withID: groupID))
        XCTAssertEqual(restored.children.map(\.id), ids)
        assertEqual(try XCTUnwrap(session.document.worldMatrix(of: groupID)), groupWorld, accuracy: 1e-8)
        for (id, expected) in zip(ids, childrenBefore) {
            assertEqual(try XCTUnwrap(session.document.worldMatrix(of: id)), expected, accuracy: 1e-8)
        }
    }

    func testUngroupRefusesMeshesAndLockedGroups() throws {
        let session = FFEditorSession(autosaveInterval: 0)
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })
        XCTAssertFalse(session.document.canUngroup(stone.id), "a mesh is not a container")
        session.selection.select([stone.id])
        XCTAssertFalse(session.ungroupSelection())

        let ids = session.document.rootNodes.map(\.id)
        session.selection.select(ids)
        let groupID = try XCTUnwrap(session.groupSelection())
        let layerID = try XCTUnwrap(session.document.node(withID: groupID)?.layerID)
        session.setLayerLocked(layerID, isLocked: true)
        let hash = session.document.stateHash
        session.selection.select([groupID])
        XCTAssertFalse(session.canUngroupSelection())
        XCTAssertFalse(session.ungroupSelection())
        XCTAssertEqual(session.document.stateHash, hash, "a refused ungroup must not move a child")
    }

    func testNestedGroupsPreserveWorldTransformsThroughTwoDissolutions() throws {
        func block(_ name: String, at x: Double) -> FFNode {
            FFNode(
                name: name,
                transform: FFTransform(
                    translation: FFPoint3(x: x, y: 0, z: 0),
                    rotation: FFPoint3(x: 0, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .mesh(pyramidMesh())
            )
        }
        let a = block("A", at: 0)
        let b = block("B", at: 20)
        let c = block("C", at: 40)
        let session = FFEditorSession(document: FFDocument(rootNodes: [a, b, c]), autosaveInterval: 0)

        session.selection.select([a.id, b.id])
        let innerID = try XCTUnwrap(session.groupSelection())
        XCTAssertTrue(session.setRotation(innerID, degreesX: 0, degreesY: 15, degreesZ: 0))
        let before = try [a.id, b.id, c.id].map {
            try XCTUnwrap(session.document.worldMatrix(of: $0))
        }

        session.selection.select([innerID, c.id])
        let outerID = try XCTUnwrap(session.groupSelection())
        let outer = try XCTUnwrap(session.document.node(withID: outerID))
        let inner = try XCTUnwrap(session.document.node(withID: innerID))
        XCTAssertEqual(outer.children.map(\.id), [innerID, c.id])
        XCTAssertEqual(session.document.parentID(of: innerID), outerID)
        XCTAssertEqual(session.document.parentID(of: a.id), innerID)
        for (id, expected) in zip([a.id, b.id, c.id], before) {
            assertEqual(try XCTUnwrap(session.document.worldMatrix(of: id)), expected)
        }

        session.selection.select([a.id])
        let info = try XCTUnwrap(session.transformInfo())
        XCTAssertEqual(info.parentName, inner.name, "the panel must name the immediate container")
        XCTAssertNotNil(inner.pivot, "the inner group's pivot must survive being nested")

        session.selection.select([outerID])
        XCTAssertTrue(session.ungroupSelection())
        XCTAssertEqual(session.selection.selectedIDs, Set([innerID, c.id]))
        for (id, expected) in zip([a.id, b.id, c.id], before) {
            assertEqual(try XCTUnwrap(session.document.worldMatrix(of: id)), expected, accuracy: 1e-8)
        }

        session.selection.select([innerID])
        XCTAssertTrue(session.ungroupSelection())
        XCTAssertEqual(session.document.rootNodes.map(\.id), [a.id, b.id, c.id])
        for (id, expected) in zip([a.id, b.id, c.id], before) {
            assertEqual(try XCTUnwrap(session.document.worldMatrix(of: id)), expected, accuracy: 1e-8)
        }
    }

    // MARK: - Pivots

    func testPivotPresetsReadTheSubtreeBounds() throws {
        var document = FFDocument()
        let block = FFNode(name: "Block", geometry: .mesh(pyramidMesh()))
        var assembly = FFNode(
            name: "Assembly",
            transform: FFTransform(
                translation: FFPoint3(x: 100, y: 0, z: 0),
                rotation: FFPoint3(x: 0, y: 0.3, z: 0),
                scale: FFPoint3(x: 1, y: 1, z: 1)
            ),
            children: [block]
        )
        assembly.pivot = FFPoint3(x: 0, y: 0, z: 0)
        document.rootNodes = [assembly]

        let bounds = try XCTUnwrap(assembly.localBounds)
        XCTAssertEqual(bounds.minimum.x, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.maximum.x, 10, accuracy: 1e-9)
        XCTAssertEqual(bounds.maximum.y, 20, accuracy: 1e-9)
        XCTAssertEqual(bounds.maximum.z, 4, accuracy: 1e-9)
        XCTAssertEqual(FFPivotPreset.centre.point(in: bounds), Vec3(x: 5, y: 10, z: 2))
        XCTAssertEqual(FFPivotPreset.origin.point(in: bounds), Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(FFPivotPreset.x.point(in: bounds), Vec3(x: 5, y: 0, z: 0))
        XCTAssertEqual(FFPivotPreset.y.point(in: bounds), Vec3(x: 0, y: 10, z: 0))
        XCTAssertEqual(FFPivotPreset.z.point(in: bounds), Vec3(x: 0, y: 0, z: 2))

        XCTAssertTrue(document.applyPivotPreset(assembly.id, preset: .centre))
        XCTAssertEqual(document.node(withID: assembly.id)?.pivot, FFPoint3(x: 5, y: 10, z: 2))
        // Origin is stored as no pivot, keeping an untouched file's hash stable.
        XCTAssertTrue(document.applyPivotPreset(assembly.id, preset: .origin))
        XCTAssertNil(document.node(withID: assembly.id)?.pivot)
    }

    func testRotationAboutPivotKeepsThatPointFixedAndReachesTheScene() throws {
        var document = FFDocument()
        let block = FFNode(name: "Block", geometry: .mesh(pyramidMesh()))
        var assembly = FFNode(name: "Assembly", children: [block])
        assembly.pivot = FFPoint3(x: 5, y: 10, z: 2)
        document.rootNodes = [assembly]
        let session = FFEditorSession(document: document, autosaveInterval: 0)
        let pivotWorld = try XCTUnwrap(session.document.worldMatrix(of: assembly.id))
            .transformedPoint(Vec3(x: 5, y: 10, z: 2))

        XCTAssertTrue(session.setRotation(assembly.id, degreesX: 0, degreesY: 90, degreesZ: 0))

        let after = try XCTUnwrap(session.document.worldMatrix(of: assembly.id))
        let pivotAfter = after.transformedPoint(Vec3(x: 5, y: 10, z: 2))
        XCTAssertEqual(pivotAfter.x, pivotWorld.x, accuracy: 1e-9)
        XCTAssertEqual(pivotAfter.y, pivotWorld.y, accuracy: 1e-9)
        XCTAssertEqual(pivotAfter.z, pivotWorld.z, accuracy: 1e-9)

        // The renderer draws the child through the same pivot-aware matrix; a
        // pivot honoured only by the panel would leave this assertion red.
        let rendered = try XCTUnwrap(session.scene.nodes.first { $0.id == block.id })
        assertEqual(rendered.transform, after, accuracy: 1e-9)
    }

    func testPivotEditIsOneUndoStepAndSurvivesSaveAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        // The bench stone is modelled around its own origin, so its bounds
        // centre is already the origin and a Centre preset would be a no-op.
        // An off-centre mesh makes the preset a real edit.
        let stoneNode = FFNode(
            name: "Stone",
            transform: FFTransform(
                translation: FFPoint3(x: 0, y: 40, z: 0),
                rotation: FFPoint3(x: 0, y: 0, z: 0),
                scale: FFPoint3(x: 1, y: 1, z: 1)
            ),
            geometry: .mesh(pyramidMesh())
        )
        let session = FFEditorSession(document: FFDocument(rootNodes: [stoneNode]), autosaveInterval: 0)
        let stone = try XCTUnwrap(session.rootNodes.first)
        let beforeHash = session.document.stateHash
        let beforeUndoDepth = session.documentSession.undoDepth

        XCTAssertTrue(session.setPivot(stone.id, preset: .centre))
        let pivot = try XCTUnwrap(session.document.node(withID: stone.id)?.pivot)
        XCTAssertEqual(session.documentSession.undoDepth, beforeUndoDepth + 1)
        XCTAssertNotEqual(session.document.stateHash, beforeHash)

        let url = directory.appendingPathComponent("Pivot.ffp")
        try session.save(to: url)
        let reopened = FFEditorSession(autosaveInterval: 0)
        try reopened.reopen(from: url)
        XCTAssertEqual(reopened.document.node(withID: stone.id)?.pivot, pivot)

        XCTAssertTrue(session.undo())
        XCTAssertNil(session.document.node(withID: stone.id)?.pivot)
        XCTAssertEqual(session.document.stateHash, beforeHash)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.document.node(withID: stone.id)?.pivot, pivot)
    }

    // MARK: - Inheritance and persistence

    func testTransformInfoReportsInheritanceLocalAndWorldValues() throws {
        let session = FFEditorSession(autosaveInterval: 0)
        let ids = session.document.rootNodes.map(\.id)
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })
        let localTranslation = stone.transform.translation
        session.selection.select(ids)
        let groupID = try XCTUnwrap(session.groupSelection())
        let groupName = try XCTUnwrap(session.document.node(withID: groupID)?.name)

        session.selection.select([stone.id])
        let info = try XCTUnwrap(session.transformInfo())
        XCTAssertEqual(info.parentName, groupName)
        XCTAssertEqual(info.localTranslation, localTranslation)
        XCTAssertEqual(info.worldTranslation, localTranslation, "an identity group adds nothing")

        XCTAssertTrue(session.commitGizmoTransform(
            nodeID: groupID,
            worldTransform: Mat4.translation(Vec3(x: 20, y: -5, z: 7)),
            dragKey: "group-move"
        ))
        let moved = try XCTUnwrap(session.transformInfo())
        XCTAssertEqual(moved.parentName, groupName, "moving the group must not change the nesting")
        XCTAssertEqual(moved.localTranslation, localTranslation, "the child's local value is unchanged")
        XCTAssertEqual(moved.worldTranslation.x, localTranslation.x + 20, accuracy: 1e-9)
        XCTAssertEqual(moved.worldTranslation.y, localTranslation.y - 5, accuracy: 1e-9)
        XCTAssertEqual(moved.worldTranslation.z, localTranslation.z + 7, accuracy: 1e-9)

        session.selection.select([groupID])
        let groupInfo = try XCTUnwrap(session.transformInfo())
        XCTAssertNil(groupInfo.parentName)
        XCTAssertTrue(groupInfo.canUngroup)
    }

    func testGroupAndPivotSurviveSaveAndUntouchedDocumentsKeepTheirEncoding() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let blockA = FFNode(name: "Block A", geometry: .mesh(pyramidMesh()))
        let blockB = FFNode(
            name: "Block B",
            transform: FFTransform(
                translation: FFPoint3(x: 20, y: 0, z: 0),
                rotation: FFPoint3(x: 0, y: 0, z: 0),
                scale: FFPoint3(x: 1, y: 1, z: 1)
            ),
            geometry: .mesh(pyramidMesh())
        )
        let session = FFEditorSession(
            document: FFDocument(rootNodes: [blockA, blockB]),
            autosaveInterval: 0
        )
        let untouched = try session.document.encoded()
        XCTAssertFalse(
            String(decoding: untouched, as: UTF8.self).contains("\"pivot\""),
            "a document without a pivot gained a pivot key and changed its canonical hash"
        )

        let ids = session.document.rootNodes.map(\.id)
        session.selection.select(ids)
        let groupID = try XCTUnwrap(session.groupSelection())
        XCTAssertTrue(session.setPivot(groupID, preset: .x))
        let pivot = try XCTUnwrap(session.document.node(withID: groupID)?.pivot)
        let bounds = try XCTUnwrap(session.document.node(withID: groupID)?.localBounds)
        XCTAssertEqual(pivot.x, bounds.center.x, accuracy: 1e-9)
        XCTAssertEqual(pivot.y, 0, accuracy: 1e-9)
        XCTAssertEqual(pivot.z, 0, accuracy: 1e-9)

        let url = directory.appendingPathComponent("Group.ffp")
        try session.save(to: url)
        let reopened = FFEditorSession(autosaveInterval: 0)
        try reopened.reopen(from: url)

        let group = try XCTUnwrap(reopened.document.node(withID: groupID))
        XCTAssertNil(group.geometry)
        XCTAssertEqual(group.children.map(\.id), ids)
        XCTAssertEqual(group.pivot, pivot)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase33-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Two triangles, enough for a real payload without needing a factory.
    private func triangleMesh() -> FFMeshPayload {
        FFMeshPayload(
            positions: [
                FFPoint3(x: 0, y: 0, z: 0),
                FFPoint3(x: 1, y: 0, z: 0),
                FFPoint3(x: 0, y: 1, z: 0),
            ],
            triangles: [FFTriangleIndex(a: 0, b: 1, c: 2)]
        )
    }

    /// A pyramid over a 10 × 20 base with its apex 4 mm up, so the subtree
    /// bounds have a distinct centre on every axis.
    private func pyramidMesh() -> FFMeshPayload {
        FFMeshPayload(
            positions: [
                FFPoint3(x: 0, y: 0, z: 0),
                FFPoint3(x: 10, y: 0, z: 0),
                FFPoint3(x: 10, y: 20, z: 0),
                FFPoint3(x: 0, y: 20, z: 0),
                FFPoint3(x: 5, y: 10, z: 4),
            ],
            triangles: [
                FFTriangleIndex(a: 0, b: 1, c: 2),
                FFTriangleIndex(a: 0, b: 2, c: 3),
                FFTriangleIndex(a: 0, b: 1, c: 4),
                FFTriangleIndex(a: 1, b: 2, c: 4),
                FFTriangleIndex(a: 2, b: 3, c: 4),
                FFTriangleIndex(a: 3, b: 0, c: 4),
            ]
        )
    }

    private func components(of matrix: Mat4) -> [Double] {
        [
            matrix.m00, matrix.m01, matrix.m02, matrix.m03,
            matrix.m10, matrix.m11, matrix.m12, matrix.m13,
            matrix.m20, matrix.m21, matrix.m22, matrix.m23,
            matrix.m30, matrix.m31, matrix.m32, matrix.m33,
        ]
    }

    private func assertEqual(
        _ actual: Mat4,
        _ expected: Mat4,
        accuracy: Double = 1e-9,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lhs = components(of: actual)
        let rhs = components(of: expected)
        for index in lhs.indices {
            XCTAssertEqual(
                lhs[index],
                rhs[index],
                accuracy: accuracy,
                "matrix component \(index) differs. \(message)",
                file: file,
                line: line
            )
        }
    }
}
