import Foundation
import XCTest
@testable import FacetForge

/// Phase 37's acceptance: every template is a real `.ffp` document that opens
/// in under two seconds with an empty undo stack and no missing references, and
/// each template has a committed snapshot.
///
/// The snapshot is the document's own shape, not an opaque rendering digest:
/// node order, kinds, triangle counts, materials, stones and layers. A geometry,
/// naming or hierarchy change therefore fails with the field that moved, and a
/// reviewer sees the template's real `manifest.json` and `preview.png` attached
/// to the run. Determinism is checked separately by rebuilding the template and
/// comparing its canonical encoding hash.
final class Phase37TemplateTests: XCTestCase {
    private struct Snapshot: Equatable {
        var name: String
        var nodeNames: [String]
        var nodeKinds: [String]
        var triangleCount: Int
        var materialNames: [String]
        var stoneNames: [String]
        var layerNames: [String]
    }

    /// Committed from the template definitions themselves: the counts follow
    /// from the mesh parameters (a torus of m × n segments is 2mn triangles, an
    /// octahedron is 8, a box is 12). A change here is a template change and
    /// must be reviewed as one.
    private static let expected: [FFDocumentTemplate: Snapshot] = [
        .solitaireRing: Snapshot(
            name: "Solitaire Ring",
            nodeNames: ["Solitaire Ring", "Shank", "Halo", "Centre Stone"],
            nodeKinds: ["group", "solid", "solid", "stone"],
            triangleCount: 4608 + 2048 + 8,
            materialNames: ["18K yellow gold", "Round Brilliant"],
            stoneNames: ["Centre Stone"],
            layerNames: ["Metal", "Stones"]
        ),
        .plainBand: Snapshot(
            name: "Plain Band",
            nodeNames: ["Comfort Band"],
            nodeKinds: ["solid"],
            triangleCount: 4608,
            materialNames: ["Platinum 950"],
            stoneNames: [],
            layerNames: ["Metal"]
        ),
        .pendant: Snapshot(
            name: "Pendant",
            nodeNames: ["Pendant", "Bail", "Girdle Collar", "Pear Drop"],
            nodeKinds: ["group", "solid", "solid", "stone"],
            triangleCount: 1536 + 1536 + 8,
            materialNames: ["18K white gold", "Pear Brilliant"],
            stoneNames: ["Pear Drop"],
            layerNames: ["Metal", "Stones"]
        ),
        .signet: Snapshot(
            name: "Signet",
            nodeNames: ["Signet Ring", "Shank", "Face", "Crest"],
            nodeKinds: ["group", "solid", "solid", "solid"],
            triangleCount: 4608 + 12 + 12,
            materialNames: ["18K yellow gold", "Antique Gold"],
            stoneNames: [],
            layerNames: ["Metal"]
        ),
    ]

    private let store = FFDocumentStore()
    private let fileManager = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase37-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snapshot(of document: FFDocument) -> Snapshot {
        var names: [String] = []
        var kinds: [String] = []
        var triangles = 0

        func walk(_ nodes: [FFNode]) {
            for node in nodes {
                names.append(node.name)
                kinds.append(node.kind?.rawValue ?? "group")
                triangles += node.meshTriangleCount
                walk(node.children)
            }
        }

        walk(document.rootNodes)
        return Snapshot(
            name: document.name,
            nodeNames: names,
            nodeKinds: kinds,
            triangleCount: triangles,
            materialNames: document.materials.map(\.name),
            stoneNames: document.stoneSummary().stones.map(\.name),
            layerNames: document.layers.map(\.name)
        )
    }

    // MARK: - Opening

    /// The row's CI clause. Each template is written as a bundle, then opened
    /// through the same session path the browser uses. The elapsed time covers
    /// the read, the scene projection and the journal attach, which is what a
    /// user waits for when a template is chosen.
    func testEachTemplateOpensInUnderTwoSecondsWithAnEmptyHistory() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        for template in FFDocumentTemplate.allCases {
            let url = directory
                .appendingPathComponent(template.fileBaseName)
                .appendingPathExtension("ffp")
            try store.save(template.makeDocument(), to: url)

            let session = FFEditorSession(documentURL: url, autosaveInterval: 0)
            let clock = ContinuousClock()
            let start = clock.now
            try session.reopen(from: url)
            let elapsed = clock.now - start

            XCTAssertLessThan(
                elapsed,
                .seconds(2),
                "\(template.title) took \(elapsed) to open; the row budgets two seconds"
            )
            XCTAssertEqual(session.documentSession.undoDepth, 0, "\(template.title) opened with history")
            XCTAssertEqual(session.documentSession.redoDepth, 0, "\(template.title) opened with redo history")
            XCTAssertFalse(session.documentSession.canUndo)
            XCTAssertEqual(session.documentSession.appliedChangeCount, 0)
            XCTAssertEqual(
                session.documentSession.document.stateHash,
                template.makeDocument().stateHash,
                "\(template.title) did not open as the document that was saved"
            )
            XCTAssertNil(session.recoveryMessage)
        }
    }

    // MARK: - Snapshot

    /// One committed snapshot per template, plus proof that building the same
    /// template twice produces byte-identical canonical JSON and that the file
    /// format returns the same document.
    func testEachTemplateMatchesItsCommittedSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        for template in FFDocumentTemplate.allCases {
            let document = template.makeDocument()
            let expected = try XCTUnwrap(
                Self.expected[template],
                "no committed snapshot for \(template.title)"
            )
            XCTAssertEqual(
                snapshot(of: document),
                expected,
                "\(template.title)'s snapshot changed; review the template, not the test"
            )
            XCTAssertEqual(
                document.stateHash,
                template.makeDocument().stateHash,
                "\(template.title) is not deterministic across builds"
            )

            let url = directory
                .appendingPathComponent(template.fileBaseName)
                .appendingPathExtension("ffp")
            try store.save(
                document,
                to: url,
                thumbnail: FFPThumbnail.png(for: document)
            )
            let content = try store.loadContent(from: url)
            XCTAssertEqual(content.document.stateHash, document.stateHash)
            XCTAssertEqual(content.document, document)
            XCTAssertNil(content.recovery)

            let manifest = try Data(contentsOf: url.appendingPathComponent(FFPFormat.manifestName))
            let manifestAttachment = XCTAttachment(
                data: manifest,
                uniformTypeIdentifier: "public.json"
            )
            manifestAttachment.name = "template-\(template.rawValue)-manifest"
            manifestAttachment.lifetime = .keepAlways
            add(manifestAttachment)

            let thumbnail = try XCTUnwrap(
                content.thumbnail,
                "\(template.title) saved without a preview.png"
            )
            let thumbnailAttachment = XCTAttachment(
                data: thumbnail,
                uniformTypeIdentifier: "public.png"
            )
            thumbnailAttachment.name = "template-\(template.rawValue)-preview"
            thumbnailAttachment.lifetime = .keepAlways
            add(thumbnailAttachment)
        }
    }

    // MARK: - References

    /// No dangling material, layer or face-group reference, every mesh payload
    /// rebuilds, every mesh node reaches the renderer, and the stone summary is
    /// the stone list rather than a stored count.
    func testTemplatesHaveNoMissingReferences() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        for template in FFDocumentTemplate.allCases {
            let url = directory
                .appendingPathComponent(template.rawValue)
                .appendingPathExtension("ffp")
            try store.save(template.makeDocument(), to: url)
            let document = try store.load(from: url)

            let materialIDs = Set(document.materials.map(\.id))
            let layerIDs = Set(document.layers.map(\.id))
            XCTAssertEqual(materialIDs.count, document.materials.count, "\(template.title): duplicate material id")
            XCTAssertEqual(layerIDs.count, document.layers.count, "\(template.title): duplicate layer id")
            XCTAssertEqual(document.layerSets.count, 1)
            XCTAssertEqual(document.activeLayerSetID, document.layerSets.first?.id)
            XCTAssertEqual(
                Set(document.layerSets.first?.layerIDs ?? []),
                layerIDs,
                "\(template.title): the Default layer set does not cover every layer"
            )
            XCTAssertTrue(
                document.currentLayerID.map(layerIDs.contains) ?? false,
                "\(template.title): the current layer does not exist"
            )

            let nodes = document.rootNodes.flatMap { $0.flattenedNodes() }
            var meshNodes: [FFNode] = []
            for node in nodes {
                if let layerID = node.layerID {
                    XCTAssertTrue(layerIDs.contains(layerID), "\(template.title): \(node.name) has a missing layer")
                }
                guard let geometry = node.geometry else {
                    XCTAssertNil(node.materialID, "\(template.title): \(node.name) names a material without geometry")
                    continue
                }
                let mesh = try XCTUnwrap(geometry.mesh?.mesh, "\(template.title): \(node.name) mesh does not rebuild")
                XCTAssertFalse(mesh.positions.isEmpty)
                meshNodes.append(node)

                let materialID = try XCTUnwrap(node.materialID, "\(template.title): \(node.name) has no material")
                XCTAssertTrue(materialIDs.contains(materialID), "\(template.title): \(node.name) names a missing material")

                for group in node.faceGroups ?? [] {
                    XCTAssertTrue(
                        materialIDs.contains(group.materialID),
                        "\(template.title): \(node.name) face group \(group.name) names a missing material"
                    )
                    XCTAssertFalse(group.triangles.isEmpty)
                    for triangle in group.triangles {
                        XCTAssertTrue(
                            triangle >= 0 && triangle < mesh.triangleCount,
                            "\(template.title): \(node.name) face group \(group.name) points outside the mesh"
                        )
                    }
                }
            }

            let scene = FFEditorSession.scene(from: document)
            XCTAssertEqual(
                scene.nodes.count,
                meshNodes.count,
                "\(template.title): the renderer is missing a mesh node"
            )
            XCTAssertEqual(
                scene.triangleCount,
                meshNodes.reduce(0) { $0 + $1.meshTriangleCount },
                "\(template.title): the renderer draws a different triangle total"
            )

            let stones = nodes.filter { FFObjectKind.classify($0) == .stone }
            XCTAssertEqual(document.stoneSummary().stones.map(\.id), stones.map(\.id))
            XCTAssertEqual(document.stoneSummary().count, stones.count)
        }
    }

    // MARK: - Creating from a template

    /// The browser path: the template becomes a real bundle in the library and
    /// opens with an empty history, and asking for the same template again
    /// numbers the new file instead of overwriting the first.
    func testCreatingFromATemplateWritesBundlesAndNeverOverwrites() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let session = FFEditorSession(
            documentURL: directory.appendingPathComponent("Open.ffp"),
            autosaveInterval: 0
        )

        let first = try session.createDocument(from: .solitaireRing)
        XCTAssertEqual(first.lastPathComponent, "Solitaire Ring.ffp")
        XCTAssertEqual(session.documentSession.undoDepth, 0)
        XCTAssertEqual(session.documentSession.document.name, "Solitaire Ring")
        XCTAssertEqual(
            session.documentSession.document.stateHash,
            FFDocumentTemplate.solitaireRing.makeDocument().stateHash
        )

        let second = try session.createDocument(from: .solitaireRing)
        XCTAssertEqual(second.lastPathComponent, "Solitaire Ring 2.ffp")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try store.load(from: first).stateHash, try store.load(from: second).stateHash)
        XCTAssertEqual(
            FFDocumentLibrary(directory: directory).documents().count,
            2,
            "the library lists the two real template bundles"
        )
        XCTAssertEqual(session.documentSession.undoDepth, 0)
    }
}
