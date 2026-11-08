import Foundation

/// One recovery snapshot written by the edit journal.
struct FFJournalSnapshot: Codable, Equatable, Sendable {
    var sequence: Int
    var recordedAt: Date
    var document: FFDocument
}

/// The crash journal for one document.
///
/// Every committed edit schedules a snapshot in a hidden sibling directory.
/// The write is delayed by at most one second so a drag does not encode the
/// whole document on every frame, but the snapshot's `recordedAt` is the moment
/// of the edit, not the moment of the write. A kill can therefore lose at most
/// the in-flight second, which is the Phase 27 acceptance bound.
///
/// Retention is five snapshots: writing the sixth deletes the oldest. A corrupt
/// entry is skipped when looking for the newest good state, so a torn write can
/// never hide a valid snapshot behind it. The journal is the session's state,
/// not the bundle's: a successful save deletes the directory.
struct FFEditJournal {
    static let retentionLimit = 5
    private static let prefix = "entry-"

    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// The journal lives beside the bundle, never inside it, so the bundle's
    /// checksums and preservation contract are untouched by recovery state.
    static func defaultDirectory(for documentURL: URL) -> URL {
        documentURL.deletingLastPathComponent().appendingPathComponent(
            ".\(documentURL.lastPathComponent).journal",
            isDirectory: true
        )
    }

    var exists: Bool {
        fileManager.fileExists(atPath: directory.path)
    }

    var entryCount: Int {
        entryFiles().count
    }

    /// Writes one snapshot and prunes the journal to five entries. Returns the
    /// snapshot as recorded, or nil when the directory could not hold it.
    @discardableResult
    func record(_ document: FFDocument, at date: Date = Date()) throws -> FFJournalSnapshot? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let sequence = (entryFiles().last?.sequence ?? 0) + 1
        let snapshot = FFJournalSnapshot(sequence: sequence, recordedAt: date, document: document)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)

        let url = directory.appendingPathComponent(Self.fileName(sequence))
        try data.write(to: url, options: .atomic)
        prune()
        return snapshot
    }

    /// The newest snapshot that decodes. Corrupt or truncated entries are
    /// skipped, so the previous good state still answers after a torn write.
    func latest() -> FFJournalSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for file in entryFiles().reversed() {
            guard let data = try? Data(contentsOf: file.url),
                  let snapshot = try? decoder.decode(FFJournalSnapshot.self, from: data),
                  snapshot.sequence == file.sequence else {
                continue
            }
            return snapshot
        }
        return nil
    }

    /// Every readable snapshot, oldest first. Used by the retention test.
    func snapshots() -> [FFJournalSnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return entryFiles().compactMap { file in
            guard let data = try? Data(contentsOf: file.url),
                  let snapshot = try? decoder.decode(FFJournalSnapshot.self, from: data),
                  snapshot.sequence == file.sequence else {
                return nil
            }
            return snapshot
        }
    }

    /// Deletes the journal after a save or an explicit discard. Removing a
    /// journal that never existed is not an error.
    func clear() {
        guard exists else { return }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Files

    private static func fileName(_ sequence: Int) -> String {
        String(format: "entry-%06d.json", sequence)
    }

    private func entryFiles() -> [(sequence: Int, url: URL)] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.compactMap { name -> (sequence: Int, url: URL)? in
            guard name.hasPrefix(Self.prefix), name.hasSuffix(".json") else { return nil }
            let number = name.dropFirst(Self.prefix.count).dropLast(".json".count)
            guard let sequence = Int(number) else { return nil }
            return (sequence, directory.appendingPathComponent(name))
        }
        .sorted { $0.sequence < $1.sequence }
    }

    private func prune() {
        let files = entryFiles()
        guard files.count > Self.retentionLimit else { return }
        for file in files.prefix(files.count - Self.retentionLimit) {
            try? fileManager.removeItem(at: file.url)
        }
    }
}
