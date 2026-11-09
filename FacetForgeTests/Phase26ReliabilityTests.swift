import XCTest
@testable import FacetForge

/// Phase 26's acceptance: repeated save/load at scale is exact, and a damaged
/// primary bundle falls back to the last good save with an error that names
/// what went wrong.
final class Phase26ReliabilityTests: XCTestCase {
    private let store = FFDocumentStore()

    // MARK: - Scale

    func testThreeSaveLoadCyclesKeepAThousandObjectDocumentIdentical() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var document = thousandObjectDocument()
        XCTAssertEqual(document.nodeCount, 1_000)
        XCTAssertEqual(document.meshNodeCount, 500)
        XCTAssertEqual(document.curveNodeCount, 500)
        let originalHash = document.stateHash
        XCTAssertFalse(originalHash.isEmpty)

        let url = directory.appendingPathComponent("soak.ffp")
        for cycle in 0..<3 {
            try store.save(document, to: url)
            let loaded = try store.load(from: url)
            XCTAssertEqual(
                loaded.stateHash,
                originalHash,
                "save/load cycle \(cycle + 1) changed the thousand-object document"
            )
            XCTAssertEqual(loaded.nodeCount, 1_000)
            document = loaded
        }

        let previous = FFPDocumentBundle.previousURL(for: url)
        XCTAssertTrue(isDirectory(previous), "the last good save was not kept")
        XCTAssertEqual(try store.load(from: previous).stateHash, originalHash)
    }

    // MARK: - Recovery

    func testTruncatedBundleFallsBackToTheLastGoodSaveWithAClearMessage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ring.ffp")

        var first = sampleDocument(name: "First")
        try store.save(first, to: url)
        var second = first
        second.name = "Second"
        try store.save(second, to: url)
        XCTAssertEqual(try store.load(from: url).name, "Second")

        let geometryURL = url.appendingPathComponent("geometry/geometry-000.bin")
        let bytes = try Data(contentsOf: geometryURL)
        XCTAssertGreaterThan(bytes.count, 8)
        try Data(bytes.prefix(bytes.count - 8)).write(to: geometryURL)

        let content = try store.loadContent(from: url)
        XCTAssertEqual(content.document.name, "First", "the damaged bundle was served instead of the previous")
        XCTAssertEqual(content.document.stateHash, first.stateHash)
        let notice = try XCTUnwrap(content.recovery, "a recovered read must carry a notice")
        XCTAssertTrue(
            notice.message.contains("Recovered the last good save"),
            "the message does not say what happened: \(notice.message)"
        )
        XCTAssertTrue(
            notice.message.contains("checksum mismatch for geometry/geometry-000.bin"),
            "the message does not name the damaged entry: \(notice.message)"
        )
        XCTAssertEqual(notice.damagedEntry, "geometry/geometry-000.bin")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "a read must leave the damaged bundle in place"
        )
        XCTAssertEqual(try store.load(from: url).name, "First")
    }

    func testDamageWithoutAPreviousSaveSurfacesTheIntegrityError() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lonely.ffp")
        try store.save(sampleDocument(name: "Lonely"), to: url)

        let geometryURL = url.appendingPathComponent("geometry/geometry-000.bin")
        let bytes = try Data(contentsOf: geometryURL)
        try Data(bytes.prefix(bytes.count - 4)).write(to: geometryURL)

        XCTAssertThrowsError(try store.load(from: url)) { error in
            XCTAssertEqual(
                error as? FFPFormatError,
                .checksumMismatch("geometry/geometry-000.bin"),
                "a read without a previous save must report the damage"
            )
        }
    }

    func testANewerFormatVersionNeverFallsBackToThePreviousSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("future.ffp")

        try store.save(sampleDocument(name: "Older"), to: url)
        try store.save(sampleDocument(name: "Newer"), to: url)

        var manifest = try FFPJSONValue.parse(
            Data(contentsOf: url.appendingPathComponent("manifest.json"))
        )
        manifest = manifest.setting("formatVersion", to: .int(FFPFormat.version + 1))
        try manifest.encoded(pretty: true)
            .write(to: url.appendingPathComponent("manifest.json"))
        try FFPDocumentBundle().writeChecksums(in: url)

        XCTAssertThrowsError(try store.load(from: url)) { error in
            XCTAssertEqual(
                error as? FFPFormatError,
                .unsupportedFormatVersion(FFPFormat.version + 1),
                "a newer bundle must not be silently downgraded to the previous save"
            )
        }
    }

    // MARK: - Files left behind

    func testSaveLeavesNoTemporaryBundlesAndKeepsAReadablePrevious() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clean.ffp")

        try store.save(sampleDocument(name: "One"), to: url)
        try store.save(sampleDocument(name: "Two"), to: url)

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(
            entries.contains { $0.contains(".tmp") },
            "a completed save left a temporary bundle: \(entries)"
        )
        let previousName = FFPDocumentBundle.previousURL(for: url).lastPathComponent
        XCTAssertTrue(entries.contains(previousName), "the previous slot is missing: \(entries)")
        XCTAssertEqual(try store.load(from: FFPDocumentBundle.previousURL(for: url)).name, "One")
    }

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase26-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    private func sampleDocument(name: String) -> FFDocument {
        let material = FFMaterial(name: "Gold")
        let mesh = FFMeshPayload(
            positions: [
                FFPoint3(x: 0, y: 0, z: 0),
                FFPoint3(x: 10, y: 0, z: 0),
                FFPoint3(x: 10, y: 10, z: 0),
                FFPoint3(x: 0, y: 10, z: 0)
            ],
            triangles: [
                FFTriangleIndex(a: 0, b: 1, c: 2),
                FFTriangleIndex(a: 0, b: 2, c: 3)
            ]
        )
        return FFDocument(
            name: name,
            materials: [material],
            rootNodes: [
                FFNode(name: "Plate", geometry: .mesh(mesh), materialID: material.id)
            ]
        )
    }

    /// The row's 1 000-object fixture, generated deterministically: 500 meshes
    /// and 500 Bézier curves, each with real geometry so the binary buffer path
    /// is exercised at scale rather than 1 000 empty nodes.
    private func thousandObjectDocument() -> FFDocument {
        var nodes: [FFNode] = []
        nodes.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let offset = Double(index) * 0.25
            let transform = FFTransform(
                translation: FFPoint3(x: offset, y: 0, z: 0),
                rotation: FFPoint3(x: 0, y: 0, z: 0),
                scale: FFPoint3(x: 1, y: 1, z: 1)
            )
            if index.isMultiple(of: 2) {
                let mesh = FFMeshPayload(
                    positions: [
                        FFPoint3(x: 0, y: 0, z: 0),
                        FFPoint3(x: 1, y: 0, z: 0),
                        FFPoint3(x: 1, y: 1, z: 0),
                        FFPoint3(x: 0, y: 1, z: 0)
                    ],
                    triangles: [
                        FFTriangleIndex(a: 0, b: 1, c: 2),
                        FFTriangleIndex(a: 0, b: 2, c: 3)
                    ]
                )
                nodes.append(FFNode(
                    name: "Mesh \(index)",
                    transform: transform,
                    geometry: .mesh(mesh)
                ))
            } else {
                let curve = FFCurvePayload(
                    segments: [
                        FFCurveSegment(
                            kind: .bezier,
                            controlPoints: [
                                FFPoint2(x: 0, y: 0),
                                FFPoint2(x: 1, y: 1),
                                FFPoint2(x: 2, y: 0)
                            ]
                        )
                    ]
                )
                nodes.append(FFNode(
                    name: "Curve \(index)",
                    transform: transform,
                    geometry: .curve(curve)
                ))
            }
        }
        return FFDocument(name: "Thousand objects", rootNodes: nodes)
    }
}
