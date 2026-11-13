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

    // MARK: - Curve library

    static var wantsCurveLibraryDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFCurveLibraryFixture")
    }

    static var wantsCurveLibraryReopen: Bool {
        ProcessInfo.processInfo.arguments.contains("-FFCurveLibraryReopen")
    }

    /// A deterministic start for the library test: the saved-curve file is
    /// removed, then a document with one named curve opens through the real
    /// reader. A save during the test therefore has to write the file.
    static func prepareCurveLibraryDocument() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(FFCurveLibrary.fileName))
        return writeCurveLibraryDocument(
            named: "Phase55 Source.ffp",
            title: "Curve library source",
            node: "Library source",
            in: documents
        )
    }

    /// The same library, an empty document. Nothing here touches the saved
    /// curves, so a curve in the tree after this launch came from the library.
    static func prepareCurveLibraryTarget() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return writeCurveLibraryDocument(
            named: "Phase55 Target.ffp",
            title: "Curve library target",
            node: nil,
            in: documents
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
                knots: [0, 0, 0.5, 1, 1]
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
