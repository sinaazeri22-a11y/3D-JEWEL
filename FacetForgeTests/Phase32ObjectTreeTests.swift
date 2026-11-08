import XCTest
@testable import FacetForge

/// Phase 32's acceptance at the model boundary. The tree flattens document
/// order with types and depth, search matches a name or a type, and every
/// rename, nest and reorder is one ordinary session edit that undo can reverse.
final class Phase32ObjectTreeTests: XCTestCase {
    // MARK: - Flattening and types

    func testTreeFlattensTypesAndDepthInDocumentOrder() throws {
        var document = FFDocument.benchSample.document
        let stone = try XCTUnwrap(document.rootNodes.first { $0.kind == .stone })
        document.rootNodes.removeAll { $0.id == stone.id }
        document.rootNodes.append(FFNode(name: "Setting", children: [stone]))

        let rows = FFObjectTree.rows(in: document)
        XCTAssertEqual(rows.map(\.name), ["Shank", "Setting", "Stone"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1])
        XCTAssertEqual(rows.map(\.kind), [.solid, .group, .stone])
        XCTAssertEqual(rows[1].childCount, 1)

        let curve = FFNode(name: "Profile", geometry: .curve(FFCurvePayload(segments: [])))
        document.rootNodes.append(curve)
        XCTAssertEqual(FFObjectTree.rows(in: document).last?.kind, .curve)
        XCTAssertEqual(FFObjectKind.classify(FFNode(name: "Empty")), .group)
    }

    // MARK: - Search

    func testSearchFindsByNameAndTypeAndKeepsAncestors() {
        var document = FFDocument.benchSample.document
        let stone = document.rootNodes.first { $0.kind == .stone }!
        document.rootNodes.removeAll { $0.id == stone.id }
        document.rootNodes.append(FFNode(name: "Setting", children: [stone]))

        XCTAssertEqual(
            FFObjectTree.rows(in: document, query: "stone").map(\.name),
            ["Setting", "Stone"],
            "a name match must keep the ancestor that leads to it"
        )
        XCTAssertEqual(
            FFObjectTree.rows(in: document, query: "  sToNe  ").map(\.name),
            ["Setting", "Stone"],
            "search is trimmed and case-insensitive"
        )
        XCTAssertEqual(
            FFObjectTree.rows(in: document, query: "GROUP").map(\.name),
            ["Setting", "Stone"],
            "a group match keeps its descendants"
        )
        XCTAssertEqual(
            FFObjectTree.rows(in: document, query: "solid").map(\.name),
            ["Shank"],
            "a type search must not match the stone"
        )
        XCTAssertEqual(FFObjectTree.rows(in: document, query: "nothing"), [])
        XCTAssertEqual(FFObjectTree.rows(in: document, query: "").count, 3)
    }

    // MARK: - Rename

    func testRenameCommitsOneUndoStepAndUpdatesTheTree() throws {
        let session = FFEditorSession()
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })
        let before = session.document.stateHash

        XCTAssertTrue(session.renameNode(stone.id, to: "  Center Stone  "))
        XCTAssertEqual(session.document.node(withID: stone.id)?.name, "Center Stone")
        XCTAssertEqual(
            FFObjectTree.rows(in: session.document).first { $0.id == stone.id }?.name,
            "Center Stone"
        )
        XCTAssertNotEqual(session.document.stateHash, before)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.node(withID: stone.id)?.name, "Stone")
    }

    func testRenameRejectsBlankUnchangedAndLockedNodes() throws {
        let session = FFEditorSession()
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })
        XCTAssertFalse(session.renameNode(stone.id, to: "   "))
        XCTAssertFalse(session.renameNode(stone.id, to: "Stone"))
        XCTAssertFalse(session.documentSession.canUndo)

        let stonesLayer = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        XCTAssertTrue(session.setLayerLocked(stonesLayer.id, isLocked: true))
        XCTAssertFalse(session.renameNode(stone.id, to: "Locked Stone"))
        XCTAssertEqual(session.document.node(withID: stone.id)?.name, "Stone")
    }

    // MARK: - Nested groups and order

    func testNestingMovesASolidIntoAGroupAndOneUndoRestoresIt() throws {
        let session = FFEditorSession()
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })
        let groupID = try XCTUnwrap(session.addObjectGroup())

        XCTAssertTrue(session.moveNode(stone.id, into: groupID))
        let rows = FFObjectTree.rows(in: session.document)
        let groupRow = try XCTUnwrap(rows.first { $0.id == groupID })
        let stoneRow = try XCTUnwrap(rows.first { $0.id == stone.id })
        XCTAssertEqual(groupRow.kind, .group)
        XCTAssertEqual(groupRow.childCount, 1)
        XCTAssertEqual(stoneRow.depth, 1)
        XCTAssertEqual(session.document.location(of: stone.id)?.parent, groupID)

        XCTAssertTrue(session.undo())
        XCTAssertNil(session.document.location(of: stone.id)?.parent)
        XCTAssertEqual(session.document.location(of: groupID)?.parent, nil)
    }

    func testNestingRejectsCyclesSelfAndLockedLayers() throws {
        let session = FFEditorSession()
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })
        let first = try XCTUnwrap(session.addObjectGroup())
        let second = try XCTUnwrap(session.addObjectGroup())

        XCTAssertTrue(session.moveNode(second, into: first))
        XCTAssertFalse(session.moveNode(first, into: second), "a group cannot enter its own child")
        XCTAssertNil(session.document.location(of: first)?.parent)

        XCTAssertFalse(session.moveNode(first, into: first), "a node cannot be its own parent")

        let stonesLayer = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        XCTAssertTrue(session.setLayerLocked(stonesLayer.id, isLocked: true))
        XCTAssertFalse(session.moveNode(stone.id, into: first), "a locked node must not move")
    }

    func testReorderMovesWithinSiblingsAndStopsAtTheEdges() throws {
        let session = FFEditorSession()
        let shank = try XCTUnwrap(session.rootNodes.first { $0.kind == .solid })
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })
        let groupID = try XCTUnwrap(session.addObjectGroup())

        XCTAssertTrue(session.moveNode(shank.id, into: groupID))
        XCTAssertTrue(session.moveNode(stone.id, into: groupID))
        XCTAssertEqual(children(of: groupID, in: session), [shank.id, stone.id])

        XCTAssertTrue(session.moveNode(shank.id, by: 1))
        XCTAssertEqual(children(of: groupID, in: session), [stone.id, shank.id])
        XCTAssertTrue(session.moveNode(shank.id, by: -1))
        XCTAssertEqual(children(of: groupID, in: session), [shank.id, stone.id])

        XCTAssertFalse(session.moveNode(shank.id, by: -1), "the first child cannot move up")
        XCTAssertFalse(session.moveNode(stone.id, by: 1), "the last child cannot move down")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(children(of: groupID, in: session), [stone.id, shank.id])
        XCTAssertTrue(session.undo())
        XCTAssertEqual(children(of: groupID, in: session), [shank.id, stone.id])
    }

    func testGroupCreationNamesAreUniqueAndUndoable() throws {
        let session = FFEditorSession()
        let first = try XCTUnwrap(session.addObjectGroup())
        let second = try XCTUnwrap(session.addObjectGroup())
        XCTAssertEqual(session.document.node(withID: first)?.name, "Group 1")
        XCTAssertEqual(session.document.node(withID: second)?.name, "Group 2")
        XCTAssertEqual(
            FFObjectTree.rows(in: session.document).filter { $0.kind == .group }.count,
            2
        )

        XCTAssertTrue(session.undo())
        XCTAssertNil(session.document.node(withID: second))
        XCTAssertNotNil(session.document.node(withID: first))
    }

    // MARK: - Selection and persistence

    func testTreeSelectionSyncsWithMultiSelect() throws {
        let session = FFEditorSession()
        let shank = try XCTUnwrap(session.rootNodes.first { $0.kind == .solid })
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })

        XCTAssertTrue(session.selectNodeFromTree(stone.id))
        XCTAssertEqual(session.selection.selectedIDs, Set([stone.id]))

        session.selection.isMultiSelect = true
        XCTAssertTrue(session.selectNodeFromTree(shank.id))
        XCTAssertEqual(session.selection.selectedIDs, Set([stone.id, shank.id]))
        XCTAssertTrue(session.selectNodeFromTree(shank.id))
        XCTAssertEqual(session.selection.selectedIDs, Set([stone.id]))
        XCTAssertFalse(session.selectNodeFromTree(UUID()))
    }

    func testNestedTreeOrderSurvivesSaveAndReopen() throws {
        let session = FFEditorSession()
        let shank = try XCTUnwrap(session.rootNodes.first { $0.kind == .solid })
        let stone = try XCTUnwrap(session.rootNodes.first { $0.kind == .stone })
        let groupID = try XCTUnwrap(session.addObjectGroup(named: "Assembly"))
        XCTAssertTrue(session.moveNode(shank.id, into: groupID))
        XCTAssertTrue(session.moveNode(stone.id, into: groupID))
        XCTAssertTrue(session.moveNode(shank.id, by: 1))
        XCTAssertTrue(session.renameNode(shank.id, to: "Band"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("facetforge-phase32-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tree.ffp")
        try session.save(to: url)

        let reopened = FFEditorSession(document: FFDocument())
        try reopened.reopen(from: url)
        let rows = FFObjectTree.rows(in: reopened.document)
        XCTAssertEqual(rows.map(\.name), ["Assembly", "Stone", "Band"])
        XCTAssertEqual(rows.first { $0.id == groupID }?.childCount, 2)
        XCTAssertEqual(children(of: groupID, in: reopened), [stone.id, shank.id])
        XCTAssertEqual(reopened.document.node(withID: shank.id)?.name, "Band")
    }

    // MARK: - Helpers

    private func children(of parentID: UUID, in session: FFEditorSession) -> [UUID] {
        session.document.node(withID: parentID)?.children.map(\.id) ?? []
    }
}
