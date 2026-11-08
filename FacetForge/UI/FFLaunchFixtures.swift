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
