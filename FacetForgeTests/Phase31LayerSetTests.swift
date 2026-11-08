import XCTest
@testable import FacetForge

/// Phase 31's acceptance. Layer states and sets are document state owned by
/// `FFEditorSession`: the tests prove exact save/reload, that switching a set
/// restores its own states without rewriting the other sets, and that a
/// template import is one ordinary undoable edit.
final class Phase31LayerSetTests: XCTestCase {
    // MARK: - States

    func testEveryLayerStateRoundTripsAndLegacyFilesStillPrint() throws {
        let layer = FFLayer(
            name: "Print plate",
            color: FFLayer.palette[2],
            isVisible: false,
            isLocked: true,
            isPrintable: false
        )
        let decoded = try JSONDecoder().decode(FFLayer.self, from: JSONEncoder().encode(layer))
        XCTAssertEqual(decoded, layer)
        XCTAssertEqual(decoded.state, layer.state)

        // A file written before Phase 31 has no print state. It must decode as
        // printable rather than silently leaving the print.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(layer)) as? [String: Any]
        )
        object.removeValue(forKey: "isPrintable")
        let legacy = try JSONDecoder().decode(
            FFLayer.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(legacy.isPrintable)
        XCTAssertFalse(legacy.isVisible)
        XCTAssertTrue(legacy.isLocked)

        var changed = layer
        changed.apply(FFLayerState(color: FFLayer.palette[4]))
        XCTAssertEqual(changed.color, FFLayer.palette[4])
        XCTAssertTrue(changed.isVisible)
        XCTAssertFalse(changed.isLocked)
        XCTAssertTrue(changed.isPrintable)
    }

    func testDocumentWithoutLayerSetsGainsOneDefaultSet() throws {
        let document = FFDocument(name: "Legacy", rootNodes: [FFNode(name: "Bench")])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any]
        )
        object.removeValue(forKey: "layerSets")
        object.removeValue(forKey: "activeLayerSetID")
        let decoded = try FFDocument.decoded(
            from: JSONSerialization.data(withJSONObject: object)
        )

        let set = try XCTUnwrap(decoded.layerSets.first)
        XCTAssertEqual(decoded.layerSets.count, 1)
        XCTAssertEqual(set.name, "Default")
        XCTAssertEqual(decoded.activeLayerSetID, set.id)
        XCTAssertEqual(set.layerIDs, decoded.layers.map(\.id))
        XCTAssertEqual(set.state(forLayer: decoded.layers[0].id)?.isVisible, true)
    }

    // MARK: - Save and reload

    func testDocumentWithLayerSetsSavesAndReloadsExactly() throws {
        let session = FFEditorSession()
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        let first = try XCTUnwrap(session.activeLayerSetID)

        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: false))
        XCTAssertTrue(session.setLayerPrintable(stones.id, isPrintable: false))
        let second = try XCTUnwrap(session.addLayerSet(named: "Presentation"))
        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: true))
        XCTAssertTrue(session.setLayerLocked(stones.id, isLocked: true))
        XCTAssertTrue(session.cycleLayerColor(stones.id))

        let expectedLayers = session.layers
        let expectedSets = session.layerSets
        let expectedActive = session.activeLayerSetID
        XCTAssertEqual(expectedActive, second)
        XCTAssertEqual(
            expectedSets.first { $0.id == first }?.state(forLayer: stones.id)?.isVisible,
            false
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("facetforge-phase31-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sets.ffp")
        try session.save(to: url)

        let saved = try FFDocumentStore().load(from: url)
        XCTAssertEqual(saved.layers, expectedLayers, "a layer state did not reach the save file")
        XCTAssertEqual(saved.layerSets, expectedSets, "layer sets did not reach the save file")
        XCTAssertEqual(saved.activeLayerSetID, expectedActive)
        XCTAssertEqual(try FFDocument.decoded(from: saved.encoded()), saved)

        let reopened = FFEditorSession(document: FFDocument())
        try reopened.reopen(from: url)
        XCTAssertEqual(reopened.layers, expectedLayers)
        XCTAssertEqual(reopened.layerSets, expectedSets)
        XCTAssertEqual(reopened.activeLayerSetID, expectedActive)
        XCTAssertEqual(reopened.layer(withID: stones.id)?.isPrintable, false)
    }

    // MARK: - Switching

    func testSwitchingPreservesEachSetsOwnVisibility() throws {
        let session = FFEditorSession()
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        let first = try XCTUnwrap(session.activeLayerSetID)

        // Set A: Stones hidden.
        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: false))
        // Set B starts from what is on screen, then Stones is shown again.
        let second = try XCTUnwrap(session.addLayerSet(named: "Presentation"))
        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: true))

        XCTAssertEqual(session.layer(withID: stones.id)?.isVisible, true)
        XCTAssertEqual(
            session.layerSets.first { $0.id == second }?.state(forLayer: stones.id)?.isVisible,
            true
        )

        // Back to A: hidden again, and B's stored visibility is untouched.
        XCTAssertTrue(session.activateLayerSet(first))
        XCTAssertEqual(session.layer(withID: stones.id)?.isVisible, false)
        XCTAssertEqual(
            session.layerSets.first { $0.id == second }?.state(forLayer: stones.id)?.isVisible,
            true,
            "switching to A rewrote B's stored visibility"
        )

        // Back to B: its own state, not A's.
        XCTAssertTrue(session.activateLayerSet(second))
        XCTAssertEqual(session.layer(withID: stones.id)?.isVisible, true)
        XCTAssertEqual(
            session.layerSets.first { $0.id == first }?.state(forLayer: stones.id)?.isVisible,
            false,
            "switching to B rewrote A's stored visibility"
        )
    }

    func testColourAndPrintStatesFollowTheirSet() throws {
        let session = FFEditorSession()
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        let first = try XCTUnwrap(session.activeLayerSetID)
        let firstColor = stones.color

        XCTAssertTrue(session.cycleLayerColor(stones.id))
        let colourA = try XCTUnwrap(session.layer(withID: stones.id)?.color)
        XCTAssertNotEqual(colourA, firstColor)
        XCTAssertTrue(session.setLayerPrintable(stones.id, isPrintable: false))

        let second = try XCTUnwrap(session.addLayerSet(named: "Presentation"))
        XCTAssertFalse(try XCTUnwrap(session.layer(withID: stones.id)).isPrintable)
        XCTAssertTrue(session.setLayerPrintable(stones.id, isPrintable: true))
        XCTAssertTrue(session.cycleLayerColor(stones.id))
        let colourB = try XCTUnwrap(session.layer(withID: stones.id)?.color)
        XCTAssertNotEqual(colourB, colourA)

        XCTAssertTrue(session.activateLayerSet(first))
        XCTAssertEqual(session.layer(withID: stones.id)?.color, colourA)
        XCTAssertEqual(session.layer(withID: stones.id)?.isPrintable, false)

        XCTAssertTrue(session.activateLayerSet(second))
        XCTAssertEqual(session.layer(withID: stones.id)?.color, colourB)
        XCTAssertEqual(session.layer(withID: stones.id)?.isPrintable, true)

        // Print is a normal edit: it can be undone and reaches the journal.
        XCTAssertTrue(session.setLayerPrintable(stones.id, isPrintable: false))
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.layer(withID: stones.id)?.isPrintable, true)
    }

    func testSetSwitchIsOneUndoableEditAndRestoresThePreviousSet() throws {
        let session = FFEditorSession()
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        let first = try XCTUnwrap(session.activeLayerSetID)

        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: false))
        let second = try XCTUnwrap(session.addLayerSet(named: "Presentation"))
        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: true))

        let depthBeforeSwitch = session.documentSession.undoDepth
        XCTAssertTrue(session.activateLayerSet(first))
        XCTAssertEqual(session.documentSession.undoDepth, depthBeforeSwitch + 1)
        XCTAssertEqual(session.activeLayerSetID, first)
        XCTAssertEqual(session.layer(withID: stones.id)?.isVisible, false)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.activeLayerSetID, second)
        XCTAssertEqual(session.layer(withID: stones.id)?.isVisible, true)

        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.activeLayerSetID, first)
        XCTAssertEqual(session.layer(withID: stones.id)?.isVisible, false)
    }

    func testNewLayerJoinsEverySetAndSurvivesSwitching() throws {
        let session = FFEditorSession()
        let first = try XCTUnwrap(session.activeLayerSetID)
        let second = try XCTUnwrap(session.addLayerSet(named: "Presentation"))
        let added = try XCTUnwrap(session.addLayer(named: "Findings"))

        for setID in [first, second] {
            let set = try XCTUnwrap(session.layerSets.first { $0.id == setID })
            XCTAssertNotNil(set.state(forLayer: added), "a new layer was missing from set \(set.name)")
        }

        XCTAssertTrue(session.activateLayerSet(first))
        XCTAssertNotNil(session.layer(withID: added))
        XCTAssertNotEqual(session.activeLayerSetID, second)
    }

    // MARK: - Document template import

    func testTemplateImportAddsOnlyMissingLayersInOneUndoStep() throws {
        let session = FFEditorSession()
        let metal = try XCTUnwrap(session.layers.first { $0.name == "Metal" })
        let originalColor = metal.color
        let setCountBefore = session.layerSets.count

        let template = FFLayerTemplate(
            name: "Shop",
            layers: [
                FFLayer(name: "Metal", color: FFLayer.palette[1]),
                FFLayer(
                    name: "Findings",
                    color: FFLayer.palette[2],
                    isPrintable: false
                ),
                // A duplicate name inside the template must not add twice.
                FFLayer(name: "Findings", color: FFLayer.palette[3])
            ]
        )

        XCTAssertEqual(session.importLayerTemplate(template), 1)
        XCTAssertEqual(session.layers.count, 3)
        XCTAssertEqual(session.layer(withID: metal.id)?.color, originalColor)
        let findings = try XCTUnwrap(session.layers.last)
        XCTAssertEqual(findings.name, "Findings")
        XCTAssertFalse(findings.isPrintable)
        XCTAssertEqual(session.layerSets.count, setCountBefore)
        for set in session.layerSets {
            XCTAssertEqual(set.state(forLayer: findings.id)?.isPrintable, false)
        }

        // Importing the same template again is a no-op that records no edit.
        let depth = session.documentSession.undoDepth
        XCTAssertEqual(session.importLayerTemplate(template), 0)
        XCTAssertEqual(session.documentSession.undoDepth, depth)

        // One undo removes the imported layer and its entries in every set.
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.layers.count, 2)
        XCTAssertNil(session.layer(withID: findings.id))
        for set in session.layerSets {
            XCTAssertNil(set.state(forLayer: findings.id))
        }
    }

    func testWorkshopTemplateIsDistinctFromTheBenchLayers() {
        let benchNames = Set(FFDocument.benchSample.document.layers.map(\.name.lowercased()))
        let templateNames = Set(FFLayerTemplate.workshop.layers.map(\.name.lowercased()))
        XCTAssertTrue(
            templateNames.isDisjoint(with: benchNames),
            "the workshop template would import nothing into the bench sample"
        )
        XCTAssertEqual(templateNames.count, FFLayerTemplate.workshop.layers.count)
    }
}
