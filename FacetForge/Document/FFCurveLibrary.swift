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

/// The user's saved curves, as one JSON file in the document container.
///
/// The file sits beside the documents rather than inside one, so it survives an
/// app restart without joining any document's schema and without a format
/// version moving: `CurveLibrary.json` is not part of a `.ffp` bundle and no
/// reader of `.ffp` has to know it exists. A missing or damaged file reads as
/// an empty library instead of refusing to open the app; a save is atomic, so a
/// crash mid-write cannot truncate the entries that were already there.
struct FFCurveLibrary {
    static let fileName = "CurveLibrary.json"
    static let maximumNameLength = 80
    static let maximumTags = 8
    static let maximumTagLength = 32

    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    /// Newest first, then by name, so the card's order is stable across reads.
    func entries() -> [FFCurveLibraryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? Self.decoder.decode([FFCurveLibraryEntry].self, from: data)
        else {
            return []
        }
        return stored.sorted { lhs, rhs in
            if lhs.savedAt != rhs.savedAt {
                return lhs.savedAt > rhs.savedAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func entry(withID id: UUID) -> FFCurveLibraryEntry? {
        entries().first { $0.id == id }
    }

    /// Appends one entry and writes the whole file. Duplicate names are allowed
    /// because the id is the identity; a jeweller may keep two versions of the
    /// same scroll and tell them apart by tag.
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

    private func write(_ entries: [FFCurveLibraryEntry]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
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
