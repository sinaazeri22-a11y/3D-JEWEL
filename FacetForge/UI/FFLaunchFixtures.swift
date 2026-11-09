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
}
