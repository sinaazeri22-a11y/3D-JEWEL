import Foundation
import XCTest
@testable import FacetForge

/// Phase 28's document library and Files integration.
///
/// The browser's rules live in `FFDocumentLibrary` and in the session's
/// commands, so these tests drive files and a real session rather than a view.
/// The one view-level ordering promise is proved by the hosted UI test.
final class Phase28LibraryTests: XCTestCase {
    private let store = FFDocumentStore()
    private let fileManager = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase28-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func savedDocument(
        in directory: URL,
        named name: String,
        modified: Date? = nil
    ) throws -> URL {
        var document = FFDocument.benchSample.document
        document.name = name
        let url = directory.appendingPathComponent("\(name).ffp")
        try store.save(document, to: url, thumbnail: FFPThumbnail.png(for: document))
        if let modified {
            try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Recents

    func testRecentsListsBundlesNewestFirstWithTheirRealThumbnails() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let older = try savedDocument(
            in: directory,
            named: "Older",
            modified: Date(timeIntervalSince1970: 1_000)
        )
        let newer = try savedDocument(
            in: directory,
            named: "Newer",
            modified: Date(timeIntervalSince1970: 2_000)
        )

        let summaries = FFDocumentLibrary(directory: directory).documents()

        XCTAssertEqual(summaries.map(\.url), [newer, older])
        XCTAssertEqual(summaries.map(\.displayName), ["Newer", "Older"])
        XCTAssertEqual(summaries.first?.fileName, "Newer")
        let thumbnail = try XCTUnwrap(summaries.first?.thumbnail, "the saved preview.png was not read")
        XCTAssertEqual(
            [UInt8](thumbnail.prefix(4)),
            [0x89, 0x50, 0x4E, 0x47],
            "the browser thumbnail is not the PNG the writer stored"
        )
    }

    func testTheScanSkipsHiddenRecoverySiblingsAndNonDocuments() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = try savedDocument(in: directory, named: "Visible")
        try store.save(FFDocument.benchSample.document, to: url)
        try Data("not a document".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let summaries = FFDocumentLibrary(directory: directory).documents()

        XCTAssertEqual(summaries.map(\.fileName), ["Visible"])
        XCTAssertFalse(
            summaries.contains { $0.fileName.hasPrefix(".") },
            "a hidden previous bundle or journal appeared as a document"
        )
    }

    func testSearchMatchesTheCardNameCaseInsensitively() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = try savedDocument(in: directory, named: "Solitaire Ring")
        let summary = try XCTUnwrap(FFDocumentLibrary(directory: directory).summary(for: url))

        XCTAssertTrue(FFDocumentLibrary.matches(summary, query: "solitaire"))
        XCTAssertTrue(FFDocumentLibrary.matches(summary, query: "  RING "))
        XCTAssertTrue(FFDocumentLibrary.matches(summary, query: ""))
        XCTAssertFalse(FFDocumentLibrary.matches(summary, query: "Emerald"))
    }

    // MARK: - Rename

    func testRenameMovesTheBundleAndItsRecoverySiblings() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        var first = FFDocument.benchSample.document
        first.name = "First"
        let url = directory.appendingPathComponent("Original.ffp")
        try store.save(first, to: url)
        var second = first
        second.name = "Second"
        try store.save(second, to: url)
        let journal = FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url))
        try journal.record(second, at: Date())

        let library = FFDocumentLibrary(directory: directory)
        let renamed = try library.rename(url, to: "Renamed")

        XCTAssertEqual(renamed.lastPathComponent, "Renamed.ffp")
        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
        XCTAssertTrue(fileManager.fileExists(atPath: renamed.path))
        XCTAssertEqual(
            try store.load(from: FFPDocumentBundle.previousURL(for: renamed)).name,
            "First",
            "the last good save did not follow the rename"
        )
        XCTAssertEqual(
            FFEditJournal(directory: FFEditJournal.defaultDirectory(for: renamed)).entryCount,
            1,
            "the unsaved-edit journal did not follow the rename"
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: FFEditJournal.defaultDirectory(for: url).path),
            "the old journal was left behind under the old name"
        )
    }

    func testRenameRejectsAnEmptyNameAPathSeparatorAndACollision() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = try savedDocument(in: directory, named: "One")
        _ = try savedDocument(in: directory, named: "Two")
        let library = FFDocumentLibrary(directory: directory)

        XCTAssertNil(FFDocumentLibrary.sanitizedName("   "))
        XCTAssertNil(FFDocumentLibrary.sanitizedName("a/b"))
        XCTAssertNil(FFDocumentLibrary.sanitizedName("a:b"))
        XCTAssertNil(FFDocumentLibrary.sanitizedName(".hidden"))
        XCTAssertThrowsError(try library.rename(url, to: " ")) { error in
            XCTAssertEqual(error as? FFLibraryError, .invalidName)
        }
        XCTAssertThrowsError(try library.rename(url, to: "Two")) { error in
            XCTAssertEqual(error as? FFLibraryError, .nameTaken("Two"))
        }
        XCTAssertTrue(fileManager.fileExists(atPath: url.path), "a rejected rename moved the file")
    }

    func testRenamingTheOpenDocumentRetargetsTheSessionWithoutLosingEdits() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = try savedDocument(in: directory, named: "Open")
        let session = FFEditorSession(document: FFDocument(), autosaveInterval: 0)
        try session.reopen(from: url)
        XCTAssertTrue(session.setDisplayMode(.technical, for: "top"))
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.journalSnapshotCount, 1)

        let renamed = try session.renameDocument(at: url, to: "Open Renamed")

        XCTAssertEqual(session.documentURL, renamed)
        XCTAssertTrue(session.isDirty, "renaming discarded the unsaved edit")
        XCTAssertEqual(session.journalSnapshotCount, 1, "the session lost its moved journal")
        try session.save()
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
        let reopened = try store.load(from: renamed)
        XCTAssertEqual(reopened.displayModes["top"], .technical)
        XCTAssertEqual(reopened.name, "Open")
    }

    // MARK: - Duplicate

    func testDuplicateIsAnIndependentCopyWithoutRecoveryState() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = try savedDocument(in: directory, named: "Master")
        let journal = FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url))
        try journal.record(FFDocument.benchSample.document, at: Date())
        let library = FFDocumentLibrary(directory: directory)

        let copy = try library.duplicate(url)
        let secondCopy = try library.duplicate(url)

        XCTAssertEqual(copy.lastPathComponent, "Master copy.ffp")
        XCTAssertEqual(secondCopy.lastPathComponent, "Master copy 2.ffp")
        XCTAssertEqual(try store.load(from: copy).stateHash, try store.load(from: url).stateHash)
        XCTAssertEqual(
            FFEditJournal(directory: FFEditJournal.defaultDirectory(for: copy)).entryCount,
            0,
            "a duplicate inherited another document's crash journal"
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: FFPDocumentBundle.previousURL(for: copy).path),
            "a duplicate inherited another document's previous save"
        )
    }

    func testDeletingACopyLeavesTheOriginalReadable() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = try savedDocument(in: directory, named: "Keep")
        let library = FFDocumentLibrary(directory: directory)
        let copy = try library.duplicate(url)

        try library.delete(copy)

        XCTAssertFalse(fileManager.fileExists(atPath: copy.path))
        XCTAssertEqual(try store.load(from: url).name, "Keep")
    }

    // MARK: - Delete

    func testDeleteRemovesTheBundleAndItsRecoverySiblings() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        var first = FFDocument.benchSample.document
        first.name = "First"
        let url = directory.appendingPathComponent("DeleteMe.ffp")
        try store.save(first, to: url)
        var second = first
        second.name = "Second"
        try store.save(second, to: url)
        let journal = FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url))
        try journal.record(second, at: Date())

        try FFDocumentLibrary(directory: directory).delete(url)

        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
        XCTAssertFalse(fileManager.fileExists(atPath: FFPDocumentBundle.previousURL(for: url).path))
        XCTAssertFalse(fileManager.fileExists(atPath: FFEditJournal.defaultDirectory(for: url).path))
    }

    func testTheSessionRefusesToDeleteTheOpenDocument() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = try savedDocument(in: directory, named: "Open")
        let session = FFEditorSession(document: FFDocument(), autosaveInterval: 0)
        try session.reopen(from: url)

        XCTAssertThrowsError(try session.deleteDocument(at: url)) { error in
            XCTAssertEqual(error as? FFLibraryError, .cannotModifyOpenDocument)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))
    }

    func testRefreshLibraryListsTheOpenDocumentsFolder() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let open = try savedDocument(in: directory, named: "Open")
        _ = try savedDocument(in: directory, named: "Sibling")
        let session = FFEditorSession(document: FFDocument(), autosaveInterval: 0)
        try session.reopen(from: open)

        session.refreshLibrary()

        XCTAssertEqual(Set(session.library.map(\.fileName)), ["Open", "Sibling"])
    }

    // MARK: - Files integration

    func testInfoPlistDeclaresTheFFPPackageAndEnablesFiles() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)

        XCTAssertEqual(info["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(info["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let declared = documentTypes.compactMap { $0["LSItemContentTypes"] as? [String] }
        XCTAssertTrue(
            declared.contains { $0.contains("com.shahroodazerov.facetforge.ffp") },
            "the app does not claim the .ffp document type"
        )

        let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let ffp = try XCTUnwrap(exported.first {
            $0["UTTypeIdentifier"] as? String == "com.shahroodazerov.facetforge.ffp"
        })
        XCTAssertEqual(ffp["UTTypeConformsTo"] as? [String], ["com.apple.package"])
        let tags = try XCTUnwrap(ffp["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["ffp"])
    }

    func testTheUIDocumentBridgeLoadsTheSameBundle() throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = try savedDocument(in: directory, named: "Bridge")
        let expected = try store.load(from: url)

        let file = FFDocumentFile(fileURL: url)
        let wrapper = try FileWrapper(url: url, options: .immediate)
        try file.load(fromContents: wrapper, ofType: "com.shahroodazerov.facetforge.ffp")

        XCTAssertEqual(file.document?.stateHash, expected.stateHash)
        XCTAssertEqual(file.content?.legacySingleFile, false)
        XCTAssertNil(file.content?.recovery)
    }
}
