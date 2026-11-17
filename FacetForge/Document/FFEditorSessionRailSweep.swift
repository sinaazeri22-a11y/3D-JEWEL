import Foundation

/// Phase 59's rail-sweep command.
///
/// The seam is deliberate and mirrors Phases 57-58. Geometry lives in
/// `FFRailSweep`, the parametric record in `FFRailSweepDefinition`, and the
/// document mutation in `FFDocument.addRailSweep`. This file is only the
/// session's wiring: it validates the two nodes the caller named, builds the
/// body before opening a history step so a refusal writes nothing, and turns one
/// commit into one undo step.
extension FFEditorSession {
    /// Sweeps the closed or open curve `profileNodeID` along `railNodeID`.
    ///
    /// The profile may be open, in which case the body is a ribbon and neither
    /// end is capped. The rail must be an open curve in the same sketch plane;
    /// the sections ride its length with the profile's centroid on the rail.
    @discardableResult
    func sweepAlongRail(
        profileNodeID: UUID,
        railNodeID: UUID,
        parameters: FFRailSweepParameters = FFRailSweepParameters()
    ) -> UUID? {
        guard profileNodeID != railNodeID else {
            documentStatus = "Choose two different curves: one profile and one rail"
            return nil
        }
        guard let profileNode = documentSession.document.node(withID: profileNodeID),
              let profilePayload = profileNode.geometry?.curve
        else {
            documentStatus = "That profile is no longer in the document"
            return nil
        }
        guard let railNode = documentSession.document.node(withID: railNodeID),
              let railPayload = railNode.geometry?.curve
        else {
            documentStatus = "That rail is no longer in the document"
            return nil
        }
        guard !isLocked(nodeID: profileNodeID) else {
            documentStatus = "That profile is on a locked layer"
            return nil
        }

        let definition = FFRailSweepDefinition(
            profile: profilePayload,
            rail: railPayload,
            parameters: parameters,
            sourceProfileNodeID: profileNodeID,
            sourceRailNodeID: railNodeID
        )
        // Build before the perform, so a self-intersecting rail or a bad
        // parameter is a sentence rather than an empty undo step.
        do {
            _ = try definition.mesh()
        } catch {
            documentStatus = (error as? LocalizedError)?.errorDescription
                ?? "Could not sweep that profile along the rail"
            return nil
        }

        var created: UUID?
        let changed = documentSession.perform("Rail sweep") { document in
            created = document.addRailSweep(
                definition,
                name: "Rail sweep",
                transform: profileNode.transform,
                layerID: profileNode.layerID
            )
        }
        guard changed, let created else {
            documentStatus = "Could not sweep that profile along the rail"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        documentStatus = definition.summary(unit: documentSession.document.displayUnit)
        return created
    }
}
