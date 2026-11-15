import Foundation

/// Phase 57's extrusion commands.
///
/// The seam is deliberate. Geometry lives in `FFExtrusion`, the parametric
/// record in `FFExtrusionDefinition`, and the document mutation in
/// `FFDocument.addExtrusion`. This file is only the session's wiring: it holds
/// the four tool choices, rebuilds the live preview when one changes, and turns
/// one commit into one undo step. Nothing here decides what a draft is; it only
/// passes the numbers the geometry owner already understands.
extension FFEditorSession {
    var extrusionDraftDegrees: Double { extrudeDraftDegrees }
    var extrusionDirection: FFExtrudeDirection { extrudeDirection }
    var extrusionIsSymmetric: Bool { extrudeIsSymmetric }
    var extrusionCaps: FFExtrudeCaps { extrudeCaps }

    /// A draft is clamped to the range the builder accepts, the same way Phase
    /// 54 clamped a height. A held stepper therefore stops at the limit instead
    /// of filling the card with an error it cannot clear.
    @discardableResult
    func setExtrusionDraft(_ degrees: Double) -> Bool {
        guard degrees.isFinite else { return false }
        let clamped = FFMath.clamp(
            degrees,
            to: (-FFExtrusionParameters.maximumDraftDegrees)...FFExtrusionParameters.maximumDraftDegrees
        )
        guard abs(clamped - extrudeDraftDegrees) > 1e-9 else { return false }
        extrudeDraftDegrees = clamped
        return rebuildSurfacePreview()
    }

    @discardableResult
    func setExtrusionDirection(_ direction: FFExtrudeDirection) -> Bool {
        guard extrudeDirection != direction else { return false }
        extrudeDirection = direction
        return rebuildSurfacePreview()
    }

    @discardableResult
    func setExtrusionSymmetric(_ isSymmetric: Bool) -> Bool {
        guard extrudeIsSymmetric != isSymmetric else { return false }
        extrudeIsSymmetric = isSymmetric
        return rebuildSurfacePreview()
    }

    @discardableResult
    func setExtrusionCaps(_ caps: FFExtrudeCaps) -> Bool {
        guard extrudeCaps != caps else { return false }
        extrudeCaps = caps
        return rebuildSurfacePreview()
    }

    /// Commits the live extrusion preview as one solid: one node, one undo step,
    /// one journal entry.
    ///
    /// The profile stays in the document. A jeweller who drafted a shank from a
    /// sketch can still edit the sketch, and the body still says which curve it
    /// came from, which is the difference between a feature and a mesh dump. The
    /// commit is refused when the source curve was locked or deleted while the
    /// preview was open, because at that moment the body would no longer match
    /// anything the user can see.
    @discardableResult
    func commitExtrusion() -> UUID? {
        guard let preview = surfacePreview, preview.mode == .extrude else {
            documentStatus = "Open an Extrude preview to commit a solid"
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
        let definition = FFExtrusionDefinition(
            profile: payload,
            parameters: extrusionParameters,
            sourceNodeID: preview.nodeID
        )
        var created: UUID?
        let changed = documentSession.perform("Extrude") { document in
            created = document.addExtrusion(
                definition,
                name: "Extrusion",
                transform: node.transform,
                layerID: node.layerID
            )
        }
        guard changed, let created else {
            documentStatus = "Could not extrude that profile"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        endSurfacePreview()
        documentStatus = definition.summary(unit: documentSession.document.displayUnit)
        return created
    }
}
