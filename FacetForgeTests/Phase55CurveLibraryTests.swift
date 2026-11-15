import XCTest
@testable import FacetForge

/// Phase 55: a saved curve is the document's own payload, not a sampled copy.
///
/// Every exactness assertion here rests on a stated premise: `FFCurvePayload` is
/// `Codable` with plain `Double` fields, and Swift's JSON encoder writes a
/// Double in the shortest form that reads back to the same bits. A payload that
/// survives a write and a fresh read therefore compares equal with no accuracy
/// argument, and that is the assertion — a tolerance would hide exactly the
/// drift the row forbids.
final class Phase55CurveLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase55Curves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Persistence

    func testASavedCurveReadsBackExactlyFromAFreshLibrary() throws {
        let payload = samplePayload()
        // The premise every equality below rests on: the fixture is a curve the
        // kernel can rebuild, not merely numbers that echo back. A NURBS with
        // the wrong knot count would satisfy an equality and still be nothing.
        XCTAssertNotNil(payload.path(), "the fixture must be a valid curve")
        let saved = try FFCurveLibrary(directory: directory)
            .save(payload, name: "  Scroll  ", tags: [" scroll ", "Ring"])

        XCTAssertEqual(saved.name, "Scroll", "the typed name is trimmed, not rewritten")
        XCTAssertEqual(saved.tags, ["scroll", "Ring"])

        // A second instance reads only the file, which is what a relaunch does.
        let reopened = FFCurveLibrary(directory: directory)
        let entries = reopened.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first, saved, "a re-read entry must equal the one that was written")
        XCTAssertEqual(entries.first?.payload, payload)
        XCTAssertEqual(entries.first?.payload.segments.count, 3)
    }

    func testTheSelectedCurveIsSavedAndInsertedWithTheSameGeometryAndOneUndo() throws {
        let payload = samplePayload()
        var sourceDocument = FFDocument(name: "Source")
        sourceDocument.rootNodes.append(FFNode(
            name: "Source curve",
            geometry: .curve(payload),
            kind: .curve,
            layerID: sourceDocument.currentLayerID
        ))
        let nodeID = sourceDocument.rootNodes[0].id
        let source = FFEditorSession(document: sourceDocument)
        source.curveLibraryDirectoryOverride = directory
        source.selection.select([nodeID])

        XCTAssertTrue(source.saveSelectedCurveToLibrary(name: "Wave 1", tags: "scroll, ring"))
        XCTAssertEqual(source.curveLibraryEntries.count, 1)
        let saved = try XCTUnwrap(source.curveLibraryEntries.first)
        XCTAssertEqual(saved.payload, payload)

        // A different session inserts it: the target document starts empty, so
        // any curve it holds came from the file.
        let target = FFEditorSession(document: FFDocument(name: "Target"))
        target.curveLibraryDirectoryOverride = directory
        let insertedID = try XCTUnwrap(target.insertLibraryCurve(saved.id))
        let inserted = try XCTUnwrap(target.rootNodes.first { $0.id == insertedID })
        XCTAssertEqual(inserted.geometry?.curve, payload, "the inserted curve is the saved curve")
        XCTAssertEqual(
            inserted.geometry?.curve?.path(),
            payload.path(),
            "both payloads rebuild the same kernel path"
        )

        let segments = try XCTUnwrap(inserted.geometry?.curve?.segments)
        XCTAssertEqual(segments[0].kind, .bezier)
        XCTAssertEqual(segments[1].kind, .nurbs)
        XCTAssertEqual(segments[1].weights, [1, 0.75, 1])
        XCTAssertEqual(segments[1].degree, 2)
        // degree 2 over 3 control points needs 3 + 2 + 1 = 6 knots, clamped at
        // both ends; the kernel rejects any other count, so this asserts the
        // only vector that can rebuild a quadratic.
        XCTAssertEqual(segments[1].knots, [0, 0, 0, 1, 1, 1])

        XCTAssertEqual(target.documentSession.undoDepth, 1, "an insert is exactly one undo step")
        XCTAssertTrue(target.undo())
        XCTAssertTrue(target.rootNodes.isEmpty, "one undo removes the inserted curve")
        XCTAssertEqual(target.documentSession.undoDepth, 0)

        // The library still holds the entry: inserting copies it.
        XCTAssertEqual(FFCurveLibrary(directory: directory).entries().count, 1)
    }

    // MARK: - Beyond the old cap

    /// The card used to render `entries.prefix(8)`, so a ninth saved curve was
    /// written to disk and then unreachable. Fifteen saves stay one list, the
    /// ninth and fifteenth entries insert through the same command a tap uses,
    /// and each insert is exactly one undo.
    func testTheNinthAndFifteenthSavedCurvesInsertAndUndoIndividually() throws {
        let payload = samplePayload()
        var document = FFDocument(name: "Many curves")
        document.rootNodes.append(FFNode(
            name: "Source curve",
            geometry: .curve(payload),
            kind: .curve,
            layerID: document.currentLayerID
        ))
        let source = FFEditorSession(document: document)
        source.curveLibraryDirectoryOverride = directory
        source.selection.select([document.rootNodes[0].id])

        for index in 1...15 {
            XCTAssertTrue(
                source.saveSelectedCurveToLibrary(name: String(format: "Curve %02d", index), tags: ""),
                "save \(index) of 15 was refused"
            )
        }
        XCTAssertEqual(source.curveLibraryEntries.count, 15)
        XCTAssertEqual(FFCurveLibrary(directory: directory).entries().count, 15)

        // Index 14 is the fifteenth entry in the card's own order, not a
        // synthetic list: the same ids a row's Insert chip passes.
        let fifteenth = source.curveLibraryEntries[14]
        let ninth = source.curveLibraryEntries[8]
        XCTAssertEqual(fifteenth.name, "Curve 01")
        XCTAssertEqual(ninth.name, "Curve 07")

        let insertedFifteenth = try XCTUnwrap(source.insertLibraryCurve(fifteenth.id))
        XCTAssertEqual(source.documentSession.undoDepth, 1, "an insert is one undo step")
        XCTAssertEqual(
            source.documentSession.document.node(withID: insertedFifteenth)?.geometry?.curve,
            payload,
            "the inserted curve is the saved curve, not a copy the session made"
        )
        XCTAssertTrue(source.undo())
        XCTAssertNil(source.documentSession.document.node(withID: insertedFifteenth))
        XCTAssertEqual(source.documentSession.undoDepth, 0)

        let insertedNinth = try XCTUnwrap(source.insertLibraryCurve(ninth.id))
        XCTAssertNotNil(source.documentSession.document.node(withID: insertedNinth))
        XCTAssertEqual(source.documentSession.undoDepth, 1)
    }

    // MARK: - Where the library lives

    /// The plan row puts the library in the document container. A document with
    /// no container yet cannot hold one, and says so rather than writing to a
    /// folder another document would read.
    func testSavingWithoutADocumentContainerSaysWhichStepIsMissing() throws {
        let payload = samplePayload()
        var document = FFDocument(name: "Unsaved")
        document.rootNodes.append(FFNode(
            name: "Source curve",
            geometry: .curve(payload),
            kind: .curve,
            layerID: document.currentLayerID
        ))
        let session = FFEditorSession(document: document)
        session.selection.select([document.rootNodes[0].id])
        session.reloadCurveLibrary()

        XCTAssertFalse(session.saveSelectedCurveToLibrary(name: "Wave 1", tags: ""))
        XCTAssertEqual(session.curveLibraryMessage, FFEditorSession.curveLibraryUnavailableMessage)
        XCTAssertNil(session.curveLibrary)
        XCTAssertTrue(session.curveLibraryEntries.isEmpty)
    }

    /// A library written before this phase lived beside the app's documents. It
    /// must still read, and the first save moves every seeded entry into the
    /// document; the old file is evidence the migration happened, not a file to
    /// delete.
    func testALibraryAtTheOldAppLocationReadsThroughAndMigratesOnSave() throws {
        let legacy = directory.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let payload = samplePayload()
        _ = try FFCurveLibrary(directory: legacy).save(payload, name: "Old scroll", tags: [])
        _ = try FFCurveLibrary(directory: legacy).save(payload, name: "Old ring", tags: [])

        let (session, bundle) = try openDocumentSession(named: "Seeded.ffp")
        session.legacyCurveLibraryDirectory = legacy
        session.reloadCurveLibrary()
        XCTAssertEqual(
            session.curveLibraryEntries.map(\.name).sorted(),
            ["Old ring", "Old scroll"],
            "an existing library is visible in the document it is being moved into"
        )

        let documentLibraryFile = bundle.appendingPathComponent(FFCurveLibrary.fileName)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: documentLibraryFile.path),
            "reading the old file must not write the document"
        )

        XCTAssertTrue(session.saveSelectedCurveToLibrary(name: "New wave", tags: ""))
        let migrated = FFCurveLibrary(directory: bundle).entries()
        XCTAssertEqual(migrated.count, 3, "the first save carries the seeded entries with it")
        XCTAssertEqual(FFCurveLibrary(directory: legacy).entries().count, 2, "the old file is untouched")

        // The library outlives a later document write. The token captured at
        // open still lists the older sidecar, and the bundle's checksums must
        // cover the newer one, or the next open calls the document damaged.
        try session.reopen(from: bundle)
        session.selection.select([
            try XCTUnwrap(session.documentSession.document.rootNodes.first?.id)
        ])
        XCTAssertTrue(session.saveSelectedCurveToLibrary(name: "After reopen", tags: ""))
        XCTAssertEqual(session.curveLibraryEntries.count, 4)
        try session.save()
        XCTAssertEqual(
            FFCurveLibrary(directory: bundle).entries().count,
            4,
            "a document save must not roll the library back to its state at open"
        )
        let reopened = try FFDocumentStore().loadContent(from: bundle)
        XCTAssertNil(
            reopened.recovery,
            "a library write must leave the bundle's own checksums valid, not fall back to the previous save"
        )
    }

    /// Two documents in one folder keep two libraries. This is the scope the
    /// old app-wide file could not express.
    func testTwoDocumentsKeepSeparateCurveLibraries() throws {
        let (first, firstBundle) = try openDocumentSession(named: "First.ffp")
        XCTAssertTrue(first.saveSelectedCurveToLibrary(name: "Only in first", tags: ""))

        let (second, secondBundle) = try openDocumentSession(named: "Second.ffp")

        XCTAssertEqual(FFCurveLibrary(directory: firstBundle).entries().count, 1)
        XCTAssertTrue(FFCurveLibrary(directory: secondBundle).entries().isEmpty)
        XCTAssertTrue(second.curveLibraryEntries.isEmpty, "a curve saved in one document must not appear in another")
    }

    // MARK: - Refusals

    func testANamelessCurveIsRefusedAndNothingIsWritten() throws {
        let library = FFCurveLibrary(directory: directory)
        XCTAssertThrowsError(try library.save(samplePayload(), name: "   ", tags: [])) { error in
            XCTAssertEqual(error as? FFCurveLibraryError, .invalidName)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL.path))
        XCTAssertTrue(library.entries().isEmpty)
    }

    func testSavingWithNoCurveSelectedSaysWhyAndWritesNothing() {
        let session = FFEditorSession()
        session.curveLibraryDirectoryOverride = directory
        XCTAssertFalse(session.saveSelectedCurveToLibrary(name: "Wave 1", tags: ""))
        XCTAssertEqual(session.curveLibraryMessage, "Select a curve before saving it")
        XCTAssertTrue(session.curveLibraryEntries.isEmpty)
    }

    func testInsertingAnEntryThatIsNoLongerInTheLibraryChangesNothing() {
        // A default session opens the bench sample, so "is empty" is only a
        // premise this test can assert if it starts from an empty document.
        let session = FFEditorSession(document: FFDocument(name: "Empty"))
        session.curveLibraryDirectoryOverride = directory
        XCTAssertNil(session.insertLibraryCurve(UUID()))
        XCTAssertTrue(session.rootNodes.isEmpty)
        XCTAssertEqual(session.documentSession.appliedChangeCount, 0, "a refused insert must not count as an edit")
        XCTAssertEqual(session.documentSession.undoDepth, 0)
    }

    // MARK: - Damage and tagging

    func testADamagedLibraryFileReadsAsEmptyAndTheNextSaveRecoversIt() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(FFCurveLibrary.fileName))

        let library = FFCurveLibrary(directory: directory)
        XCTAssertTrue(library.entries().isEmpty, "a damaged sidecar must not stop the app opening")

        let saved = try library.save(samplePayload(), name: "Recovered", tags: [])
        XCTAssertEqual(library.entries().map(\.id), [saved.id])
    }

    func testTagsAreSplitTrimmedDeduplicatedAndCapped() {
        XCTAssertEqual(
            FFCurveLibrary.tags(from: " scroll , ,ring; Gem "),
            [" scroll ", " ", "ring", " Gem "]
        )
        XCTAssertEqual(
            FFCurveLibrary.normalizedTags(FFCurveLibrary.tags(from: "scroll, Scroll ,ring,, gem")),
            ["scroll", "ring", "gem"]
        )
        let many = (0..<12).map { "tag\($0)" }
        XCTAssertEqual(FFCurveLibrary.normalizedTags(many).count, FFCurveLibrary.maximumTags)
        XCTAssertEqual(
            FFCurveLibrary.normalizedTags([String(repeating: "x", count: 40)]),
            [],
            "an over-long tag is dropped rather than truncated"
        )
    }

    // MARK: - Helpers

    /// A document saved as a real `.ffp` bundle and opened through the real
    /// reader, so `documentURL` is a container the library can live in. The
    /// document holds one selectable curve.
    private func openDocumentSession(named name: String) throws -> (FFEditorSession, URL) {
        // An empty seed folder of its own keeps these tests independent of
        // whatever a simulator run has left in the app's Documents folder.
        let emptySeed = directory.appendingPathComponent("Seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySeed, withIntermediateDirectories: true)
        let payload = samplePayload()
        var document = FFDocument(name: name)
        document.rootNodes.append(FFNode(
            name: "Source curve",
            geometry: .curve(payload),
            kind: .curve,
            layerID: document.currentLayerID
        ))
        let bundle = directory.appendingPathComponent(name, isDirectory: true)
        try FFDocumentStore().save(document, to: bundle)
        let session = FFEditorSession(document: document)
        session.legacyCurveLibraryDirectory = emptySeed
        try session.reopen(from: bundle)
        session.selection.select([document.rootNodes[0].id])
        return (session, bundle)
    }

    /// Three spans whose middle one is a weighted NURBS, so a round trip that
    /// silently dropped weights, degree or knots fails on an exact comparison.
    private func samplePayload() -> FFCurvePayload {
        let start = Vec2(x: -18.25, y: -12.5)
        let peak = Vec2(x: 0.125, y: 16.75)
        let end = Vec2(x: 20.5, y: -10.25)
        return FFCurvePayload(
            segments: [
                FFCurveSegment(
                    kind: .bezier,
                    controlPoints: [
                        FFPoint2(start),
                        FFPoint2(Vec2(x: -11.5, y: 4.25)),
                        FFPoint2(peak)
                    ]
                ),
                FFCurveSegment(
                    kind: .nurbs,
                    controlPoints: [
                        FFPoint2(peak),
                        FFPoint2(Vec2(x: 7.75, y: 13.5)),
                        FFPoint2(end)
                    ],
                    weights: [1, 0.75, 1],
                    degree: 2,
                    knots: [0, 0, 0, 1, 1, 1]
                ),
                FFCurveSegment(
                    kind: .bezier,
                    controlPoints: [FFPoint2(end), FFPoint2(Vec2(x: 2.5, y: -14.75))]
                )
            ],
            isClosed: false
        )
    }
}
