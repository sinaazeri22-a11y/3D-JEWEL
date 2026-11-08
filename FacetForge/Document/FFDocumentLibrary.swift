import Foundation

/// One row of the in-app document browser. The browser lists files, so the
/// card title is the file's base name: renaming visibly changes it, and a
/// duplicate is distinguishable before it is opened. The document's internal
/// name is a title inside the bundle, not a file identity.
struct FFDocumentSummary: Identifiable, Equatable, Sendable {
    var url: URL
    var modifiedAt: Date
    var thumbnail: Data?

    var id: URL { url }
    var fileName: String { url.deletingPathExtension().lastPathComponent }
    var displayName: String { fileName }
}

enum FFLibraryError: Error, Equatable, LocalizedError {
    case invalidName
    case nameTaken(String)
    case cannotModifyOpenDocument

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "A document name cannot be empty or contain a path separator."
        case .nameTaken(let name):
            return "A document named \(name) already exists."
        case .cannotModifyOpenDocument:
            return "Close or switch the open document before deleting it."
        }
    }
}

/// Reads and mutates the Documents folder for the browser.
///
/// The library only touches files. Rename, duplicate and delete are the
/// session's commands; it calls this type and republishes the list. A `.ffp`
/// bundle keeps its `preview.png` and `manifest.json` beside the geometry, so
/// the browser can show a real thumbnail and the document's own name without
/// loading the model.
struct FFDocumentLibrary {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Recents order: newest first, then display name. Hidden siblings
    /// (`.<name>.previous`, `.<name>.journal`) are skipped because the scan
    /// starts from non-hidden entries only.
    func documents() -> [FFDocumentSummary] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "ffp" }
            .compactMap { summary(for: Self.canonicalURL($0)) }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt {
                    return $0.modifiedAt > $1.modifiedAt
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    func summary(for url: URL) -> FFDocumentSummary? {
        let url = Self.canonicalURL(url)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return FFDocumentSummary(
            url: url,
            modifiedAt: values?.contentModificationDate ?? Date.distantPast,
            thumbnail: thumbnailData(at: url)
        )
    }

    /// A scan of the folder hands back directory-hinted URLs (a trailing slash)
    /// for packages, while a save, rename or open produces the plain file URL.
    /// They are the same file but not the same `URL`, so every identity the
    /// browser compares — selection, rename, duplicate, delete — must use one
    /// form. This is that form.
    static func canonicalURL(_ url: URL) -> URL {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return URL(filePath: path, directoryHint: .notDirectory)
    }

    /// Whether two URLs name the same bundle, whichever of them came from a
    /// folder scan. Used for every destructive or retargeting decision, so a
    /// directory-hinted URL can never slip past the open-document guard.
    static func isSameDocument(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalURL(lhs).standardizedFileURL == canonicalURL(rhs).standardizedFileURL
    }

    /// Renames the bundle and carries its recovery siblings to the new base
    /// name. The document name inside the manifest is a user-facing title, not
    /// the file identity, so it is intentionally untouched.
    @discardableResult
    func rename(_ url: URL, to rawName: String) throws -> URL {
        guard let base = Self.sanitizedName(rawName) else {
            throw FFLibraryError.invalidName
        }
        let target = directory
            .appendingPathComponent(base)
            .appendingPathExtension("ffp")
        if Self.isSameDocument(target, url) {
            return Self.canonicalURL(url)
        }
        guard !fileManager.fileExists(atPath: target.path) else {
            throw FFLibraryError.nameTaken(base)
        }

        try fileManager.moveItem(at: url, to: target)
        let previous = FFPDocumentBundle.previousURL(for: url)
        if fileManager.fileExists(atPath: previous.path) {
            try? fileManager.moveItem(
                at: previous,
                to: FFPDocumentBundle.previousURL(for: target)
            )
        }
        let journal = FFEditJournal.defaultDirectory(for: url)
        if fileManager.fileExists(atPath: journal.path) {
            try? fileManager.moveItem(
                at: journal,
                to: FFEditJournal.defaultDirectory(for: target)
            )
        }
        return target
    }

    /// Copies the document bundle, never its previous save or crash journal:
    /// a duplicate is a new document, and inheriting recovery state from
    /// another file's session would be surprising and unsafe.
    func duplicate(_ url: URL) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = "\(base) copy"
        var target = directory
            .appendingPathComponent(candidate)
            .appendingPathExtension("ffp")
        var index = 2
        while fileManager.fileExists(atPath: target.path) {
            candidate = "\(base) copy \(index)"
            target = directory
                .appendingPathComponent(candidate)
                .appendingPathExtension("ffp")
            index += 1
        }
        try fileManager.copyItem(at: url, to: target)
        return target
    }

    func delete(_ url: URL) throws {
        try fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: FFPDocumentBundle.previousURL(for: url))
        try? fileManager.removeItem(at: FFEditJournal.defaultDirectory(for: url))
    }

    /// Case-insensitive match over what the card shows. Kept beside the scan
    /// so the browser has no private search rule of its own.
    static func matches(_ summary: FFDocumentSummary, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return summary.displayName.localizedCaseInsensitiveContains(needle)
            || summary.fileName.localizedCaseInsensitiveContains(needle)
    }

    /// The file-safe form of a typed name. Path separators, control characters
    /// and a leading dot are rejected rather than silently rewritten, so the
    /// browser can tell the user why the rename did not happen.
    static func sanitizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return trimmed
    }

    // MARK: - Reading bundle metadata

    private func thumbnailData(at url: URL) -> Data? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return try? Data(contentsOf: url.appendingPathComponent(FFPFormat.thumbnailName))
    }
}
