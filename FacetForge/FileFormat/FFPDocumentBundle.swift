import Foundation

/// The result of opening a document, including what the reader did not
/// understand. `preservation` is nil for a legacy single-file document, which
/// has no bundle-level fields to carry.
struct FFPBundleContent {
    var document: FFDocument
    var preservation: FFPBundlePreservation?
    var legacySingleFile: Bool
    var thumbnail: Data?
    /// Set when the primary bundle failed integrity checks and the last good
    /// save answered instead. `nil` for a normal open.
    var recovery: FFPRecoveryNotice? = nil
}

/// Reads and writes the `.ffp` document bundle.
///
/// A bundle is a directory so geometry can stay binary, a thumbnail can be
/// replaced without rewriting the model, and unknown files from a future
/// minor writer can be copied through untouched. The writer builds a complete
/// sibling directory and swaps it in, so the destination is never a
/// half-written bundle. Before the swap the previous bundle is copied to a
/// hidden sibling, which the store can fall back to when the primary fails its
/// checksums or a block is truncated.
struct FFPDocumentBundle {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The sibling that keeps the last bundle that was known to be complete.
    /// It is a bundle in its own right, readable with the same reader.
    static func previousURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).previous",
            isDirectory: true
        )
    }

    // MARK: - Write

    func write(
        document: FFDocument,
        to url: URL,
        preservation: FFPBundlePreservation? = nil,
        thumbnail: Data? = nil
    ) throws {
        let payload = try FFPManifest.makePayload(document: document, preservation: preservation)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let temporary = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

            if !payload.buffers.isEmpty {
                let geometryDirectory = temporary.appendingPathComponent(
                    FFPFormat.geometryDirectory,
                    isDirectory: true
                )
                try fileManager.createDirectory(at: geometryDirectory, withIntermediateDirectories: true)
                for (index, data) in payload.buffers.enumerated() {
                    let name = String(format: "geometry-%03d.bin", index)
                    try data.write(to: geometryDirectory.appendingPathComponent(name))
                }
            }

            try payload.manifest.encoded(pretty: true)
                .write(to: temporary.appendingPathComponent(FFPFormat.manifestName))

            if let thumbnail {
                try thumbnail.write(to: temporary.appendingPathComponent(FFPFormat.thumbnailName))
            }

            try copyUnknownEntries(from: url, to: temporary)
            try preservePrevious(at: url)
            for (relativePath, data) in preservation?.files ?? [:] {
                try FFPManifest.validateRelativePath(relativePath)
                let target = temporary.appendingPathComponent(relativePath)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try data.write(to: target)
            }
            try writeChecksums(in: temporary)
            try swap(temporary, into: url)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// Copies entries this writer does not own. Unknown files are part of the
    /// document as far as a newer writer is concerned, so dropping them on save
    /// would silently discard data the reader promised to keep.
    private func copyUnknownEntries(from source: URL, to destination: URL) throws {
        guard isDirectory(source) else { return }
        for (relativePath, fileURL) in try files(in: source) {
            let first = relativePath.split(separator: "/").first.map(String.init) ?? relativePath
            guard !FFPFormat.ownedNames.contains(first) else { continue }
            let target = destination.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: fileURL, to: target)
        }
    }

    /// Recomputes `checksums.json` for every file in a bundle. Internal so the
    /// format tests can edit a fixture and restore a valid checksum list.
    func writeChecksums(in bundle: URL) throws {
        let entries = try files(in: bundle)
            .filter { $0.0 != FFPFormat.checksumsName }
            .sorted { $0.0 < $1.0 }
            .map { relativePath, fileURL -> FFPJSONValue in
                let data = try Data(contentsOf: fileURL)
                return .object([
                    "path": .string(relativePath),
                    "byteLength": .int(data.count),
                    "sha256": .string(FFPSHA256.hex(data))
                ])
            }
        let checksums = FFPJSONValue.object([
            "algorithm": .string("sha256"),
            "files": .array(entries)
        ])
        try checksums.encoded(pretty: true)
            .write(to: bundle.appendingPathComponent(FFPFormat.checksumsName))
    }

    /// Copies the destination to the hidden previous slot only when it is a
    /// bundle. A legacy single file has no reusable previous, and a copy
    /// failure aborts the save before the primary is touched.
    private func preservePrevious(at destination: URL) throws {
        guard isDirectory(destination) else { return }
        let previous = Self.previousURL(for: destination)
        if fileManager.fileExists(atPath: previous.path) {
            try fileManager.removeItem(at: previous)
        }
        try fileManager.copyItem(at: destination, to: previous)
    }

    private func swap(_ temporary: URL, into destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            do {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                return
            } catch {
                // Replacing a plain file with a directory is not a same-kind
                // replacement. Phase 26 owns the journal that makes this path
                // crash-safe; for now the old document is removed only after
                // the new bundle is complete on disk.
                try? fileManager.removeItem(at: destination)
            }
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    // MARK: - Read

    func read(from url: URL) throws -> FFPBundleContent {
        guard isDirectory(url) else {
            let data = try Data(contentsOf: url)
            return FFPBundleContent(
                document: try FFDocument.decoded(from: data),
                preservation: nil,
                legacySingleFile: true,
                thumbnail: nil
            )
        }

        let checksumsURL = url.appendingPathComponent(FFPFormat.checksumsName)
        guard fileManager.fileExists(atPath: checksumsURL.path) else {
            throw FFPFormatError.missingEntry(FFPFormat.checksumsName)
        }
        try verifyChecksums(Data(contentsOf: checksumsURL), in: url)

        let manifestURL = url.appendingPathComponent(FFPFormat.manifestName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw FFPFormatError.missingEntry(FFPFormat.manifestName)
        }
        let manifest: FFPJSONValue
        do {
            manifest = try FFPJSONValue.parse(Data(contentsOf: manifestURL))
        } catch {
            throw FFPFormatError.malformedManifest("manifest.json is not valid JSON")
        }
        let decoded = try FFPManifest.read(manifest: manifest) { relativePath in
            try FFPManifest.validateRelativePath(relativePath)
            let fileURL = url.appendingPathComponent(relativePath)
            guard self.fileManager.fileExists(atPath: fileURL.path) else {
                throw FFPFormatError.missingEntry(relativePath)
            }
            return try Data(contentsOf: fileURL)
        }

        let thumbnailURL = url.appendingPathComponent(FFPFormat.thumbnailName)
        var preservation = decoded.preservation
        var preservedFiles: [String: Data] = [:]
        for (relativePath, fileURL) in try files(in: url) {
            let first = relativePath.split(separator: "/").first.map(String.init) ?? relativePath
            guard !FFPFormat.ownedNames.contains(first) else { continue }
            preservedFiles[relativePath] = try Data(contentsOf: fileURL)
        }
        preservation.files = preservedFiles
        return FFPBundleContent(
            document: decoded.document,
            preservation: preservation,
            legacySingleFile: false,
            thumbnail: fileManager.fileExists(atPath: thumbnailURL.path)
                ? try Data(contentsOf: thumbnailURL)
                : nil
        )
    }

    private func verifyChecksums(_ data: Data, in bundle: URL) throws {
        let tree: FFPJSONValue
        do {
            tree = try FFPJSONValue.parse(data)
        } catch {
            throw FFPFormatError.malformedManifest("checksums.json is not valid JSON")
        }
        guard let values = tree.objectValue,
              values["algorithm"]?.stringValue == "sha256",
              let files = values["files"]?.arrayValue else {
            throw FFPFormatError.malformedManifest("checksums.json is not a sha256 list")
        }
        for entry in files {
            guard let object = entry.objectValue,
                  let path = object["path"]?.stringValue,
                  let byteLength = object["byteLength"]?.intValue,
                  let sha256 = object["sha256"]?.stringValue else {
                throw FFPFormatError.malformedManifest("checksum entry is incomplete")
            }
            try FFPManifest.validateRelativePath(path)
            let fileURL = bundle.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                throw FFPFormatError.missingEntry(path)
            }
            let fileData = try Data(contentsOf: fileURL)
            guard fileData.count == byteLength else {
                throw FFPFormatError.checksumMismatch(path)
            }
            guard FFPSHA256.hex(fileData) == sha256 else {
                throw FFPFormatError.checksumMismatch(path)
            }
        }
    }

    // MARK: - Filesystem helpers

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    /// Every regular file under `root`, keyed by a forward-slash relative path.
    private func files(in root: URL) throws -> [(String, URL)] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }
        let rootComponents = root.standardizedFileURL.pathComponents.count
        var result: [(String, URL)] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let components = fileURL.standardizedFileURL.pathComponents
            guard components.count > rootComponents else { continue }
            result.append((
                components.dropFirst(rootComponents).joined(separator: "/"),
                fileURL
            ))
        }
        return result
    }
}
