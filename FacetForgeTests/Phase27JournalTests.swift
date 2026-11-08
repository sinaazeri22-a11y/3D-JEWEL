import XCTest
@testable import FacetForge

/// Phase 27's acceptance: a kill during an edit recovers the last edit within
/// five seconds, the journal keeps only five snapshots, autosave writes real
/// saves, and the recovery offer is the session's decision while the shell only
/// renders it.
final class Phase27JournalTests: XCTestCase {
    private let store = FFDocumentStore()

    // MARK: - Simulated kill

    func testASimulatedKillRecoversTheLastEditWithinFiveSeconds() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("kill.ffp")
        let baseline = FFDocument.benchSample.document
        try store.save(baseline, to: url)

        let session = FFEditorSession(
            document: FFDocument(),
            autosaveInterval: 30,
        )
        try session.reopen(from: url)
        XCTAssertNil(session.recoveryOffer, "a clean document must not offer recovery")

        let editTime = Date()
        XCTAssertTrue(session.setDisplayMode(.wireframe, for: "perspective"))
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: false))
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(
            session.document.stateHash != baseline.stateHash,
            "the edits did not change the document"
        )
        // Each committed edit is journaled synchronously, so the simulated
        // kill needs no waiting and no flush to see both edits.
        let journal = FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url))
        XCTAssertEqual(journal.entryCount, 2, "both edits did not reach the journal")

        // Simulated kill: no save, no background hook, no flush. A brand-new
        // session reads the same files and must offer the journal.
        let revived = FFEditorSession(
            document: FFDocument(),
            autosaveInterval: 30,
        )
        try revived.reopen(from: url)

        XCTAssertEqual(
            revived.displayMode(for: "perspective"),
            .shaded,
            "the saved bundle was already replaced instead of waiting for the prompt"
        )
        let offer = try XCTUnwrap(revived.recoveryOffer, "the journal was not offered")
        XCTAssertEqual(offer.snapshotCount, 2)
        XCTAssertEqual(offer.document.displayModes["perspective"], .wireframe)
        XCTAssertEqual(
            offer.document.layers.first { $0.name == "Stones" }?.isVisible,
            false
        )
        XCTAssertEqual(offer.documentName, "Untitled ring")
        XCTAssertLessThan(
            offer.recordedAt.timeIntervalSince(editTime),
            5,
            "the recovered snapshot is more than five seconds older than the last edit"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(offer.recordedAt),
            5,
            "recovery read a snapshot that is five seconds stale"
        )
        XCTAssertTrue(revived.documentStatus.hasPrefix("Unsaved edits found"))

        XCTAssertTrue(revived.restoreRecovery(), "the offer could not be applied")
        XCTAssertEqual(revived.displayMode(for: "perspective"), .wireframe)
        XCTAssertEqual(
            revived.layers.first { $0.name == "Stones" }?.isVisible,
            false
        )
        XCTAssertNil(revived.recoveryOffer)
        XCTAssertTrue(revived.documentStatus.hasPrefix("Restored 2 unsaved edits"))
        XCTAssertTrue(revived.isDirty)
        XCTAssertEqual(revived.document.stateHash, offer.document.stateHash)
        XCTAssertGreaterThanOrEqual(
            FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url)).entryCount,
            1,
            "the restored state must be journaled again"
        )
    }

    // MARK: - Retention

    func testJournalIsPrunedToFiveSnapshots() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = FFEditJournal(directory: directory.appendingPathComponent("retention"))
        let base = FFDocument.benchSample.document

        for index in 1...7 {
            var document = base
            document.name = "Ring \(index)"
            try journal.record(
                document,
                at: Date(timeIntervalSince1970: Double(index))
            )
        }

        XCTAssertEqual(journal.entryCount, 5, "the journal kept more than five snapshots")
        XCTAssertEqual(
            journal.snapshots().map(\.document.name),
            ["Ring 3", "Ring 4", "Ring 5", "Ring 6", "Ring 7"],
            "pruning dropped the wrong snapshots"
        )
        XCTAssertEqual(journal.latest()?.document.name, "Ring 7")
    }

    func testCorruptNewestSnapshotFallsBackToThePreviousGoodOne() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = FFEditJournal(directory: directory)
        let base = FFDocument.benchSample.document

        var older = base
        older.name = "Older"
        try journal.record(older, at: Date(timeIntervalSince1970: 1))
        var newer = base
        newer.name = "Newer"
        try journal.record(newer, at: Date(timeIntervalSince1970: 2))

        let files = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("entry-") }
            .sorted()
        let newest = try XCTUnwrap(files.last)
        let newestURL = directory.appendingPathComponent(newest)
        let data = try Data(contentsOf: newestURL)
        try Data(data.prefix(data.count / 2)).write(to: newestURL)

        XCTAssertEqual(
            journal.latest()?.document.name,
            "Older",
            "a truncated newest snapshot hid the previous good one"
        )
        XCTAssertEqual(journal.entryCount, 2)
    }

    // MARK: - Autosave

    func testAutosaveWritesOnlyWhenDirtyAndClearsTheJournal() throws {
        XCTAssertEqual(FFEditorSession.defaultAutosaveInterval, 30)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auto.ffp")
        try store.save(FFDocument.benchSample.document, to: url)

        let session = FFEditorSession(
            document: FFDocument(),
            autosaveInterval: 0.2,
        )
        try session.reopen(from: url)
        XCTAssertFalse(session.autosaveIfNeeded(), "a clean document was rewritten")

        XCTAssertTrue(session.setDisplayMode(.technical, for: "top"))
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.autosaveIfNeeded(), "a dirty document was not autosaved")
        XCTAssertFalse(session.isDirty)
        XCTAssertNotNil(session.lastAutosaveAt)
        XCTAssertEqual(session.autosaveMessage, "Autosaved auto.ffp")
        XCTAssertTrue(session.documentStatus.hasPrefix("Autosaved"))
        XCTAssertEqual(
            FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url)).entryCount,
            0,
            "a successful save must delete the journal it made redundant"
        )
        XCTAssertEqual(try store.load(from: url).displayModes["top"], .technical)

        let before = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        XCTAssertFalse(session.autosaveIfNeeded(), "an idle document was autosaved")
        let after = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        XCTAssertEqual(before, after, "an idle autosave rewrote the bundle")
    }

    func testTheThirtySecondTimerUsesTheSameAutosavePath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timer.ffp")
        try store.save(FFDocument.benchSample.document, to: url)

        let session = FFEditorSession(
            document: FFDocument(),
            autosaveInterval: 0.2,
        )
        try session.reopen(from: url)
        XCTAssertTrue(session.setDisplayMode(.technical, for: "front"))
        session.startAutosave()
        defer { session.stopAutosave() }

        // Poll for the timer rather than assuming a fixed window is enough on a
        // loaded simulator. A timer that never fires still fails, and the
        // assertions below still prove the save reached the bundle.
        let deadline = Date().addingTimeInterval(5)
        while session.lastAutosaveAt == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNotNil(session.lastAutosaveAt, "the autosave timer never fired")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(
            try store.load(from: url).displayModes["front"],
            .technical
        )
        session.stopAutosave()
    }

    // MARK: - Restore and discard

    func testDiscardLeavesTheSavedBundleAndTheDocumentUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("discard.ffp")
        let baseline = FFDocument.benchSample.document
        try store.save(baseline, to: url)

        let writer = FFEditorSession(
            document: FFDocument(),
            autosaveInterval: 30,
        )
        try writer.reopen(from: url)
        XCTAssertTrue(writer.setDisplayMode(.wireframe, for: "perspective"))

        let reader = FFEditorSession(
            document: FFDocument(),
            autosaveInterval: 30,
        )
        try reader.reopen(from: url)
        XCTAssertNotNil(reader.recoveryOffer)
        XCTAssertTrue(reader.discardRecovery())
        XCTAssertNil(reader.recoveryOffer)
        XCTAssertEqual(reader.document.stateHash, baseline.stateHash)
        XCTAssertFalse(reader.isDirty)
        XCTAssertEqual(try store.load(from: url).stateHash, baseline.stateHash)
        XCTAssertEqual(
            FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url)).entryCount,
            0
        )
        XCTAssertTrue(reader.documentStatus.hasPrefix("Discarded unsaved edits"))
    }

    func testRestoredEditsSurviveTheNextSaveAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("restored.ffp")
        try store.save(FFDocument.benchSample.document, to: url)

        let writer = FFEditorSession(
            document: FFDocument(),
            autosaveInterval: 30,
        )
        try writer.reopen(from: url)
        XCTAssertTrue(writer.setDisplayMode(.wireframe, for: "perspective"))
        let edited = writer.document.stateHash

        let reader = FFEditorSession(
            document: FFDocument(),
            autosaveInterval: 30,
        )
        try reader.reopen(from: url)
        XCTAssertTrue(reader.restoreRecovery())
        try reader.save()
        XCTAssertEqual(
            FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url)).entryCount,
            0,
            "saving after a restore did not clear the journal"
        )

        let reopened = FFEditorSession(document: FFDocument())
        try reopened.reopen(from: url)
        XCTAssertNil(reopened.recoveryOffer)
        XCTAssertEqual(reopened.displayMode(for: "perspective"), .wireframe)
        XCTAssertEqual(reopened.document.stateHash, edited)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("facetforge-phase27-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
