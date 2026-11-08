import Foundation
import XCTest
@testable import FacetForge

/// Phase 34's acceptance at the model boundary. Duplication is a copy of the
/// subtree, a linear array spaces members along one axis, a 12-item 360° radial
/// array spaces them at exactly 30°, and every parameter stays editable
/// afterwards as one ordinary session step.
final class Phase34ArrayTests: XCTestCase {
    private let fileManager = FileManager.default

    // MARK: - Duplication

    func testDuplicateCopiesTheSubtreeAsOneUndoStep() throws {
        let tip = FFNode(name: "Tip", geometry: .mesh(pyramidMesh()))
        let prong = FFNode(
            name: "Prong",
            transform: FFTransform(
                translation: FFPoint3(x: 12, y: 4, z: -3),
                rotation: FFPoint3(x: 0.1, y: 0.2, z: 0.3),
                scale: FFPoint3(x: 1, y: 1, z: 1)
            ),
            geometry: .mesh(pyramidMesh()),
            children: [tip]
        )
        let session = FFEditorSession(document: FFDocument(rootNodes: [prong]), autosaveInterval: 0)
        session.selection.select([prong.id])
        XCTAssertTrue(session.canDuplicateSelection)

        let beforeHash = session.document.stateHash
        let beforeDepth = session.documentSession.undoDepth
        let copyID = try XCTUnwrap(session.duplicateSelection())

        XCTAssertEqual(session.documentSession.undoDepth, beforeDepth + 1)
        XCTAssertEqual(session.selection.selectedIDs, Set([copyID]), "the copy becomes the selection")
        let copy = try XCTUnwrap(session.document.node(withID: copyID))
        XCTAssertEqual(copy.name, "Prong copy")
        XCTAssertEqual(copy.transform, prong.transform, "a duplicate keeps the source's local matrix")
        XCTAssertNotEqual(copy.id, prong.id)
        XCTAssertEqual(copy.children.map(\.name), ["Tip"])
        XCTAssertNotEqual(copy.children.first?.id, tip.id, "a nested node must also get a new identity")
        XCTAssertEqual(session.document.rootNodes.map(\.id), [prong.id, copyID])

        // A second duplicate of the same source picks a unique name instead of
        // creating two rows with the same accessibility identifier.
        session.selection.select([prong.id])
        let secondID = try XCTUnwrap(session.duplicateSelection())
        XCTAssertEqual(session.document.node(withID: secondID)?.name, "Prong copy 2")

        XCTAssertTrue(session.undo())
        XCTAssertNil(session.document.node(withID: secondID))
        XCTAssertTrue(session.undo())
        XCTAssertNil(session.document.node(withID: copyID))
        XCTAssertEqual(session.document.stateHash, beforeHash, "one undo per duplicate restores the exact document")
    }

    // MARK: - Linear arrays

    func testLinearArraySpacesMembersAtExactOffsetsAndIsOneUndoStep() throws {
        let prong = block(name: "Prong", at: FFPoint3(x: 10, y: 0, z: 0))
        let session = FFEditorSession(document: FFDocument(rootNodes: [prong]), autosaveInterval: 0)
        session.selection.select([prong.id])
        let original = try XCTUnwrap(session.document.node(withID: prong.id))
        let beforeHash = session.document.stateHash
        let beforeDepth = session.documentSession.undoDepth

        let groupID = try XCTUnwrap(
            session.makeLinearArray(count: 5, offset: 8, direction: .x)
        )

        XCTAssertEqual(session.documentSession.undoDepth, beforeDepth + 1)
        XCTAssertEqual(session.selection.selectedIDs, Set([groupID]), "the array group becomes the selection")
        XCTAssertEqual(session.document.rootNodes.map(\.id), [groupID], "the group stands where the node stood")
        let group = try XCTUnwrap(session.document.node(withID: groupID))
        XCTAssertEqual(
            group.array,
            FFArrayParameters.linear(count: 5, offset: 8, direction: .x)
        )
        XCTAssertEqual(group.children.count, 5)
        XCTAssertEqual(group.children.first?.id, prong.id, "member zero is the untouched source")
        XCTAssertEqual(group.children.first?.transform, original.transform)

        for (index, member) in group.children.enumerated() {
            let origin = member.localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0))
            XCTAssertEqual(origin.x, 10 + 8 * Double(index), accuracy: 1e-9)
            XCTAssertEqual(origin.y, 0, accuracy: 1e-9)
            XCTAssertEqual(origin.z, 0, accuracy: 1e-9)
            XCTAssertEqual(member.name, index == 0 ? "Prong" : "Prong \(index + 1)")
        }

        XCTAssertTrue(session.undo())
        XCTAssertNil(session.document.node(withID: groupID))
        XCTAssertEqual(session.document.rootNodes.map(\.id), [prong.id])
        XCTAssertEqual(session.document.stateHash, beforeHash, "one undo restores the pre-array document")
    }

    // MARK: - Radial arrays

    /// The plan row's CI criterion: twelve members over a full 360° sweep are
    /// exactly 30° apart. The check uses the transformed local origin, so it
    /// measures the placement the renderer would draw rather than a parameter.
    func testTwelveItemFullCircleRadialArraySpacesItemsAtThirtyDegrees() throws {
        let prong = block(
            name: "Prong",
            at: FFPoint3(x: 20, y: 0, z: 0),
            rotation: FFPoint3(x: 0, y: 0.3, z: 0)
        )
        let session = FFEditorSession(document: FFDocument(rootNodes: [prong]), autosaveInterval: 0)
        session.selection.select([prong.id])
        let groupID = try XCTUnwrap(
            session.makeRadialArray(count: 12, axis: .y, totalAngle: 360)
        )
        let group = try XCTUnwrap(session.document.node(withID: groupID))
        XCTAssertEqual(group.children.count, 12)
        XCTAssertEqual(group.array?.angularStepDegrees ?? 0, 30, accuracy: 1e-12)
        XCTAssertEqual(
            group.children.first?.id,
            prong.id,
            "member zero keeps the source, including its rotation"
        )

        var angles: [Double] = []
        for member in group.children {
            let origin = member.localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0))
            XCTAssertEqual((origin.x * origin.x + origin.z * origin.z).squareRoot(), 20, accuracy: 1e-9)
            XCTAssertEqual(origin.y, 0, accuracy: 1e-9)
            angles.append(FFMath.degrees(atan2(origin.z, origin.x)))
        }

        for index in 1..<angles.count {
            var delta = angles[index] - angles[index - 1]
            delta = (delta.truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360)
            let gap = min(delta, 360 - delta)
            XCTAssertEqual(
                gap,
                30,
                accuracy: 1e-9,
                "members \(index - 1) and \(index) are \(gap)° apart, not 30°"
            )
        }
    }

    // MARK: - Editable parameters

    func testArrayParametersRemainEditableAfterCreation() throws {
        let prong = block(name: "Prong", at: FFPoint3(x: 20, y: 0, z: 0))
        let session = FFEditorSession(document: FFDocument(rootNodes: [prong]), autosaveInterval: 0)
        session.selection.select([prong.id])
        let groupID = try XCTUnwrap(session.makeRadialArray(count: 12, axis: .y, totalAngle: 360))
        let depthAfterCreation = session.documentSession.undoDepth

        XCTAssertTrue(session.adjustArrayCount(groupID, by: -6))
        XCTAssertEqual(session.documentSession.undoDepth, depthAfterCreation + 1)
        var group = try XCTUnwrap(session.document.node(withID: groupID))
        XCTAssertEqual(group.array?.count, 6)
        XCTAssertEqual(group.children.count, 6)
        XCTAssertEqual(group.array?.angularStepDegrees ?? 0, 60, accuracy: 1e-12)

        // An open arc spans its sweep with count - 1 intervals: six members
        // over 180° are 36° apart, which is a different rule from the closed
        // circle above and proves both branches.
        let depthAfterCount = session.documentSession.undoDepth
        XCTAssertTrue(session.updateArray(groupID) { $0.totalAngle = 180 })
        XCTAssertEqual(session.documentSession.undoDepth, depthAfterCount + 1)
        group = try XCTUnwrap(session.document.node(withID: groupID))
        XCTAssertEqual(group.array?.totalAngle, 180)
        XCTAssertEqual(group.array?.angularStepDegrees ?? 0, 36, accuracy: 1e-12)
        let firstOrigin = try XCTUnwrap(group.children.first)
            .localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0))
        let lastOrigin = try XCTUnwrap(group.children.last)
            .localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0))
        let sweep = abs(
            FFMath.degrees(atan2(lastOrigin.z, lastOrigin.x))
                - FFMath.degrees(atan2(firstOrigin.z, firstOrigin.x))
        )
        XCTAssertEqual(sweep, 180, accuracy: 1e-9, "an open 180° arc must span 180°, not 216°")

        XCTAssertTrue(session.adjustArrayAngle(groupID, by: FFArrayParameters.angleStep))
        XCTAssertEqual(session.document.node(withID: groupID)?.array?.totalAngle, 195)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.node(withID: groupID)?.array?.totalAngle, 180)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.node(withID: groupID)?.array?.totalAngle, 360)
        XCTAssertTrue(session.undo())
        group = try XCTUnwrap(session.document.node(withID: groupID))
        XCTAssertEqual(group.array?.count, 12)
        XCTAssertEqual(group.children.count, 12)

        // The linear kind edits its offset and direction through the same path.
        session.selection.select([prong.id])
        let linearID = try XCTUnwrap(
            session.makeLinearArray(count: 3, offset: 10, direction: .x)
        )
        XCTAssertTrue(session.adjustArrayOffset(linearID, by: 2))
        XCTAssertTrue(session.setArrayDirection(linearID, direction: .z))
        let linear = try XCTUnwrap(session.document.node(withID: linearID))
        XCTAssertEqual(linear.array?.offset, 12)
        XCTAssertEqual(linear.array?.direction, .z)
        let offsets = linear.children.map {
            $0.localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0)).z
        }
        XCTAssertEqual(offsets[1], 12, accuracy: 1e-9)
        XCTAssertEqual(offsets[2], 24, accuracy: 1e-9)
    }

    // MARK: - Persistence and refusals

    func testArraySurvivesSaveReopenAndUntouchedDocumentsKeepTheirEncoding() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let prong = block(name: "Prong", at: FFPoint3(x: 20, y: 0, z: 0))
        let session = FFEditorSession(document: FFDocument(rootNodes: [prong]), autosaveInterval: 0)
        let untouched = try session.document.encoded()
        XCTAssertFalse(
            String(decoding: untouched, as: UTF8.self).contains("\"array\""),
            "a document without an array gained an array key and changed its canonical hash"
        )

        session.selection.select([prong.id])
        let groupID = try XCTUnwrap(session.makeRadialArray(count: 12, axis: .y, totalAngle: 360))
        let before = try XCTUnwrap(session.document.node(withID: groupID))
        let angles = before.children.map {
            FFMath.degrees(
                atan2(
                    $0.localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0)).z,
                    $0.localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0)).x
                )
            )
        }

        let url = directory.appendingPathComponent("Array.ffp")
        try session.save(to: url)
        let reopened = FFEditorSession(autosaveInterval: 0)
        try reopened.reopen(from: url)

        let group = try XCTUnwrap(reopened.document.node(withID: groupID))
        XCTAssertEqual(group.array, before.array)
        XCTAssertEqual(group.children.map(\.id), before.children.map(\.id))
        XCTAssertEqual(group.children.count, 12)
        let reopenedAngles = group.children.map {
            FFMath.degrees(
                atan2(
                    $0.localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0)).z,
                    $0.localMatrix.transformedPoint(Vec3(x: 0, y: 0, z: 0)).x
                )
            )
        }
        for (lhs, rhs) in zip(angles, reopenedAngles) {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-9, "save/reopen moved an array member")
        }
    }

    func testDuplicateAndArrayRefuseLockedLayersAndInvalidParameters() throws {
        let prong = block(name: "Prong", at: FFPoint3(x: 20, y: 0, z: 0))
        let session = FFEditorSession(document: FFDocument(rootNodes: [prong]), autosaveInterval: 0)
        session.selection.select([prong.id])
        let layerID = try XCTUnwrap(session.document.layer(forNodeID: prong.id)?.id)
        session.setLayerLocked(layerID, isLocked: true)
        let hash = session.document.stateHash

        XCTAssertFalse(session.canDuplicateSelection)
        XCTAssertNil(session.duplicateSelection())
        XCTAssertNil(session.makeLinearArray())
        XCTAssertNil(session.makeRadialArray())
        XCTAssertEqual(session.document.stateHash, hash, "a refused command must not touch the document")

        session.setLayerLocked(layerID, isLocked: false)
        let unlockedHash = session.document.stateHash
        XCTAssertNil(
            session.makeLinearArray(count: 1),
            "an array needs at least two members"
        )
        XCTAssertNil(
            session.makeRadialArray(count: 12, totalAngle: 0),
            "a radial array needs a positive sweep"
        )
        XCTAssertNil(
            session.makeRadialArray(count: 12, totalAngle: 400),
            "a radial array may not sweep more than a full circle"
        )
        XCTAssertEqual(session.document.stateHash, unlockedHash)

        let groupID = try XCTUnwrap(session.makeRadialArray(count: 12))
        let depth = session.documentSession.undoDepth
        XCTAssertFalse(session.updateArray(groupID) { $0.count = 1 })
        XCTAssertFalse(session.updateArray(groupID) { $0.totalAngle = -5 })
        XCTAssertEqual(session.documentSession.undoDepth, depth, "invalid edits must not enter history")
    }

    // MARK: - Helpers

    private func block(
        name: String,
        at translation: FFPoint3,
        rotation: FFPoint3 = FFPoint3(x: 0, y: 0, z: 0)
    ) -> FFNode {
        FFNode(
            name: name,
            transform: FFTransform(
                translation: translation,
                rotation: rotation,
                scale: FFPoint3(x: 1, y: 1, z: 1)
            ),
            geometry: .mesh(pyramidMesh())
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase34-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A pyramid over a 10 × 20 base, tall enough to be a real payload without a
    /// factory.
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
}
