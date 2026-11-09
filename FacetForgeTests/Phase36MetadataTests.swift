import Foundation
import XCTest
@testable import FacetForge

/// Phase 36's two acceptance clauses at the document boundary: every metadata
/// field round-trips through the file format, and the stone summary is exactly
/// the document's stone list rather than a stored count that can drift.
final class Phase36MetadataTests: XCTestCase {
    private let fileManager = FileManager.default

    // MARK: - File format round trip

    func testEveryMetadataFieldRoundTripsThroughTheFileFormat() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let session = FFEditorSession(
            document: FFDocument.benchSample.document,
            autosaveInterval: 0
        )
        XCTAssertFalse(
            String(decoding: try session.document.encoded(), as: UTF8.self)
                .contains("\"metadata\""),
            "the bench sample gained Phase 36's key before any field was written"
        )

        let partNumber = "FF-1042"
        let sku = "RING-18K-YG-6"
        let summary = "Six-claw solitaire with a 6 mm brilliant."
        let notes = "Size 6½ · rhodium before setting · client initials J.R."
        XCTAssertTrue(session.setMetadataField(.partNumber, value: partNumber))
        XCTAssertTrue(session.setMetadataField(.sku, value: sku))
        XCTAssertTrue(session.setMetadataField(.itemDescription, value: summary))
        XCTAssertTrue(session.setMetadataField(.workshopNotes, value: notes))

        XCTAssertTrue(session.toggleManufacturingFlag(.casting))
        XCTAssertTrue(session.toggleManufacturingFlag(.stoneSetting))
        XCTAssertTrue(session.toggleManufacturingFlag(.handEngraving))

        let encoded = String(decoding: try session.document.encoded(), as: UTF8.self)
        for key in ["partNumber", "sku", "description", "workshopNotes", "manufacturingFlags"] {
            XCTAssertTrue(encoded.contains("\"\(key)\""), "the encoding is missing \(key)")
        }
        XCTAssertTrue(encoded.contains("\"description\":\"\(summary)\""))

        let url = directory.appendingPathComponent("Metadata.ffp")
        try session.save(to: url)
        let reopened = FFEditorSession(autosaveInterval: 0)
        try reopened.reopen(from: url)

        XCTAssertEqual(reopened.metadata.partNumber, partNumber)
        XCTAssertEqual(reopened.metadata.sku, sku)
        XCTAssertEqual(reopened.metadata.itemDescription, summary)
        XCTAssertEqual(reopened.metadata.workshopNotes, notes)
        XCTAssertEqual(
            reopened.metadata.manufacturingFlags,
            [.casting, .stoneSetting, .handEngraving]
        )
        XCTAssertEqual(reopened.document.stateHash, session.document.stateHash)
        XCTAssertEqual(reopened.stoneSummary, session.stoneSummary)
    }

    func testEmptyMetadataIsPrunedSoUntouchedDocumentsKeepTheirHash() throws {
        let baseline = FFDocument.benchSample.document
        let baselineHash = baseline.stateHash
        let session = FFEditorSession(document: baseline, autosaveInterval: 0)

        XCTAssertTrue(session.setMetadataField(.partNumber, value: "FF-1"))
        XCTAssertNotEqual(session.document.stateHash, baselineHash)
        XCTAssertTrue(session.setMetadataField(.partNumber, value: ""))
        XCTAssertEqual(
            session.document.stateHash,
            baselineHash,
            "clearing the last field must restore the pre-Phase 36 encoding"
        )
        XCTAssertNil(session.document.metadata)

        XCTAssertTrue(session.toggleManufacturingFlag(.casting))
        XCTAssertNotNil(session.document.metadata)
        XCTAssertTrue(session.toggleManufacturingFlag(.casting))
        XCTAssertNil(session.document.metadata)
        XCTAssertEqual(session.document.stateHash, baselineHash)
    }

    // MARK: - Stone summary

    func testStoneSummaryMatchesTheStoneListExactly() throws {
        let gold = FFMaterial(name: "18k Yellow Gold")
        let gem = FFMaterial(name: "Gem")
        let mesh = try XCTUnwrap(FFMeshFactory.octahedron(radius: 2))

        func stone(_ name: String, _ material: FFMaterial) -> FFNode {
            FFNode(
                name: name,
                geometry: .mesh(FFMeshPayload(mesh)),
                materialID: material.id,
                kind: .stone
            )
        }

        let cluster = FFNode(
            name: "Cluster",
            children: [stone("Centre", gem), stone("Halo", gem)]
        )
        let band = FFNode(
            name: "Shank",
            geometry: .mesh(FFMeshPayload(mesh)),
            materialID: gold.id,
            kind: .solid
        )
        let accent = stone("Accent", gem)
        let document = FFDocument(
            materials: [gold, gem],
            rootNodes: [cluster, band, accent]
        )

        let summary = document.stoneSummary()
        let treeStones = FFObjectTree.rows(in: document).filter { $0.kind == .stone }
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.label, "3 stones")
        XCTAssertEqual(summary.stones.map(\.id), treeStones.map(\.id))
        XCTAssertEqual(summary.stones.map(\.name), treeStones.map(\.name))
        XCTAssertEqual(summary.stones.map(\.name), ["Centre", "Halo", "Accent"])
        XCTAssertEqual(summary.stones.map(\.materialName), ["Gem", "Gem", "Gem"])
        XCTAssertFalse(summary.stones.contains { $0.name == "Shank" })

        let empty = FFDocument()
        XCTAssertEqual(empty.stoneSummary().label, "0 stones")
        XCTAssertTrue(empty.stoneSummary().stones.isEmpty)
    }

    func testStoneSummaryFollowsRenamesAndUndo() throws {
        let gem = FFMaterial(name: "Gem")
        let mesh = try XCTUnwrap(FFMeshFactory.octahedron(radius: 2))
        let centre = FFNode(
            name: "Stone",
            geometry: .mesh(FFMeshPayload(mesh)),
            materialID: gem.id,
            kind: .stone
        )
        let session = FFEditorSession(
            document: FFDocument(materials: [gem], rootNodes: [centre]),
            autosaveInterval: 0
        )
        XCTAssertEqual(session.stoneSummary.stones.first?.name, "Stone")

        XCTAssertTrue(session.renameNode(centre.id, to: "Centre stone"))
        XCTAssertEqual(session.stoneSummary.stones.first?.name, "Centre stone")
        XCTAssertEqual(session.stoneSummary.stones.first?.id, centre.id)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.stoneSummary.stones.first?.name, "Stone")
        XCTAssertEqual(session.stoneSummary.count, 1, "undo must not duplicate or lose a stone")
    }

    // MARK: - Flags and edit granularity

    func testManufacturingFlagsAreCanonicalWhateverTheToggleOrder() throws {
        let first = FFEditorSession(
            document: FFDocument.benchSample.document,
            autosaveInterval: 0
        )
        first.toggleManufacturingFlag(.casting)
        first.toggleManufacturingFlag(.stoneSetting)
        first.toggleManufacturingFlag(.rhodiumPlating)

        let second = FFEditorSession(
            document: FFDocument.benchSample.document,
            autosaveInterval: 0
        )
        second.toggleManufacturingFlag(.rhodiumPlating)
        second.toggleManufacturingFlag(.stoneSetting)
        second.toggleManufacturingFlag(.casting)

        XCTAssertEqual(
            first.metadata.manufacturingFlags,
            [.casting, .stoneSetting, .rhodiumPlating]
        )
        XCTAssertEqual(first.document.stateHash, second.document.stateHash)

        let decoded = try FFDocument.decoded(from: first.document.encoded())
        XCTAssertEqual(decoded.resolvedMetadata.manufacturingFlags,
                       [.casting, .stoneSetting, .rhodiumPlating])
        XCTAssertEqual(decoded.stateHash, first.document.stateHash)
    }

    func testTypingCoalescesToOneUndoAndAFlagIsItsOwnStep() throws {
        let session = FFEditorSession(
            document: FFDocument.benchSample.document,
            autosaveInterval: 0
        )
        let depth = session.documentSession.undoDepth

        XCTAssertTrue(session.setMetadataField(.partNumber, value: "F"))
        XCTAssertTrue(session.setMetadataField(.partNumber, value: "FF"))
        XCTAssertTrue(session.setMetadataField(.partNumber, value: "FF-10"))
        XCTAssertEqual(session.documentSession.undoDepth, depth + 1)
        XCTAssertEqual(session.metadata.partNumber, "FF-10")
        XCTAssertEqual(session.documentSession.undoName, "Part number")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.resolvedMetadata.partNumber, "")
        XCTAssertEqual(session.metadata.partNumber, "")
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.document.resolvedMetadata.partNumber, "FF-10")
        XCTAssertEqual(session.metadata.partNumber, "FF-10")

        XCTAssertTrue(session.toggleManufacturingFlag(.stoneSetting))
        XCTAssertEqual(session.documentSession.undoDepth, depth + 2)
        XCTAssertTrue(session.metadata.isFlagEnabled(.stoneSetting))
        XCTAssertTrue(session.undo())
        XCTAssertFalse(session.document.resolvedMetadata.isFlagEnabled(.stoneSetting))
        XCTAssertFalse(session.metadata.isFlagEnabled(.stoneSetting))
        XCTAssertEqual(
            session.document.resolvedMetadata.partNumber,
            "FF-10",
            "undoing the flag must not touch the typed part number"
        )
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase36-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
