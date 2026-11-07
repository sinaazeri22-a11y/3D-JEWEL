import UIKit
import XCTest
@testable import FacetForge

/// Phase 25's acceptance: the `.ffp` bundle is a real, versioned format whose
/// manifest validates against the shipped schema, and a rewrite preserves
/// fields and files this version does not understand.
final class Phase25FileFormatTests: XCTestCase {
    private let bundle = FFPDocumentBundle()

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var schemaURL: URL {
        repositoryRoot.appendingPathComponent("docs/format/ffp-1.0.schema.json")
    }

    // MARK: - Schema

    func testManifestMatchesTheShippedSchemaAndTheValidatorCoversIt() throws {
        let validator = try FFPJSONSchemaValidator(schemaURL: schemaURL)
        XCTAssertEqual(
            validator.unsupportedKeywords,
            [],
            "the schema uses keywords the validator does not implement"
        )

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, document) in [
            ("empty", FFDocument(name: "Empty")),
            ("sample", sampleDocument())
        ] {
            let url = directory.appendingPathComponent("\(name).ffp")
            try bundle.write(
                document: document,
                to: url,
                thumbnail: FFPThumbnail.png(for: document)
            )
            let manifest = try manifestTree(at: url)
            let errors = validator.validate(manifest)
            XCTAssertEqual(errors, [], "\(name) manifest failed schema validation")
        }
    }

    func testSchemaRejectsMalformedManifests() throws {
        let validator = try FFPJSONSchemaValidator(schemaURL: schemaURL)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.ffp")
        try bundle.write(document: sampleDocument(), to: url)
        let valid = try manifestTree(at: url)
        XCTAssertEqual(validator.validate(valid), [])

        XCTAssertFalse(
            validator.validate(valid.removing("formatVersion")).isEmpty,
            "a manifest without a version must fail"
        )
        XCTAssertFalse(
            validator.validate(valid.setting("formatVersion", to: .string("one"))).isEmpty,
            "a string version must fail"
        )
        XCTAssertFalse(
            validator.validate(valid.setting("format", to: .string("something-else"))).isEmpty,
            "a foreign format identifier must fail"
        )
        XCTAssertFalse(
            validator.validate(valid.setting("document", to: .null)).isEmpty,
            "a missing document must fail"
        )
    }

    // MARK: - Geometry buffers

    func testGeometryBlocksRoundTripAndRejectCorruption() throws {
        let document = sampleDocument()
        let geometry = try XCTUnwrap(document.rootNodes.first?.children.first?.geometry)
        let block = try FFPGeometryCodec.encode(geometry)
        XCTAssertEqual(
            try FFPGeometryCodec.decode(block, expecting: FFPGeometryCodec.kind(of: geometry)),
            geometry
        )

        XCTAssertThrowsError(
            try FFPGeometryCodec.decode(Data(block.dropLast(1)), expecting: .mesh)
        )
        var wrongMagic = block
        wrongMagic.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try FFPGeometryCodec.decode(wrongMagic, expecting: .mesh))
        XCTAssertThrowsError(try FFPManifest.validateRelativePath("../escape.bin"))
        XCTAssertThrowsError(try FFPManifest.validateRelativePath("/absolute.bin"))
    }

    // MARK: - Bundle round trip

    func testBundleRoundTripKeepsTheDocumentExactAndWritesItsParts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ring.ffp")
        let document = sampleDocument()

        let thumbnail = try XCTUnwrap(FFPThumbnail.png(for: document))
        XCTAssertEqual(thumbnail.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        try bundle.write(document: document, to: url, thumbnail: thumbnail)
        let content = try bundle.read(from: url)
        XCTAssertFalse(content.legacySingleFile)
        XCTAssertEqual(content.document, document)
        XCTAssertEqual(content.document.stateHash, document.stateHash)
        XCTAssertEqual(content.thumbnail, thumbnail)
        XCTAssertNotNil(content.preservation)

        let entries = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        XCTAssertTrue(entries.contains("manifest.json"))
        XCTAssertTrue(entries.contains("checksums.json"))
        XCTAssertTrue(entries.contains("preview.png"))
        XCTAssertTrue(entries.contains("geometry"))

        let checksums = try FFPJSONValue.parse(
            Data(contentsOf: url.appendingPathComponent("checksums.json"))
        )
        let paths = try XCTUnwrap(checksums["files"]?.arrayValue).compactMap { $0["path"]?.stringValue }
        XCTAssertTrue(paths.contains("manifest.json"))
        XCTAssertTrue(paths.contains("preview.png"))
        XCTAssertTrue(paths.contains("geometry/geometry-000.bin"))
        XCTAssertFalse(paths.contains("checksums.json"))
    }

    // MARK: - Preservation

    func testUnknownManifestFieldsAndFilesSurviveARewrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("future.ffp")
        let document = sampleDocument()
        try bundle.write(document: document, to: url, thumbnail: FFPThumbnail.png(for: document))

        var manifest = try manifestTree(at: url)
        manifest = manifest.setting(
            "futureFeature",
            to: .object(["enabled": .bool(true), "note": .string("kept at the top level")])
        )
        var documentTree = try XCTUnwrap(manifest["document"])
        documentTree = documentTree.setting("futureDocumentField", to: .string("kept"))
        documentTree = try addingFutureFieldToEveryIdentifiedObject(documentTree)
        manifest = manifest.setting("document", to: documentTree)
        try manifest.encoded(pretty: true)
            .write(to: url.appendingPathComponent("manifest.json"))

        let unknownDirectory = url.appendingPathComponent("future", isDirectory: true)
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)
        let unknownData = Data("annotation payload from a future writer".utf8)
        try unknownData.write(to: unknownDirectory.appendingPathComponent("annotation.bin"))
        try bundle.writeChecksums(in: url)

        let content = try bundle.read(from: url)
        XCTAssertEqual(content.document, document)

        let rewritten = directory.appendingPathComponent("rewritten.ffp")
        try bundle.write(document: content.document, to: rewritten, preservation: content.preservation)

        let rewrittenManifest = try manifestTree(at: rewritten)
        XCTAssertEqual(
            rewrittenManifest["futureFeature"]?["note"]?.stringValue,
            "kept at the top level"
        )
        XCTAssertEqual(
            rewrittenManifest["document"]?["futureDocumentField"]?.stringValue,
            "kept"
        )
        let shank = try XCTUnwrap(
            node(named: "Shank", in: try XCTUnwrap(rewrittenManifest["document"]))
        )
        XCTAssertEqual(shank["futureNodeField"]?["note"]?.stringValue, "kept")
        let gold = try XCTUnwrap(
            object(withName: "Gold", in: try XCTUnwrap(rewrittenManifest["document"]))
        )
        XCTAssertEqual(gold["futureNodeField"]?["note"]?.stringValue, "kept")

        XCTAssertEqual(
            try Data(contentsOf: rewritten.appendingPathComponent("future/annotation.bin")),
            unknownData
        )
        XCTAssertEqual(try bundle.read(from: rewritten).document, document)
    }

    // MARK: - Integrity and versions

    func testChecksumMismatchAndFutureVersionAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tampered = directory.appendingPathComponent("tampered.ffp")
        try bundle.write(document: sampleDocument(), to: tampered, thumbnail: FFPThumbnail.png(for: sampleDocument()))
        let preview = tampered.appendingPathComponent("preview.png")
        var bytes = try Data(contentsOf: preview)
        bytes.append(0x00)
        try bytes.write(to: preview)
        XCTAssertThrowsError(try bundle.read(from: tampered)) { error in
            XCTAssertEqual(error as? FFPFormatError, .checksumMismatch("preview.png"))
        }

        let future = directory.appendingPathComponent("future.ffp")
        try bundle.write(document: sampleDocument(), to: future)
        var manifest = try manifestTree(at: future)
        manifest = manifest.setting("formatVersion", to: .int(2))
        try manifest.encoded(pretty: true)
            .write(to: future.appendingPathComponent("manifest.json"))
        try bundle.writeChecksums(in: future)
        XCTAssertThrowsError(try bundle.read(from: future)) { error in
            XCTAssertEqual(error as? FFPFormatError, .unsupportedFormatVersion(2))
        }
    }

    // MARK: - Legacy migration

    func testLegacySingleFileDocumentLoadsAndMigratesToStringBundle() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.facetforge.json")
        let document = sampleDocument()
        try document.encoded().write(to: url)

        let store = FFDocumentStore()
        let content = try store.loadContent(from: url)
        XCTAssertTrue(content.legacySingleFile)
        XCTAssertNil(content.preservation)
        XCTAssertEqual(content.document, document)

        try store.save(document, to: url)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the migrated document is a bundle")
        XCTAssertEqual(try store.load(from: url), document)
    }

    // MARK: - Fixtures and helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase25-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifestTree(at bundleURL: URL) throws -> FFPJSONValue {
        try FFPJSONValue.parse(
            Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        )
    }

    private func sampleDocument() -> FFDocument {
        let material = FFMaterial(name: "Gold")
        let mesh = FFMeshPayload(
            positions: [
                FFPoint3(x: 0, y: 0, z: 0),
                FFPoint3(x: 10, y: 0, z: 0),
                FFPoint3(x: 10, y: 10, z: 0),
                FFPoint3(x: 0, y: 10, z: 0),
                FFPoint3(x: 0, y: 0, z: 4),
                FFPoint3(x: 10, y: 0, z: 4),
                FFPoint3(x: 10, y: 10, z: 4),
                FFPoint3(x: 0, y: 10, z: 4)
            ],
            triangles: [
                FFTriangleIndex(a: 0, b: 1, c: 2), FFTriangleIndex(a: 0, b: 2, c: 3),
                FFTriangleIndex(a: 4, b: 6, c: 5), FFTriangleIndex(a: 4, b: 7, c: 6),
                FFTriangleIndex(a: 0, b: 4, c: 5), FFTriangleIndex(a: 0, b: 5, c: 1),
                FFTriangleIndex(a: 1, b: 5, c: 6), FFTriangleIndex(a: 1, b: 6, c: 2),
                FFTriangleIndex(a: 2, b: 6, c: 7), FFTriangleIndex(a: 2, b: 7, c: 3),
                FFTriangleIndex(a: 3, b: 7, c: 4), FFTriangleIndex(a: 3, b: 4, c: 0)
            ]
        )
        let curve = FFCurvePayload(
            segments: [
                FFCurveSegment(
                    kind: .bezier,
                    controlPoints: [
                        FFPoint2(x: 0, y: 0),
                        FFPoint2(x: 5, y: -3),
                        FFPoint2(x: 10, y: 0),
                        FFPoint2(x: 5, y: 3)
                    ]
                )
            ],
            isClosed: true
        )
        let shank = FFNode(
            name: "Shank",
            geometry: .mesh(mesh),
            materialID: material.id
        )
        let profile = FFNode(
            name: "Profile",
            geometry: .curve(curve),
            layerID: FFLayer.defaultLayerID
        )
        return FFDocument(
            name: "Phase 25",
            materials: [material],
            rootNodes: [FFNode(name: "Ring", children: [shank, profile])],
            layers: [.defaultLayer]
        )
    }

    /// Adds a field to every object that carries an `id`. Node, material and
    /// layer preservation are all matched by id, so one injection exercises
    /// all three.
    private func addingFutureFieldToEveryIdentifiedObject(
        _ tree: FFPJSONValue
    ) throws -> FFPJSONValue {
        switch tree {
        case .object(var values):
            if values["id"] != nil {
                values["futureNodeField"] = .object(["note": .string("kept")])
            }
            for (key, value) in values {
                values[key] = try addingFutureFieldToEveryIdentifiedObject(value)
            }
            return .object(values)
        case .array(let values):
            return .array(try values.map { try addingFutureFieldToEveryIdentifiedObject($0) })
        default:
            return tree
        }
    }

    private func node(named name: String, in tree: FFPJSONValue) -> FFPJSONValue? {
        object(withName: name, in: tree)
    }

    private func object(withName name: String, in tree: FFPJSONValue) -> FFPJSONValue? {
        if let values = tree.objectValue, values["name"]?.stringValue == name {
            return tree
        }
        switch tree {
        case .object(let values):
            for value in values.values {
                if let match = object(withName: name, in: value) { return match }
            }
        case .array(let values):
            for value in values {
                if let match = object(withName: name, in: value) { return match }
            }
        default:
            break
        }
        return nil
    }
}
