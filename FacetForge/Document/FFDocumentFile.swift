import Foundation
import UIKit

/// The Files-facing opener.
///
/// `UIDocument` is the only bridge this app needs for the system document
/// browser: Files hands a URL to the app, the document reads the same `.ffp`
/// bundle the editor uses, and the shell then routes the result into the
/// session. No document state lives here beyond the parsed result, so the
/// session remains the single owner of editing and of every mutation.
final class FFDocumentFile: UIDocument {
    private(set) var document: FFDocument?
    private(set) var content: FFPBundleContent?

    override func contents(forType typeName: String) throws -> Any {
        guard let fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try FileWrapper(url: fileURL, options: .immediate)
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let loaded = try FFDocumentStore().loadContent(from: fileURL)
        content = loaded
        document = loaded.document
    }
}
