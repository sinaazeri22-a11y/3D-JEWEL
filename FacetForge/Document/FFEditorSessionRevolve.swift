import Foundation

/// Phase 58's revolution commands.
///
/// The seam is deliberate and mirrors Phase 57's. Geometry lives in `FFRevolve`,
/// the ring body primitive in `FFRingBody`, the parametric record in
/// `FFRevolveDefinition`, and the document mutations in
/// `FFDocument.addRevolve` and `FFDocument.addRingBody`. This file is only the
/// session's wiring: it holds the two tool choices, rebuilds the live preview
/// when one changes, and turns one commit into one undo step. Nothing here
/// decides what a revolution is; it only passes the numbers the geometry owner
/// already understands.
extension FFEditorSession {
    var revolveDirection: FFRevolveDirection { revolveSweepDirection }
    var revolveCaps: FFRevolveCaps { revolveSweepCaps }

    @discardableResult
    func setRevolveDirection(_ direction: FFRevolveDirection) -> Bool {
        guard revolveSweepDirection != direction else { return false }
        revolveSweepDirection = direction
        return rebuildSurfacePreview()
    }

    @discardableResult
    func setRevolveCaps(_ caps: FFRevolveCaps) -> Bool {
        guard revolveSweepCaps != caps else { return false }
        revolveSweepCaps = caps
        return rebuildSurfacePreview()
    }

    /// Commits the live revolution preview as one solid: one node, one undo
    /// step, one journal entry.
    ///
    /// The profile stays in the document, exactly as the extrusion commit leaves
    /// its sketch, so a jeweller can still edit the curve the body came from.
    /// The commit is refused when the source curve was locked or deleted while
    /// the preview was open, because at that moment the body would no longer
    /// match anything the user can see.
    @discardableResult
    func commitRevolve() -> UUID? {
        guard let preview = surfacePreview, preview.mode == .revolve else {
            documentStatus = "Open a Revolve preview to commit a solid"
            return nil
        }
        guard let node = documentSession.document.node(withID: preview.nodeID),
              let payload = node.geometry?.curve
        else {
            documentStatus = "That profile is no longer in the document"
            return nil
        }
        guard !isLocked(nodeID: preview.nodeID) else {
            documentStatus = "That curve is on a locked layer"
            return nil
        }
        let definition = FFRevolveDefinition(
            profile: payload,
            parameters: revolveParameters,
            sourceNodeID: preview.nodeID
        )
        var created: UUID?
        let changed = documentSession.perform("Revolve") { document in
            created = document.addRevolve(
                definition,
                name: "Revolve",
                transform: node.transform,
                layerID: node.layerID
            )
        }
        guard changed, let created else {
            documentStatus = "Could not revolve that profile"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        endSurfacePreview()
        documentStatus = definition.summary(unit: documentSession.document.displayUnit)
        return created
    }

    /// Creates the row's ring body primitive as one ordinary solid node.
    ///
    /// The command exists on the session rather than only on the document so the
    /// primitive is a real user capability with one undo step, the same way every
    /// other created body in this app is committed. It has no control in the
    /// shell yet; the closing note for this phase says so rather than implying a
    /// button that is not there.
    @discardableResult
    func addRingBody(
        majorRadius: Double = FFRingBody.defaultMajorRadius,
        minorRadius: Double = FFRingBody.defaultMinorRadius
    ) -> UUID? {
        let body = FFRingBody(majorRadius: majorRadius, minorRadius: minorRadius)
        if let error = body.validationError {
            documentStatus = error.errorDescription ?? "That ring body is not valid"
            return nil
        }
        var created: UUID?
        let changed = documentSession.perform("Ring body") { document in
            created = document.addRingBody(body, name: "Ring body")
        }
        guard changed, let created else {
            documentStatus = "Could not build that ring body"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        documentStatus = body.summary(unit: documentSession.document.displayUnit)
        return created
    }
}
