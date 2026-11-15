import Foundation

/// One saved curve: the payload, the name the jeweller gave it and the tags
/// they filed it under.
///
/// The payload is the document's own curve payload, not a sampled outline, so
/// inserting an entry reproduces the saved control points, weights, degree and
/// knots exactly. There is nothing to re-fit and no tolerance to argue about.
struct FFCurveLibraryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var tags: [String]
    var payload: FFCurvePayload
    /// Precise, not rounded: the default date strategy writes the interval as
    /// a double, so a re-read entry compares equal to the one that was saved.
    var savedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        tags: [String],
        payload: FFCurvePayload,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.payload = payload
        self.savedAt = savedAt
    }
}

/// Why a curve could not be saved. Each case carries the sentence the card
/// shows, the same rule the editing commands follow: a refusal explains itself.
enum FFCurveLibraryError: Error, Equatable, LocalizedError {
    case invalidName
    case emptyCurve
    case missingEntry

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "A saved curve needs a short name without control characters"
        case .emptyCurve:
            return "That curve has no spans to save"
        case .missingEntry:
            return "That saved curve is no longer in the library"
        }
    }
}

/// The user's saved curves, as one JSON file inside the document that owns
/// them.
///
/// The file lives in the open document's `.ffp` bundle, so a jeweller's saved
/// curves travel with the file they belong to instead of being shared by every
/// document on the device. It stays an unknown entry as far as the format is
/// concerned: no manifest field and no reader of `.ffp` has to know it exists,
/// `FFPDocumentBundle` already copies unknown entries through a save, and the
/// library adds itself to the bundle's checksum list when it writes so the
/// document stays verifiable.
///
/// Documents written before Phase 55 kept the library beside the app's
/// documents. `seedDirectory` is read only while the document has no library of
/// its own, and the first save copies every seeded entry into the document, so
/// a jeweller's existing curves appear and are never orphaned; the old file is
/// left untouched rather than deleted. A missing or damaged file reads as an
/// empty library instead of refusing to open the document; a save is atomic, so
/// a crash mid-write cannot truncate the entries that were already there.
struct FFCurveLibrary {
    static let fileName = "CurveLibrary.json"
    static let maximumNameLength = 80
    static let maximumTags = 8
    static let maximumTagLength = 32

    let directory: URL
    /// Where the library lived before it moved into the document. Read-only.
    let seedDirectory: URL?
    private let fileManager: FileManager

    init(directory: URL, seedDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory
        self.seedDirectory = seedDirectory
        self.fileManager = fileManager
    }

    var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    var seedFileURL: URL? {
        seedDirectory?.appendingPathComponent(Self.fileName)
    }

    /// Newest first, then by name, so the card's order is stable across reads.
    ///
    /// A document that has no file yet answers from the seed, which is what
    /// makes a library written before this phase visible in the document it is
    /// being moved into.
    func entries() -> [FFCurveLibraryEntry] {
        if let stored = readEntries(at: fileURL) {
            return sorted(stored)
        }
        if let seedFileURL, let seeded = readEntries(at: seedFileURL) {
            return sorted(seeded)
        }
        return []
    }

    private func readEntries(at url: URL) -> [FFCurveLibraryEntry]? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let stored = try? Self.decoder.decode([FFCurveLibraryEntry].self, from: data)
        else {
            return nil
        }
        return stored
    }

    private func sorted(_ stored: [FFCurveLibraryEntry]) -> [FFCurveLibraryEntry] {
        stored.sorted { lhs, rhs in
            if lhs.savedAt != rhs.savedAt {
                return lhs.savedAt > rhs.savedAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func entry(withID id: UUID) -> FFCurveLibraryEntry? {
        entries().first { $0.id == id }
    }

    /// Appends one entry and writes the whole file into the document. Because
    /// the list starts from `entries()`, the first save after an upgrade writes
    /// the seeded entries too: the migration is one-way, best-effort and never
    /// deletes the old file. Duplicate names are allowed because the id is the
    /// identity; a jeweller may keep two versions of the same scroll and tell
    /// them apart by tag.
    @discardableResult
    func save(
        _ payload: FFCurvePayload,
        name rawName: String,
        tags rawTags: [String]
    ) throws -> FFCurveLibraryEntry {
        guard let name = Self.validName(rawName) else {
            throw FFCurveLibraryError.invalidName
        }
        guard !payload.segments.isEmpty else {
            throw FFCurveLibraryError.emptyCurve
        }
        var stored = entries()
        let entry = FFCurveLibraryEntry(
            name: name,
            tags: Self.normalizedTags(rawTags),
            payload: payload
        )
        stored.append(entry)
        try write(stored)
        return entry
    }

    /// A document bundle's `checksums.json` covers every file it holds, so a
    /// sidecar written after a save has to be added to that list in the same
    /// breath. Without the repair the next open would reject the document as
    /// damaged; a failure puts the library and the list back as they were rather
    /// than leaving either half-written.
    private func write(_ entries: [FFCurveLibraryEntry]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(entries)
        let checksumsURL = directory.appendingPathComponent(FFPFormat.checksumsName)
        let inDocumentBundle = fileManager.fileExists(
            atPath: directory.appendingPathComponent(FFPFormat.manifestName).path
        ) && fileManager.fileExists(atPath: checksumsURL.path)
        let previousLibrary = fileManager.contents(atPath: fileURL.path)
        let previousChecksums = inDocumentBundle ? fileManager.contents(atPath: checksumsURL.path) : nil
        do {
            try data.write(to: fileURL, options: .atomic)
            if inDocumentBundle {
                try FFPDocumentBundle(fileManager: fileManager).writeChecksums(in: directory)
            }
        } catch {
            if let previousLibrary {
                try? previousLibrary.write(to: fileURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: fileURL)
            }
            if let previousChecksums {
                try? previousChecksums.write(to: checksumsURL, options: .atomic)
            }
            throw error
        }
    }

    /// The bundle's unknown-entry token must not speak for this file. A token
    /// captured when the document was opened would otherwise write the library
    /// back to its state at open time on the next save, discarding every curve
    /// saved since; the bundle writer copies live unknown files on its own, so
    /// the library still travels through a save without the token's help.
    static func withoutLibrary(_ preservation: FFPBundlePreservation?) -> FFPBundlePreservation? {
        guard var preservation, preservation.files[fileName] != nil else { return preservation }
        preservation.files.removeValue(forKey: fileName)
        return preservation
    }

    // MARK: - Normalisation

    /// The card takes tags as one typed field, so the separators are the two a
    /// jeweller is likely to type. Empty pieces are dropped.
    static func tags(from raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
    }

    /// Trimmed, non-empty, length-capped and de-duplicated case-insensitively,
    /// first spelling wins. Ordering is what the user typed, not alphabetical.
    static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maximumTagLength else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == maximumTags { break }
        }
        return result
    }

    static func validName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumNameLength,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            return nil
        }
        return trimmed
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
