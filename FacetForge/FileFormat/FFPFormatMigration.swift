import Foundation

/// One revision step in the `.ffp` version ladder.
///
/// A step names what changed between two adjacent `formatVersion`s. The reader
/// walks the ladder in order, so adding a revision means adding a step and its
/// body rewrite rather than a second code path in the bundle reader.
struct FFPMigrationStep: Equatable, Sendable {
    /// The version a file was written at.
    let from: Int
    /// The version the step produces.
    let to: Int
    /// One sentence a user can read.
    let summary: String
}

/// What a reader did to bring an older file up to the version this build
/// writes. A file already at the current version produces no report.
struct FFPMigrationReport: Equatable, Sendable {
    let from: Int
    let to: Int
    let steps: [FFPMigrationStep]

    /// The line the shell shows after opening an upgraded document.
    var headline: String { "Upgraded from format \(from) to \(to)" }

    /// Every step in one sentence, for a detail view or a log line.
    var summary: String {
        ([headline] + steps.map { "\($0.from) → \($0.to): \($0.summary)" })
            .joined(separator: " · ")
    }
}

/// The ordered version ladder for the `.ffp` container.
///
/// Version 2 changes the container, not the document body: a version-2 file
/// must list every owned file in `checksums.json` (the manifest included) and
/// its geometry table must resolve one-to-one against the nodes in the
/// document. A version-1 file is still read, under version-1 rules, and the
/// next save writes version 2 — which is why an upgrade needs a report rather
/// than a rewrite.
enum FFPFormatMigration {
    /// The ladder, lowest first. Every adjacent pair is exactly one revision.
    /// Named `ladder` rather than `steps` so the reader can also expose
    /// `steps(from:to:)` without overloading a stored property.
    static let ladder: [FFPMigrationStep] = [
        FFPMigrationStep(
            from: 1,
            to: 2,
            summary: "format 2 requires checksums.json to cover every owned file and the geometry table to resolve one-to-one with the document, so both are verified instead of assumed"
        ),
    ]

    /// The steps needed to read a file written at `version` with this build.
    static func steps(from version: Int, to target: Int = FFPFormat.version) throws -> [FFPMigrationStep] {
        guard version <= target else {
            throw FFPFormatError.unsupportedFormatVersion(version)
        }
        guard version >= 1 else {
            throw FFPFormatError.malformedManifest("formatVersion \(version) is not a known revision")
        }
        var needed: [FFPMigrationStep] = []
        var current = version
        while current < target {
            guard let step = ladder.first(where: { $0.from == current }) else {
                throw FFPFormatError.malformedManifest(
                    "no migration path from format \(current) to \(target)"
                )
            }
            needed.append(step)
            current = step.to
        }
        return needed
    }

    /// The report for reading a file written at `version`, or nil when it is
    /// already the current version.
    static func report(from version: Int, to target: Int = FFPFormat.version) throws -> FFPMigrationReport? {
        let needed = try steps(from: version, to: target)
        guard !needed.isEmpty else { return nil }
        return FFPMigrationReport(from: version, to: target, steps: needed)
    }

    /// Runs the ladder over a document tree.
    ///
    /// Version 1 → 2 rewrites nothing in the body: a tree a version-1 writer
    /// produced already has the shape version 2 reads. The step exists so the
    /// reader has one implementation to walk and a future body revision is a
    /// `case` here instead of a branch in the bundle reader.
    static func migrate(
        documentTree: FFPJSONValue,
        from version: Int,
        to target: Int = FFPFormat.version
    ) throws -> (tree: FFPJSONValue, report: FFPMigrationReport?) {
        let needed = try steps(from: version, to: target)
        var tree = documentTree
        for step in needed {
            tree = try apply(step, to: tree)
        }
        let report = needed.isEmpty
            ? nil
            : FFPMigrationReport(from: version, to: target, steps: needed)
        return (tree, report)
    }

    private static func apply(_ step: FFPMigrationStep, to tree: FFPJSONValue) throws -> FFPJSONValue {
        switch (step.from, step.to) {
        case (1, 2):
            return tree
        default:
            throw FFPFormatError.malformedManifest(
                "no body rewrite is implemented for format \(step.from) → \(step.to)"
            )
        }
    }

    /// Writes the bundle a version-1 app could have produced: the same files,
    /// `formatVersion` 1, and a checksum list covering exactly what was written.
    ///
    /// This is the migration tests' and the launch fixture's only way to obtain
    /// an old file. The shipping writer always emits the current version, and
    /// no app code reads or writes version 1 except through the reader's
    /// downgrade path.
    static func writingVersion1Copy(
        of source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        if source.standardizedFileURL != destination.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        let manifestURL = destination.appendingPathComponent(FFPFormat.manifestName)
        let manifest = try FFPJSONValue.parse(Data(contentsOf: manifestURL))
        try manifest.setting("formatVersion", to: .int(1))
            .encoded(pretty: true)
            .write(to: manifestURL)
        try FFPDocumentBundle(fileManager: fileManager).writeChecksums(in: destination)
    }
}
