import Foundation
import XCTest
@testable import FacetForge

/// Phase 29's OBJ interchange.
///
/// The row's acceptance is a fixture with three groups and four materials, and
/// an exported mesh that reimports with bounds matching to 1e-4 mm. Both are
/// proved here against real files and a real session, not a mock.
final class Phase29InterchangeTests: XCTestCase {
    private let fileManager = FileManager.default

    // MARK: - Fixture

    private enum Fixture {
        /// Three groups, four used materials, one material declared but unused.
        /// The stone face is a quad using texture coordinates, so the reader's
        /// polygon fan and `v/vt` syntax are exercised by the same file.
        static let obj = """
        # units: millimetres
        # up-axis: Z
        mtllib fixture.mtl
        o ring
        v 0 0 0
        v 1 0 0
        v 0 1 0
        usemtl gold
        f 1 2 3
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        g stone
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 0 0 1
        usemtl gem
        f 4/1 5/2 6/3 7/4
        g accent
        v 2 0 0
        v 3 0 0
        v 2 1 0
        v 2 -1 0
        usemtl silver
        f 8 9 10
        usemtl accent
        f 8 10 11
        """

        static let mtl = """
        newmtl gold
        Kd 0.83 0.68 0.33
        Pm 1
        Pr 0.24
        newmtl gem
        Kd 0.52 0.84 0.96
        Pm 0.05
        Pr 0.08
        newmtl silver
        Kd 0.9 0.9 0.92
        Pm 1
        Pr 0.18
        newmtl accent
        Kd 0.8 0.2 0.2
        Pm 0
        Pr 0.5
        newmtl unused
        Kd 1 0 0
        """
    }

    private func fixtureAsset() throws -> FFOBJAsset {
        try FFOBJImporter.parse(Fixture.obj, materialLibrary: Fixture.mtl)
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase29-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Reading the fixture

    func testFixtureImportsThreeGroupsAndFourMaterials() throws {
        let asset = try fixtureAsset()

        XCTAssertEqual(asset.groups.map(\.name), ["ring", "stone", "accent"])
        XCTAssertEqual(asset.materials.map(\.name), ["gold", "gem", "silver", "accent"])
        XCTAssertEqual(asset.units, "millimetres")
        XCTAssertEqual(asset.upAxis, "Z")
        XCTAssertTrue(asset.warnings.isEmpty, "unexpected warnings: \(asset.warnings)")

        let ring = try XCTUnwrap(asset.groups.first)
        XCTAssertEqual(ring.meshCount, 1)
        XCTAssertEqual(ring.submeshes[0].material, "gold")
        XCTAssertEqual(ring.submeshes[0].mesh.positions.count, 3, "faces were not compacted to their own vertices")
        XCTAssertEqual(ring.submeshes[0].mesh.triangleCount, 1)

        let stone = asset.groups[1]
        XCTAssertEqual(stone.submeshes[0].material, "gem")
        XCTAssertEqual(stone.submeshes[0].mesh.positions.count, 4)
        XCTAssertEqual(stone.submeshes[0].mesh.triangleCount, 2, "a quad must fan into two triangles")

        let accent = asset.groups[2]
        XCTAssertEqual(accent.submeshes.map(\.material), ["silver", "accent"])
        XCTAssertEqual(accent.meshCount, 2, "two materials in one group must stay two submeshes")

        let gold = try XCTUnwrap(asset.materials.first)
        XCTAssertEqual(gold.baseColor.red, 0.83, accuracy: 1e-9)
        XCTAssertEqual(gold.baseColor.green, 0.68, accuracy: 1e-9)
        XCTAssertEqual(gold.baseColor.blue, 0.33, accuracy: 1e-9)
        XCTAssertEqual(gold.metallic, 1, accuracy: 1e-9)
        XCTAssertEqual(gold.roughness, 0.24, accuracy: 1e-9)

        assertBounds(asset.bounds, equals: AABB(
            minimum: Vec3(x: 0, y: -1, z: 0),
            maximum: Vec3(x: 3, y: 1, z: 1)
        ))
    }

    func testNegativeIndicesResolveAgainstTheVerticesBeforeTheFace() throws {
        let asset = try FFOBJImporter.parse("""
        # units: mm
        v 0 0 0
        v 2 0 0
        v 0 2 0
        f -3 -2 -1
        """)

        XCTAssertEqual(asset.groups.map(\.name), ["default"])
        XCTAssertNil(asset.groups[0].submeshes[0].material)
        XCTAssertTrue(asset.materials.isEmpty)
        assertBounds(asset.bounds, equals: AABB(
            minimum: Vec3(x: 0, y: 0, z: 0),
            maximum: Vec3(x: 2, y: 2, z: 0)
        ))
    }

    func testVertexNormalSyntaxIsAccepted() throws {
        let asset = try FFOBJImporter.parse("""
        # units: mm
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vn 0 0 1
        f 1//1 2//1 3//1
        """)

        XCTAssertEqual(asset.meshCount, 1)
        XCTAssertEqual(asset.groups[0].submeshes[0].mesh.triangleCount, 1)
        XCTAssertTrue(asset.warnings.isEmpty, "unexpected warnings: \(asset.warnings)")
    }

    // MARK: - Refusals

    func testReaderRejectsANonMillimetreHeaderInsteadOfScaling() {
        assertThrows(.unsupportedUnits("inches"), """
        # units: inches
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """)
    }

    func testReaderReportsGeometryDefectsInsteadOfDroppingThem() {
        assertThrows(.malformedNumber("nope", line: 1), """
        v 0 0 nope
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """)
        assertThrows(.indexOutOfRange("4", line: 4), """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 4
        """)
        assertThrows(.degenerateFace(line: 4), """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 1 2
        """)
        assertThrows(.noGeometry, """
        # units: mm
        v 0 0 0
        """)
        assertThrows(.indexOutOfRange("1//2", line: 4), """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1//2 2//2 3//2
        """)
    }

    func testAMissingUnitNoteIsAWarningNotASilentAssumption() throws {
        let asset = try FFOBJImporter.parse("""
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """)

        XCTAssertEqual(asset.units, "millimetres")
        XCTAssertTrue(
            asset.warnings.contains { $0.contains("no unit note") },
            "a file without a unit note must say so: \(asset.warnings)"
        )
    }

    // MARK: - Writing

    func testDocumentExportsTheUnitNoteRealGroupsAndSixDecimals() throws {
        let document = FFDocument.benchSample.document
        let obj = FFOBJExporter.obj(for: document)
        let mtl = FFOBJExporter.mtl(for: document)
        let lines = obj.components(separatedBy: "\n")

        XCTAssertTrue(obj.contains("# units: millimetres"))
        XCTAssertTrue(obj.contains("# up-axis: Z"))
        XCTAssertTrue(obj.contains("mtllib materials.mtl"))
        XCTAssertTrue(obj.contains("g Shank"))
        XCTAssertTrue(obj.contains("g Stone"))
        XCTAssertTrue(obj.contains("usemtl 18k Yellow Gold"))
        XCTAssertTrue(obj.contains("usemtl Gem"))

        XCTAssertEqual(lines.filter { $0.hasPrefix("v ") }.count, 3366)
        XCTAssertEqual(lines.filter { $0.hasPrefix("vn ") }.count, 3366)
        XCTAssertEqual(lines.filter { $0.hasPrefix("f ") }.count, 6728)
        XCTAssertTrue(
            lines.first(where: { $0.hasPrefix("v ") })?.contains(".") ?? false,
            "coordinates must be written as fixed decimals, not scientific notation"
        )

        XCTAssertTrue(mtl.contains("newmtl 18k Yellow Gold"))
        XCTAssertTrue(mtl.contains("Pr 0.240000"))

        // The same document read back through the writer keeps its bounds.
        let asset = try FFOBJImporter.parse(obj, materialLibrary: mtl)
        XCTAssertEqual(asset.groups.map(\.name), ["Shank", "Stone"])
        XCTAssertEqual(asset.meshCount, 2)
        XCTAssertEqual(
            asset.groups.flatMap(\.submeshes).map(\.mesh.triangleCount).reduce(0, +),
            6728
        )
        XCTAssertEqual(asset.materials.map(\.name), ["18k Yellow Gold", "Gem"])
        assertBounds(asset.bounds, equals: try XCTUnwrap(worldBounds(document)), accuracy: 1e-4)
    }

    func testAFixtureRoundTripsThreeGroupsFourMaterialsAndBoundsTo1e_4Millimetres() throws {
        let asset = try fixtureAsset()
        var document = FFDocument(name: "Interchange fixture")
        let built = FFOBJDocumentBuilder.build(asset, layerID: document.currentLayerID)
        document.materials = built.materials
        document.rootNodes = built.nodes

        XCTAssertEqual(document.rootNodes.count, 3)
        XCTAssertEqual(
            document.rootNodes.first(where: { $0.name == "accent" })?.children.count,
            2
        )

        let exported = FFOBJExporter.obj(for: document, mtlFileName: "fixture.mtl")
        let library = FFOBJExporter.mtl(for: document)
        let reimported = try FFOBJImporter.parse(exported, materialLibrary: library)

        XCTAssertEqual(reimported.groups.map(\.name), ["ring", "stone", "accent"])
        XCTAssertEqual(reimported.groups.map(\.meshCount), [1, 1, 2])
        XCTAssertEqual(reimported.materials.map(\.name), ["gold", "gem", "silver", "accent"])
        assertBounds(
            reimported.bounds,
            equals: try XCTUnwrap(asset.bounds),
            accuracy: 1e-4
        )
        assertBounds(
            reimported.bounds,
            equals: try XCTUnwrap(worldBounds(document)),
            accuracy: 1e-4
        )
    }

    // MARK: - Session ownership

    func testImportIsOneUndoableSessionEditThatSurvivesSaveAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let session = FFEditorSession(document: FFDocument(name: "Import bench"))
        let imported = session.importOBJ(try fixtureAsset(), label: "ring.obj")

        XCTAssertEqual(imported, 3)
        XCTAssertEqual(session.document.rootNodes.count, 3)
        XCTAssertEqual(session.document.materials.count, 4)
        XCTAssertEqual(session.scene.nodes.count, 4, "the scene must carry one node per submesh")
        XCTAssertEqual(session.documentStatus, "Imported ring.obj · 3 objects")
        XCTAssertTrue(session.isDirty)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.rootNodes.count, 0)
        XCTAssertEqual(session.document.materials.count, 0)

        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.document.rootNodes.count, 3)

        let url = directory.appendingPathComponent("Imported.ffp")
        try session.save(to: url)
        XCTAssertFalse(session.isDirty)

        let reopened = FFEditorSession(document: FFDocument(name: "Reopen bench"))
        try reopened.reopen(from: url)
        XCTAssertEqual(reopened.document.rootNodes.count, 3)
        XCTAssertEqual(reopened.document.materials.map(\.name), ["gold", "gem", "silver", "accent"])
        XCTAssertEqual(reopened.scene.nodes.count, 4)
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: FFOBJError,
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try FFOBJImporter.parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? FFOBJError, expected, file: file, line: line)
        }
    }

    private func assertBounds(
        _ bounds: AABB?,
        equals expected: AABB,
        accuracy: Double = 1e-6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let bounds else {
            return XCTFail("bounds are nil", file: file, line: line)
        }
        for (actual, wanted) in [
            (bounds.minimum, expected.minimum),
            (bounds.maximum, expected.maximum),
        ] {
            XCTAssertEqual(actual.x, wanted.x, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(actual.y, wanted.y, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(actual.z, wanted.z, accuracy: accuracy, file: file, line: line)
        }
    }

    /// The world-space bounds of every mesh in the document, which is what an
    /// exporter must preserve even when a node carries a transform.
    private func worldBounds(_ document: FFDocument) -> AABB? {
        var box: AABB?

        func visit(_ node: FFNode, parent: Mat4) {
            let world = parent * node.transform.matrix
            if let mesh = node.geometry?.mesh?.mesh, let local = mesh.bounds {
                for x in [local.minimum.x, local.maximum.x] {
                    for y in [local.minimum.y, local.maximum.y] {
                        for z in [local.minimum.z, local.maximum.z] {
                            let point = world.transformedPoint(Vec3(x: x, y: y, z: z))
                            let corner = AABB(minimum: point, maximum: point)
                            box = box.map { $0.union(corner) } ?? corner
                        }
                    }
                }
            }
            for child in node.children {
                visit(child, parent: world)
            }
        }

        for root in document.rootNodes {
            visit(root, parent: .identity)
        }
        return box
    }
}
