import UIKit
import XCTest
@testable import FacetForge

/// Phase 38's acceptance: an older `.ffp` file still opens with its content
/// unchanged, the next save writes the current container revision, the
/// revision's stricter reader rules refuse exactly the files version 1 would
/// have accepted silently, and a 10 000-document mutation corpus never crashes
/// and never loses a value the model understood.
final class Phase38FormatEvolutionTests: XCTestCase {
    private let store = FFDocumentStore()
    private let bundle = FFPDocumentBundle()
    private let fileManager = FileManager.default

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var legacySchemaURL: URL {
        repositoryRoot.appendingPathComponent("docs/format/ffp-1.0.schema.json")
    }

    private var currentSchemaURL: URL {
        repositoryRoot.appendingPathComponent("docs/format/ffp-2.0.schema.json")
    }

    // MARK: - Schema

    /// The version this build writes has its own frozen schema. The 1.0 schema
    /// stays normative for version-1 files and must not accept a version-2
    /// manifest, which is why the writer could not simply keep using it.
    func testTheCurrentWriterValidatesAgainstTheVersion2SchemaOnly() throws {
        let current = try FFPJSONSchemaValidator(schemaURL: currentSchemaURL)
        XCTAssertEqual(
            current.unsupportedKeywords,
            [],
            "the 2.0 schema uses keywords the validator does not implement"
        )
        let legacy = try FFPJSONSchemaValidator(schemaURL: legacySchemaURL)

        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("current.ffp")
        let document = FFDocumentTemplate.pendant.makeDocument()
        try store.save(document, to: url, thumbnail: FFPThumbnail.png(for: document))

        let manifest = try manifestTree(at: url)
        XCTAssertEqual(manifest["formatVersion"]?.intValue, FFPFormat.version)
        XCTAssertEqual(current.validate(manifest), [], "a real version-2 manifest failed its own schema")
        XCTAssertFalse(
            legacy.validate(manifest).isEmpty,
            "the frozen 1.0 schema accepted a version-2 manifest"
        )

        let legacyCopy = directory.appendingPathComponent("legacy.ffp")
        try FFPFormatMigration.writingVersion1Copy(of: url, to: legacyCopy)
        let legacyManifest = try manifestTree(at: legacyCopy)
        XCTAssertEqual(legacy.validate(legacyManifest), [], "the 1.0 schema stopped accepting version-1 files")
        XCTAssertFalse(current.validate(legacyManifest).isEmpty)
    }

    // MARK: - Opening an older file

    /// The row's first promise: a version-1 file opens, and its content keeps
    /// its meaning. The only difference between the two manifests is the
    /// version field — the document member is byte-identical, so the state hash
    /// cannot move for a format-version reason.
    func testAVersion1BundleOpensWithItsContentUnchanged() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let currentURL = directory.appendingPathComponent("current.ffp")
        let legacyURL = directory.appendingPathComponent("legacy.ffp")
        let document = FFDocumentTemplate.pendant.makeDocument()
        let thumbnail = try XCTUnwrap(FFPThumbnail.png(for: document))
        try store.save(document, to: currentURL, thumbnail: thumbnail)
        try FFPFormatMigration.writingVersion1Copy(of: currentURL, to: legacyURL)

        let currentTree = try manifestTree(at: currentURL)
        let legacyTree = try manifestTree(at: legacyURL)
        XCTAssertEqual(legacyTree["formatVersion"]?.intValue, 1)
        let currentDocumentBytes = try XCTUnwrap(currentTree["document"]).encoded()
        let legacyDocumentBytes = try XCTUnwrap(legacyTree["document"]).encoded()
        XCTAssertEqual(
            currentDocumentBytes,
            legacyDocumentBytes,
            "the version-1 copy rewrote the document body instead of only the version"
        )

        let content = try store.loadContent(from: legacyURL)
        XCTAssertEqual(content.document, document)
        XCTAssertEqual(content.document.stateHash, document.stateHash)
        XCTAssertEqual(
            content.document.schemaVersion,
            FFDocument.currentSchemaVersion,
            "the document model did not change, so its schema version must not either"
        )
        XCTAssertNil(content.recovery)
        XCTAssertEqual(content.thumbnail, thumbnail)

        let migration = try XCTUnwrap(
            content.migration,
            "a version-1 file was read without a migration report"
        )
        XCTAssertEqual(migration.from, 1)
        XCTAssertEqual(migration.to, FFPFormat.version)
        XCTAssertEqual(migration.steps.map(\.to), [2])
        XCTAssertTrue(migration.headline.contains("format 1"))
    }

    /// The upgrade path: reading a version-1 file and saving it writes version
    /// 2 with full checksum coverage, without moving the document or dropping
    /// what the reader promised to preserve.
    func testSavingAVersion1BundleUpgradesItWithoutMovingTheDocument() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let currentURL = directory.appendingPathComponent("current.ffp")
        let legacyURL = directory.appendingPathComponent("legacy.ffp")
        let upgradedURL = directory.appendingPathComponent("upgraded.ffp")
        let document = FFDocumentTemplate.signet.makeDocument()
        let thumbnail = try XCTUnwrap(FFPThumbnail.png(for: document))
        try store.save(document, to: currentURL, thumbnail: thumbnail)
        try FFPFormatMigration.writingVersion1Copy(of: currentURL, to: legacyURL)

        // A future minor writer's field and file, which a migration must not
        // drop even though this version does not understand them.
        var legacyManifest = try manifestTree(at: legacyURL)
        legacyManifest = legacyManifest.setting("futureFeature", to: .string("kept"))
        try legacyManifest.encoded(pretty: true)
            .write(to: legacyURL.appendingPathComponent(FFPFormat.manifestName))
        try FileManager.default.createDirectory(
            at: legacyURL.appendingPathComponent("future", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("annotation from a newer writer".utf8)
            .write(to: legacyURL.appendingPathComponent("future/annotation.bin"))
        try bundle.writeChecksums(in: legacyURL)

        let legacyDocumentBytes = try XCTUnwrap(legacyManifest["document"]).encoded()
        let opened = try store.loadContent(from: legacyURL)
        XCTAssertNotNil(opened.migration)

        try store.save(
            opened.document,
            to: upgradedURL,
            preservation: opened.preservation,
            thumbnail: opened.thumbnail
        )

        let upgraded = try manifestTree(at: upgradedURL)
        XCTAssertEqual(upgraded["formatVersion"]?.intValue, FFPFormat.version)
        XCTAssertEqual(upgraded["documentVersion"]?.intValue, document.schemaVersion)
        let upgradedDocumentBytes = try XCTUnwrap(upgraded["document"]).encoded()
        XCTAssertEqual(
            upgradedDocumentBytes,
            legacyDocumentBytes,
            "the upgrade rewrote the document body"
        )
        XCTAssertEqual(upgraded["futureFeature"]?.stringValue, "kept")
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: upgradedURL.appendingPathComponent("future/annotation.bin").path
            ),
            "the upgrade dropped an unknown bundle file"
        )

        let checksums = try FFPJSONValue.parse(
            Data(contentsOf: upgradedURL.appendingPathComponent(FFPFormat.checksumsName))
        )
        let listed = Set(
            (checksums["files"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
        )
        XCTAssertTrue(
            listed.contains(FFPFormat.manifestName),
            "a version-2 save must cover the manifest it just wrote"
        )
        XCTAssertTrue(listed.contains(FFPFormat.thumbnailName))

        let reloaded = try store.loadContent(from: upgradedURL)
        XCTAssertEqual(reloaded.document.stateHash, document.stateHash)
        XCTAssertNil(reloaded.migration, "a version-2 file reported a migration")
        XCTAssertNil(reloaded.recovery)
    }

    // MARK: - The rules version 2 adds

    /// Version 1 verified whatever entries `checksums.json` happened to list.
    /// A manifest whose bytes changed *and* whose entry was removed therefore
    /// loaded silently as a different document. Version 2 requires coverage.
    func testVersion2RefusesAManifestThatChecksumsDoNotCover() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let currentURL = directory.appendingPathComponent("current.ffp")
        let legacyURL = directory.appendingPathComponent("legacy.ffp")
        let document = FFDocumentTemplate.pendant.makeDocument()
        try store.save(document, to: currentURL, thumbnail: FFPThumbnail.png(for: document))
        try FFPFormatMigration.writingVersion1Copy(of: currentURL, to: legacyURL)

        try renamingDocument("Silently Altered", in: legacyURL)
        try droppingChecksumEntry(FFPFormat.manifestName, in: legacyURL)

        // Version 1 rules: the altered body is accepted, and the report is the
        // only signal that the file is old. This is the hole, stated plainly.
        let lenient = try bundle.read(from: legacyURL)
        XCTAssertEqual(lenient.document.name, "Silently Altered")
        XCTAssertNotNil(lenient.migration)

        // The same bytes declared as version 2 must be refused, with a reason.
        try settingFormatVersion(FFPFormat.version, in: legacyURL)
        XCTAssertThrowsError(try bundle.read(from: legacyURL)) { error in
            XCTAssertEqual(error as? FFPFormatError, .unlistedEntry(FFPFormat.manifestName))
            XCTAssertTrue(
                (error as? FFPFormatError)?.allowsLastGoodRecovery == true,
                "an uncovered manifest is damage and should consult the last good save"
            )
            XCTAssertFalse(
                (error as? FFPFormatError)?.recoveryDescription.isEmpty ?? true,
                "the refusal does not explain itself"
            )
        }

        // Re-signing the bytes makes the same bundle readable again: the rule
        // is about coverage, not about what the document says.
        try bundle.writeChecksums(in: legacyURL)
        let covered = try bundle.read(from: legacyURL)
        XCTAssertEqual(covered.document.name, "Silently Altered")
        XCTAssertNil(covered.migration)
    }

    /// A geometry reference no node answers silently dropped its block in
    /// version 1. Version 2 refuses it rather than losing the solid.
    func testVersion2RefusesAGeometryReferenceWithNoNode() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let url = directory.appendingPathComponent("dangling.ffp")
        let document = FFDocumentTemplate.pendant.makeDocument()
        XCTAssertGreaterThan(document.meshNodeCount, 0)
        try store.save(document, to: url, thumbnail: FFPThumbnail.png(for: document))

        let manifest = try manifestTree(at: url)
        let documentTree = try XCTUnwrap(manifest["document"])
        XCTAssertFalse(
            (manifest["geometry"]?["nodes"]?.arrayValue ?? []).isEmpty,
            "the fixture has no geometry table to damage"
        )

        // Empty the tree but keep the geometry table: every reference dangles.
        try manifest
            .setting("document", to: documentTree.setting("rootNodes", to: .array([])))
            .encoded(pretty: true)
            .write(to: url.appendingPathComponent(FFPFormat.manifestName))
        try bundle.writeChecksums(in: url)

        XCTAssertThrowsError(try bundle.read(from: url)) { error in
            guard let formatError = error as? FFPFormatError,
                  case .danglingGeometryReference = formatError else {
                return XCTFail("expected a dangling reference, got \(error)")
            }
            XCTAssertFalse(
                formatError.recoveryDescription.isEmpty,
                "the refusal does not explain itself"
            )
        }

        // Version 1 opened the same bytes, which is why the rule is gated on
        // the declared revision instead of applied to every file.
        try settingFormatVersion(1, in: url)
        try bundle.writeChecksums(in: url)
        let lenient = try bundle.read(from: url)
        XCTAssertEqual(lenient.document.nodeCount, 0)
        XCTAssertNotNil(lenient.migration)
    }

    /// A file from a newer container revision is refused before it replaces
    /// any state, and never masked by the last good save.
    func testAFutureFormatVersionIsRefusedWithoutFallback() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let url = directory.appendingPathComponent("future.ffp")
        let document = FFDocument(name: "Future")
        try store.save(document, to: url)
        try settingFormatVersion(FFPFormat.version + 1, in: url)
        try bundle.writeChecksums(in: url)

        XCTAssertThrowsError(try store.loadContent(from: url)) { error in
            XCTAssertEqual(
                error as? FFPFormatError,
                .unsupportedFormatVersion(FFPFormat.version + 1)
            )
            XCTAssertFalse(
                (error as? FFPFormatError)?.allowsLastGoodRecovery == true,
                "a newer file must not be replaced by an older save"
            )
        }
    }

    // MARK: - The ladder

    /// The ladder is the harness: one ordered table, a report that names every
    /// step it applied, and no body rewrite for 1 → 2 because that revision
    /// changed the container.
    func testTheMigrationLadderReportsEveryStepItApplies() throws {
        XCTAssertEqual(try FFPFormatMigration.steps(from: FFPFormat.version), [])
        XCTAssertNil(try FFPFormatMigration.report(from: FFPFormat.version))

        let steps = try FFPFormatMigration.steps(from: 1)
        XCTAssertEqual(steps.map(\.from), [1])
        XCTAssertEqual(steps.map(\.to), [2])
        XCTAssertFalse(steps[0].summary.isEmpty)

        let report = try XCTUnwrap(FFPFormatMigration.report(from: 1))
        XCTAssertEqual(report.steps, steps)
        XCTAssertTrue(report.summary.contains(steps[0].summary))

        let tree = FFPJSONValue.object(["schemaVersion": .int(1), "name": .string("Ladder")])
        let migrated = try FFPFormatMigration.migrate(documentTree: tree, from: 1)
        XCTAssertEqual(try migrated.tree.encoded(), try tree.encoded())
        XCTAssertEqual(migrated.report?.steps, steps)

        XCTAssertThrowsError(try FFPFormatMigration.steps(from: FFPFormat.version + 1)) { error in
            XCTAssertEqual(
                error as? FFPFormatError,
                .unsupportedFormatVersion(FFPFormat.version + 1)
            )
        }
        XCTAssertThrowsError(try FFPFormatMigration.steps(from: 0)) { error in
            guard let formatError = error as? FFPFormatError,
                  case .malformedManifest(let detail) = formatError else {
                return XCTFail("expected a malformed manifest, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty, "the refusal has no detail")
        }
    }

    // MARK: - The corpus

    /// The row's CI clause. Ten thousand deterministic mutations of three real
    /// documents, run in-process so the corpus costs seconds rather than
    /// megabytes of checked-in fixtures. A crash anywhere kills the test
    /// process, so surviving the loop is the no-crash proof.
    func testTenThousandMutatedDocumentsNeverCrashOrLoseDataSilently() throws {
        // Small but complete documents: every container the model owns, and an
        // eight-triangle mesh rather than a production ring, so ten thousand
        // cases cost seconds instead of minutes.
        let baseData = try corpusBases().map { try $0.encoded() }
        var generator = SplitMix64(seed: 0x5EED_0038)
        var accepted = 0
        var rejections: [String] = []
        var samples: [String] = []
        var slowest: TimeInterval = 0
        let started = Date()
        let caseCount = 10_000

        for index in 0..<caseCount {
            let baseIndex = Int(generator.next() % UInt64(baseData.count))
            let base = try FFPJSONValue.parse(baseData[baseIndex])
            let rounds = 1 + Int(generator.next() % 3)
            let mutant = mutate(base, with: &generator, rounds: rounds)
            let data = try mutant.encoded()

            let caseStart = Date()
            do {
                let document = try FFDocument.decoded(from: data)
                accepted += 1

                // Reading a decoded document back must not change it.
                let again = try FFDocument.decoded(from: try document.encoded())
                XCTAssertEqual(again, document, "case \(index): a second read changed the document")
                XCTAssertEqual(
                    again.stateHash,
                    document.stateHash,
                    "case \(index): a second read changed the state hash"
                )

                // Nothing the mutant declared may vanish. Layers are excluded
                // because an absent layer list is a documented default.
                XCTAssertEqual(
                    document.materials.count,
                    declaredMaterials(mutant),
                    "case \(index): materials were dropped"
                )
                XCTAssertEqual(
                    document.nodeCount,
                    declaredNodes(mutant),
                    "case \(index): nodes were dropped"
                )
                XCTAssertFalse(document.layers.isEmpty, "case \(index): the layer list is empty")
            } catch {
                let reason = describe(error)
                XCTAssertFalse(reason.isEmpty, "case \(index) was refused without a reason")

                switch error {
                case is FFDocumentError:
                    XCTAssertNotNil(
                        (error as? FFDocumentError)?.errorDescription,
                        "case \(index): a typed rejection has no explanation"
                    )
                case let decoding as DecodingError:
                    XCTAssertFalse(
                        describe(decoding).isEmpty,
                        "case \(index): a decoding rejection has no explanation"
                    )
                default:
                    XCTFail("case \(index) was refused by an unexplained error: \(error)")
                }

                rejections.append(reason)
                if samples.count < 12 {
                    samples.append("case \(index): \(reason)")
                }
            }
            slowest = max(slowest, Date().timeIntervalSince(caseStart))
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(accepted + rejections.count, caseCount)
        XCTAssertGreaterThan(accepted, 0, "the corpus never produced a document the model accepts")
        XCTAssertGreaterThan(rejections.count, 0, "the corpus never produced a rejection")
        XCTAssertGreaterThan(
            Set(rejections).count,
            5,
            "every rejection reported the same reason, so the corpus is not reaching the model"
        )

        let summary = """
        Phase 38 corpus
        cases: \(caseCount)
        accepted: \(accepted)
        rejected: \(rejections.count)
        distinct rejection reasons: \(Set(rejections).count)
        elapsed: \(String(format: "%.2f", elapsed)) s
        slowest case: \(String(format: "%.4f", slowest * 1000)) ms
        first rejection reasons:
        \(samples.joined(separator: "\n"))
        """
        let attachment = XCTAttachment(
            data: Data(summary.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = "phase38-corpus"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThan(
            elapsed,
            120,
            "the corpus took \(String(format: "%.1f", elapsed)) s; it must stay inside the unit budget"
        )
    }

    // MARK: - Mutation corpus

    /// Three small documents that together carry every container the model
    /// writes: materials with presets, layers and layer sets, node hierarchy,
    /// pivots, face groups, measurements and metadata.
    private func corpusBases() throws -> [FFDocument] {
        let gold = FFMaterial(name: "Gold", preset: .yellowGold18K)
        let gem = FFMaterial(
            name: "Gem",
            baseColor: FFRGBA(red: 0.52, green: 0.84, blue: 0.96),
            metallic: 0.05,
            roughness: 0.08
        )
        let metal = FFLayer(name: "Metal", color: .gold)
        let stones = FFLayer(name: "Stones", color: FFRGBA(red: 0.46, green: 0.82, blue: 0.96))
        let mesh = try XCTUnwrap(FFMeshFactory.octahedron(radius: 4))

        let stone = FFNode(
            name: "Stone",
            geometry: .mesh(FFMeshPayload(mesh)),
            materialID: gem.id,
            kind: .stone,
            layerID: stones.id,
            faceGroups: [
                FFFaceGroup(name: "Table", materialID: gold.id, triangles: [0, 2, 4])
            ]
        )
        let band = FFNode(
            name: "Band",
            geometry: .mesh(FFMeshPayload(mesh)),
            materialID: gold.id,
            kind: .solid,
            layerID: metal.id,
            pivot: FFPoint3(x: 1, y: 2, z: 3)
        )
        let assembly = FFNode(name: "Ring", children: [band, stone])

        return [
            FFDocument(name: "Empty"),
            FFDocument(
                name: "Structured",
                materials: [gold, gem],
                rootNodes: [assembly],
                layers: [metal, stones],
                currentLayerID: metal.id,
                metadata: FFMetadata(
                    partNumber: "P-1",
                    sku: "SKU-1",
                    itemDescription: "Octahedron ring",
                    workshopNotes: "Fuzz base",
                    manufacturingFlags: [.casting]
                )
            ),
            FFDocument(name: "Layers", layers: [metal, stones], currentLayerID: metal.id)
        ]
    }

    // MARK: - Mutation helpers

    private enum PathStep: Hashable {
        case key(String)
        case index(Int)
    }

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private func mutate(
        _ tree: FFPJSONValue,
        with generator: inout SplitMix64,
        rounds: Int
    ) -> FFPJSONValue {
        var current = tree
        for _ in 0..<rounds {
            var paths: [[PathStep]] = []
            collectPaths(in: current, into: &paths)
            guard !paths.isEmpty else { return current }
            let path = paths[Int(generator.next() % UInt64(paths.count))]
            let target = value(in: current, at: path)

            switch generator.next() % 5 {
            case 0:
                let replacement = wrongType(looking: target, generator: &generator)
                current = replacing(current, at: path) { _ in replacement }
            case 1:
                current = removing(current, at: path)
            case 2:
                if case .array(let items) = target, !items.isEmpty {
                    let item = items[Int(generator.next() % UInt64(items.count))]
                    current = replacing(current, at: path) { existing in
                        .array((existing.arrayValue ?? []) + [item])
                    }
                }
            case 3:
                if target.objectValue != nil {
                    current = replacing(current, at: path) { existing in
                        existing.setting("phase38Unknown", to: .string("kept"))
                    }
                }
            default:
                if case .string = target {
                    current = replacing(current, at: path) { _ in .string("") }
                }
            }
        }
        return current
    }

    private func collectPaths(
        in value: FFPJSONValue,
        prefix: [PathStep] = [],
        into result: inout [[PathStep]]
    ) {
        result.append(prefix)
        switch value {
        case .object(let values):
            // Sorted keys keep the corpus reproducible: Swift dictionary order
            // is seeded per instance, so an unsorted walk would make the seed
            // describe a different corpus on every launch.
            for (key, child) in values.sorted(by: { $0.key < $1.key }) where key != "phase38Unknown" {
                collectPaths(in: child, prefix: prefix + [.key(key)], into: &result)
            }
        case .array(let items):
            for (index, child) in items.enumerated() {
                collectPaths(in: child, prefix: prefix + [.index(index)], into: &result)
            }
        default:
            break
        }
    }

    private func value(in tree: FFPJSONValue, at path: [PathStep]) -> FFPJSONValue {
        var current = tree
        for step in path {
            switch step {
            case .key(let key):
                guard let next = current[key] else { return .null }
                current = next
            case .index(let index):
                guard case .array(let items) = current, items.indices.contains(index) else {
                    return .null
                }
                current = items[index]
            }
        }
        return current
    }

    private func replacing(
        _ tree: FFPJSONValue,
        at path: [PathStep],
        with transform: (FFPJSONValue) -> FFPJSONValue
    ) -> FFPJSONValue {
        guard let step = path.first else { return transform(tree) }
        let rest = Array(path.dropFirst())
        switch step {
        case .key(let key):
            guard case .object(var values) = tree, let child = values[key] else { return tree }
            values[key] = replacing(child, at: rest, with: transform)
            return .object(values)
        case .index(let index):
            guard case .array(var items) = tree, items.indices.contains(index) else { return tree }
            items[index] = replacing(items[index], at: rest, with: transform)
            return .array(items)
        }
    }

    private func removing(_ tree: FFPJSONValue, at path: [PathStep]) -> FFPJSONValue {
        guard let step = path.first else { return tree }
        let rest = Array(path.dropFirst())
        switch step {
        case .key(let key):
            if rest.isEmpty {
                return tree.removing(key)
            }
            guard case .object(var values) = tree, let child = values[key] else { return tree }
            values[key] = removing(child, at: rest)
            return .object(values)
        case .index(let index):
            guard case .array(var items) = tree, items.indices.contains(index) else { return tree }
            if rest.isEmpty {
                items.remove(at: index)
                return .array(items)
            }
            items[index] = removing(items[index], at: rest)
            return .array(items)
        }
    }

    private func wrongType(looking value: FFPJSONValue, generator: inout SplitMix64) -> FFPJSONValue {
        let candidates: [FFPJSONValue] = [
            .string(""),
            .int(-1),
            .double(0.5),
            .bool(true),
            .null,
            .array([]),
            .object([:])
        ]
        let candidate = candidates[Int(generator.next() % UInt64(candidates.count))]
        return candidate == value ? .string("phase38") : candidate
    }

    private func declaredNodes(_ tree: FFPJSONValue) -> Int {
        func count(_ node: FFPJSONValue) -> Int {
            guard case .object(let values) = node else { return 0 }
            return 1 + (values["children"]?.arrayValue ?? []).reduce(0) { $0 + count($1) }
        }
        return (tree["rootNodes"]?.arrayValue ?? []).reduce(0) { $0 + count($1) }
    }

    private func declaredMaterials(_ tree: FFPJSONValue) -> Int {
        tree["materials"]?.arrayValue?.count ?? 0
    }

    private func describe(_ error: Error) -> String {
        if let documentError = error as? FFDocumentError {
            return documentError.errorDescription ?? String(describing: documentError)
        }
        if let formatError = error as? FFPFormatError {
            return formatError.recoveryDescription
        }
        guard let decoding = error as? DecodingError else {
            return String(describing: error)
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(codingPath(context))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(codingPath(context)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "no value for \(type) at \(codingPath(context))"
        case .dataCorrupted(let context):
            return "corrupt value at \(codingPath(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: decoding)
        }
    }

    private func codingPath(_ context: DecodingError.Context) -> String {
        context.codingPath
            .map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }
            .joined(separator: ".")
    }

    // MARK: - Bundle helpers

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase38-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifestTree(at url: URL) throws -> FFPJSONValue {
        try FFPJSONValue.parse(
            Data(contentsOf: url.appendingPathComponent(FFPFormat.manifestName))
        )
    }

    private func settingFormatVersion(_ version: Int, in bundle: URL) throws {
        let url = bundle.appendingPathComponent(FFPFormat.manifestName)
        let manifest = try FFPJSONValue.parse(Data(contentsOf: url))
        try manifest.setting("formatVersion", to: .int(version))
            .encoded(pretty: true)
            .write(to: url)
    }

    private func renamingDocument(_ name: String, in bundle: URL) throws {
        let url = bundle.appendingPathComponent(FFPFormat.manifestName)
        let manifest = try FFPJSONValue.parse(Data(contentsOf: url))
        let document = (manifest["document"] ?? .object([:]))
            .setting("name", to: .string(name))
        try manifest.setting("document", to: document)
            .encoded(pretty: true)
            .write(to: url)
    }

    private func droppingChecksumEntry(_ path: String, in bundle: URL) throws {
        let url = bundle.appendingPathComponent(FFPFormat.checksumsName)
        let checksums = try FFPJSONValue.parse(Data(contentsOf: url))
        let files = (checksums["files"]?.arrayValue ?? [])
            .filter { $0["path"]?.stringValue != path }
        try checksums.setting("files", to: .array(files))
            .encoded(pretty: true)
            .write(to: url)
    }
}
