import Foundation

/// Save and load for `FFDocument` on top of the `.ffp` bundle.
///
/// The bundle writer builds a complete sibling directory and swaps it in, so a
/// crash or a full disk can never leave a half-written document behind. A
/// document saved before Phase 25 is a single JSON file; the bundle reader
/// detects that shape and decodes it, and the next save writes a bundle.
struct FFDocumentStore {
    let fileManager: FileManager
    private let bundle: FFPDocumentBundle

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.bundle = FFPDocumentBundle(fileManager: fileManager)
    }

    func save(
        _ document: FFDocument,
        to url: URL,
        preservation: FFPBundlePreservation? = nil,
        thumbnail: Data? = nil
    ) throws {
        try bundle.write(
            document: document,
            to: url,
            preservation: preservation,
            thumbnail: thumbnail
        )
    }

    func load(from url: URL) throws -> FFDocument {
        try loadContent(from: url).document
    }

    /// Loads the document and the preservation token. Callers that keep the
    /// token can rewrite the bundle without dropping fields or files the
    /// reader did not understand.
    ///
    /// When the primary bundle fails an integrity check, the hidden previous
    /// bundle answers instead and the content carries a notice naming the
    /// damaged entry. A newer format version never falls back, and a damaged
    /// primary is never deleted or rewritten by a read.
    func loadContent(from url: URL) throws -> FFPBundleContent {
        do {
            return try bundle.read(from: url)
        } catch let error as FFPFormatError where error.allowsLastGoodRecovery {
            let previous = FFPDocumentBundle.previousURL(for: url)
            guard let recovered = try? bundle.read(from: previous) else {
                throw error
            }
            var content = recovered
            content.recovery = FFPRecoveryNotice(
                message: "Recovered the last good save of \(url.lastPathComponent) because the current bundle is damaged: \(error.recoveryDescription). The damaged bundle was left in place.",
                damagedEntry: error.damagedEntry
            )
            return content
        }
    }
}

/// A single reversible edit. `before` and `after` are full snapshots: version
/// zero of the document is small enough that snapshots are simpler and safer
/// than invertible diffs, and they make undo exact by construction.
struct FFDocumentChange: Equatable, Sendable {
    let name: String
    let coalescingKey: String?
    let before: FFDocument
    let after: FFDocument
}

/// Editing session with a bounded undo history.
///
/// Consecutive edits that share a coalescing key (a drag, a slider, typing in
/// one field) collapse into one undo step. Any edit after an undo starts a new
/// step, so redo can never be captured by a stale merge. The history holds at
/// most 100 steps; older steps are dropped and cannot be recovered, which is
/// the documented behaviour of the command stack.
final class FFDocumentSession {
    static let historyLimit = 100

    private(set) var document: FFDocument
    private(set) var undoStack: [FFDocumentChange] = []
    private(set) var redoStack: [FFDocumentChange] = []

    /// Number of edits that actually changed the document, including edits
    /// whose undo step was later dropped by the history cap.
    private(set) var appliedChangeCount = 0

    init(document: FFDocument = FFDocument()) {
        self.document = document
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoDepth: Int { undoStack.count }
    var redoDepth: Int { redoStack.count }
    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    /// Applies `mutation` to a draft and commits it only when the document
    /// actually changed. Returns whether an edit was recorded.
    @discardableResult
    func perform(
        _ name: String,
        coalescingKey: String? = nil,
        _ mutation: (inout FFDocument) throws -> Void
    ) rethrows -> Bool {
        let before = document
        var draft = document
        try mutation(&draft)
        guard draft != before else { return false }

        let hadRedo = !redoStack.isEmpty
        document = draft
        appliedChangeCount += 1
        redoStack.removeAll()

        if !hadRedo,
           let key = coalescingKey,
           let last = undoStack.last,
           last.coalescingKey == key {
            undoStack[undoStack.count - 1] = FFDocumentChange(
                name: last.name,
                coalescingKey: key,
                before: last.before,
                after: draft
            )
        } else {
            undoStack.append(FFDocumentChange(
                name: name,
                coalescingKey: coalescingKey,
                before: before,
                after: draft
            ))
            if undoStack.count > Self.historyLimit {
                undoStack.removeFirst(undoStack.count - Self.historyLimit)
            }
        }
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let change = undoStack.popLast() else { return false }
        document = change.before
        redoStack.append(change)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let change = redoStack.popLast() else { return false }
        document = change.after
        undoStack.append(change)
        return true
    }

    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
