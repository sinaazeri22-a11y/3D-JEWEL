import Foundation

/// Launch-time test surfaces, alongside the Phase 4 layout laboratory.
///
/// `-FFRecoveryFixture` seeds a real saved bundle and a real crash journal, then
/// the shipping shell opens it through the same `reopen` path a user takes. The
/// session has no test-only branch: this file only prepares files on disk.
enum FFLaunchFixtures {
    static var wantsRecoveryDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFRecoveryFixture")
    }

    static var wantsBrowserDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFBrowserFixture")
    }

    static var wantsMigrationDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFMigrationFixture")
    }

    static var wantsSurfaceDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFSurfaceFixture")
    }

    /// One closed profile, saved through the real writer and opened by the real
    /// reader. It is off the local y axis so both an extrusion and a revolution
    /// are legal on it, and it is large enough that the camera's standard view
    /// shows the whole ghost.
    static func prepareSurfaceDocument() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let url = documents.appendingPathComponent("Phase54 Profile.ffp")
        try? FileManager.default.removeItem(at: url)

        let corners = [
            Vec2(x: 10, y: -15),
            Vec2(x: 28, y: -15),
            Vec2(x: 28, y: 15),
            Vec2(x: 10, y: 15)
        ]
        var segments: [FFCurveSegment] = []
        for index in corners.indices {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(start), FFPoint2(end)]
            ))
        }
        let payload = FFCurvePayload(segments: segments, isClosed: true)
        var document = FFDocument(name: "Surface preview")
        let layerID = document.currentLayerID
        document.rootNodes.append(FFNode(
            name: "Preview profile",
            geometry: .curve(payload),
            kind: .curve,
            layerID: layerID
        ))
        guard (try? FFDocumentStore().save(
            document,
            to: url,
            thumbnail: FFPThumbnail.png(for: document)
        )) != nil else {
            return nil
        }
        return url
    }

    /// A real bundle written by this build, then rewritten as the bundle a
    /// version-1 app would have produced. The shipping shell opens it through
    /// the normal reader, so the status line the test reads is the line a user
    /// sees after opening an old file.
    static func prepareMigrationDocument() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)

        let destination = documents.appendingPathComponent("Legacy Pendant.ffp")
        let source = documents.appendingPathComponent("Phase38 Source.ffp")
        for url in [destination, source] {
            try? FileManager.default.removeItem(at: url)
        }

        let document = FFDocumentTemplate.pendant.makeDocument()
        guard (try? FFDocumentStore().save(
            document,
            to: source,
            thumbnail: FFPThumbnail.png(for: document)
        )) != nil else {
            return nil
        }
        guard (try? FFPFormatMigration.writingVersion1Copy(of: source, to: destination)) != nil else {
            return nil
        }
        try? FileManager.default.removeItem(at: source)
        return destination
    }

    /// Two real saved bundles in the app's Documents directory, each with the
    /// real thumbnail the editor's save writes. The names carry a Phase28
    /// prefix so a rerun replaces only its own fixtures.
    @discardableResult
    static func prepareBrowserDocuments() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil
        ) {
            for url in existing {
                let name = url.lastPathComponent
                if name.hasPrefix("Phase28") || name.hasPrefix("Untitled") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        var sapphire = FFDocument.benchSample.document
        sapphire.name = "Sapphire Ring"
        let sapphireURL = documents.appendingPathComponent("Phase28 Sapphire.ffp")
        guard (try? FFDocumentStore().save(
            sapphire,
            to: sapphireURL,
            thumbnail: FFPThumbnail.png(for: sapphire)
        )) != nil else {
            return nil
        }

        var emerald = FFDocument.benchSample.document
        emerald.name = "Emerald Brooch"
        if let stoneID = emerald.rootNodes.first(where: { $0.kind == .stone })?.id {
            emerald.updateNode(withID: stoneID) { node in
                node.transform.translation.y += 4
            }
        }
        let emeraldURL = documents.appendingPathComponent("Phase28 Emerald.ffp")
        guard (try? FFDocumentStore().save(
            emerald,
            to: emeraldURL,
            thumbnail: FFPThumbnail.png(for: emerald)
        )) != nil else {
            return nil
        }
        return documents
    }

    /// A saved bench sample plus two journal snapshots that moved the stone to
    /// y = 47.5 mm. The saved bundle still has it at 40 mm, so restoring the
    /// journal is visible both in the gizmo readout and in the recovered state.
    static func prepareRecoveryDocument() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = documents.appendingPathComponent("RecoveryDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else {
            return nil
        }

        let url = directory.appendingPathComponent("recovered-ring.ffp")
        var baseline = FFDocument.benchSample.document
        baseline.name = "Recovered Ring"
        guard (try? FFDocumentStore().save(baseline, to: url)) != nil else {
            return nil
        }

        let journal = FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url))
        journal.clear()

        var moved = baseline
        guard let stoneID = moved.rootNodes.first(where: { $0.kind == .stone })?.id else {
            return nil
        }
        moved.updateNode(withID: stoneID) { node in
            node.transform.translation.y += 2.5
        }
        try? journal.record(moved, at: Date().addingTimeInterval(-2))
        moved.updateNode(withID: stoneID) { node in
            node.transform.translation.y += 5
        }
        try? journal.record(moved, at: Date().addingTimeInterval(-1))
        return url
    }

    // MARK: - Curve performance

    static var wantsCurvePerformanceDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFCurvePerformanceFixture")
    }

    /// One saved document whose only node is the row's ten-thousand-point
    /// curve, written by the real store and opened through the real reader. The
    /// geometry is the committed harness's own payload, centred on the sketch
    /// origin so the standard camera frames the whole curve, so the document the
    /// UI test draws is the same payload the thresholds are measured against.
    static func prepareCurvePerformanceDocument() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let url = documents.appendingPathComponent("Phase56 Benchmark.ffp")
        try? FileManager.default.removeItem(at: url)
        // This fixture writes its own document and clears that document's
        // journal, so an earlier launch's undone edit cannot leave a recovery
        // prompt covering the shell the test has to reach.
        FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url)).clear()

        let payload = FFCurveBenchmark.polylinePayload()
        let document = FFCurveBenchmark.document(
            name: "Curve performance",
            nodeName: "Benchmark curve",
            payload: centred(payload)
        )
        guard (try? FFDocumentStore().save(
            document,
            to: url,
            thumbnail: FFPThumbnail.png(for: document)
        )) != nil else {
            return nil
        }
        return url
    }

    /// The benchmark's payload spans x from 0 to about 45 mm; the sketch exists
    /// around the origin, so it is shifted once here rather than in the harness,
    /// whose own coordinates the thresholds are quoted against.
    private static func centred(_ payload: FFCurvePayload) -> FFCurvePayload {
        let xs = payload.segments.flatMap { $0.controlPoints.map(\.x) }
        guard let minimum = xs.min(), let maximum = xs.max() else { return payload }
        let offset = (minimum + maximum) * 0.5
        guard abs(offset) > FFMath.eps else { return payload }
        var shifted = payload
        for index in shifted.segments.indices {
            for point in shifted.segments[index].controlPoints.indices {
                shifted.segments[index].controlPoints[point].x -= offset
            }
        }
        return shifted
    }

    // MARK: - Curve library

    static var wantsCurveLibraryDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFCurveLibraryFixture")
    }

    static var wantsCurveLibraryReopen: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFCurveLibraryReopen")
    }

    static var wantsCurveLibraryFull: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFCurveLibraryFullFixture")
    }

    /// The document the library fixtures share, so a reopen launches the same
    /// file the previous launch saved into rather than a fresh one.
    private static let curveLibrarySourceName = "Phase55 Source.ffp"
    /// The full-library fixture writes its own document. Sharing the source URL
    /// would hand it the previous test's journal, and an open recovery prompt
    /// covers the shell, so the chip would exist but never be reachable.
    private static let curveLibraryFullName = "Phase55 Full.ffp"

    /// A deterministic start for the library test: the pre-Phase-55 app-level
    /// file and the journal for the fixture document are removed so neither can
    /// seed or prompt anything, and a freshly written document with one named
    /// curve opens through the real reader. The bundle is new, so it carries no
    /// library of its own and a save during the test has to write one into the
    /// document.
    static func prepareCurveLibraryDocument() -> URL? {
        guard let documents = curveLibraryDocuments() else { return nil }
        let url = documents.appendingPathComponent(curveLibrarySourceName)
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(FFCurveLibrary.fileName))
        clearJournal(for: url)
        return writeCurveLibraryDocument(
            named: curveLibrarySourceName,
            title: "Curve library source",
            node: "Library source",
            in: documents
        )
    }

    /// The same document again, with its library left exactly as the previous
    /// launch wrote it: this is the relaunch the persistence test needs, and it
    /// deliberately touches nothing on disk.
    static func prepareCurveLibrarySource() -> URL? {
        guard let documents = curveLibraryDocuments() else { return nil }
        let url = documents.appendingPathComponent(curveLibrarySourceName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// An empty document with twelve saved curves already inside its bundle,
    /// which is more than the card used to render. The rows are real entries in
    /// the real sidecar, so reaching the twelfth proves the card reaches the
    /// file rather than a test-only list, and a curve in the tree afterwards
    /// can only have come from the library.
    static func prepareCurveLibraryFullDocument() -> URL? {
        guard let documents = curveLibraryDocuments() else { return nil }
        let full = documents.appendingPathComponent(curveLibraryFullName)
        clearJournal(for: full)
        guard let url = writeCurveLibraryDocument(
            named: curveLibraryFullName,
            title: "Curve library full",
            node: nil,
            in: documents
        ) else { return nil }
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(FFCurveLibrary.fileName))
        seedCurveLibrary(count: 12, in: url)
        return url
    }

    /// A relaunch test must not inherit a recovery offer from an earlier run,
    /// so every fixture that writes a document starts from an empty journal for
    /// that exact file.
    private static func clearJournal(for url: URL) {
        FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url)).clear()
    }

    private static func curveLibraryDocuments() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    /// Writes the same JSON shape `FFCurveLibrary` reads, with timestamps one
    /// second apart so the card's newest-first order is deterministic: index 0
    /// is the twelfth curve, index 11 the first.
    private static func seedCurveLibrary(count: Int, in bundle: URL) {
        guard count > 0 else { return }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var entries: [FFCurveLibraryEntry] = []
        for index in 1...count {
            entries.append(FFCurveLibraryEntry(
                name: String(format: "Curve %02d", index),
                tags: [],
                payload: seededCurvePayload(index),
                savedAt: base.addingTimeInterval(Double(index))
            ))
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(
            to: bundle.appendingPathComponent(FFCurveLibrary.fileName),
            options: .atomic
        )
    }

    private static func seededCurvePayload(_ index: Int) -> FFCurvePayload {
        let offset = Double(index) * 0.5
        return FFCurvePayload(
            segments: [
                FFCurveSegment(
                    kind: .bezier,
                    controlPoints: [
                        FFPoint2(Vec2(x: -12 + offset, y: -8)),
                        FFPoint2(Vec2(x: 0, y: 10))
                    ]
                ),
                FFCurveSegment(
                    kind: .bezier,
                    controlPoints: [
                        FFPoint2(Vec2(x: 0, y: 10)),
                        FFPoint2(Vec2(x: 12 + offset, y: -8))
                    ]
                )
            ],
            isClosed: false
        )
    }

    /// One document, optionally holding one three-span open curve. The spans
    /// are written as the payload a document stores, so the geometry the test
    /// saves is geometry a user could have drawn rather than a test-only
    /// outline, and one span is a weighted NURBS so weights, degree and knots
    /// all have to survive the round trip.
    private static func writeCurveLibraryDocument(
        named fileName: String,
        title: String,
        node nodeName: String?,
        in documents: URL
    ) -> URL? {
        let url = documents.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        var document = FFDocument(name: title)
        if let nodeName {
            let start = Vec2(x: -18, y: -12)
            let peak = Vec2(x: 0, y: 16)
            let end = Vec2(x: 20, y: -10)
            let first = FFCurveSegment(
                kind: .bezier,
                controlPoints: [
                    FFPoint2(start),
                    FFPoint2(Vec2(x: -11, y: 4)),
                    FFPoint2(peak)
                ]
            )
            let second = FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(peak),
                    FFPoint2(Vec2(x: 7, y: 13)),
                    FFPoint2(end)
                ],
                weights: [1, 0.75, 1],
                degree: 2,
                // 3 control points at degree 2 need 3 + 2 + 1 = 6 knots; a
                // shorter vector makes the segment unrebuildable, so the
                // saved curve would be bytes rather than geometry.
                knots: [0, 0, 0, 1, 1, 1]
            )
            let third = FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(end), FFPoint2(Vec2(x: 2, y: -14))]
            )
            document.rootNodes.append(FFNode(
                name: nodeName,
                geometry: .curve(FFCurvePayload(
                    segments: [first, second, third],
                    isClosed: false
                )),
                kind: .curve,
                layerID: document.currentLayerID
            ))
        }
        guard (try? FFDocumentStore().save(
            document,
            to: url,
            thumbnail: FFPThumbnail.png(for: document)
        )) != nil else {
            return nil
        }
        return url
    }
}
