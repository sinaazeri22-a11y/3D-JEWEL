import Foundation

/// Phase 60's loft command.
///
/// The seam is deliberate and mirrors Phases 57-59. Geometry lives in `FFLoft`,
/// the parametric record in `FFLoftDefinition`, and the document mutation in
/// `FFDocument.addLoft`. This file is only the session's wiring: it validates
/// the nodes the caller named, builds the body before opening a history step so
/// a refusal writes nothing, and turns one commit into one undo step.
extension FFEditorSession {
    /// Lofts three or more curve nodes into one ordinary solid.
    ///
    /// Every section is converted to world space from its own node transform,
    /// because a loft's sections are deliberately on different planes — three
    /// circles stacked 12 mm apart are the row's own fixture. The committed node
    /// therefore carries an identity transform and a mesh already in world
    /// space; inheriting one section's placement would apply that placement
    /// twice.
    @discardableResult
    func loft(
        sectionNodeIDs: [UUID],
        parameters: FFLoftParameters = FFLoftParameters()
    ) -> UUID? {
        guard sectionNodeIDs.count >= FFLoftParameters.minimumSections else {
            documentStatus = FFLoftError
                .notEnoughSections(sectionNodeIDs.count)
                .errorDescription ?? "A loft needs at least three sections"
            return nil
        }
        guard Set(sectionNodeIDs).count == sectionNodeIDs.count else {
            documentStatus = "Choose each section once"
            return nil
        }

        var nodes: [FFNode] = []
        nodes.reserveCapacity(sectionNodeIDs.count)
        for id in sectionNodeIDs {
            guard let node = documentSession.document.node(withID: id),
                  node.geometry?.curve != nil
            else {
                documentStatus = "One of those sections is no longer a curve in the document"
                return nil
            }
            guard !isLocked(nodeID: id) else {
                documentStatus = "\(node.name) is on a locked layer"
                return nil
            }
            nodes.append(node)
        }

        let closedness = Set(nodes.map { $0.geometry?.curve?.isClosed ?? false })
        guard closedness.count == 1 else {
            documentStatus = FFLoftError.mixedSectionStyles.errorDescription
                ?? "Every section must be closed, or every one open"
            return nil
        }

        let sections = nodes.compactMap { Self.loftSection(for: $0) }
        guard sections.count == nodes.count else {
            documentStatus = "One of those sections has a collapsed placement"
            return nil
        }

        let definition = FFLoftDefinition(
            sections: sections,
            parameters: parameters,
            sourceSectionNodeIDs: sectionNodeIDs
        )
        // Build before the perform, so a coincident or degenerate section is a
        // sentence rather than an empty undo step.
        do {
            _ = try definition.mesh()
        } catch {
            documentStatus = (error as? LocalizedError)?.errorDescription
                ?? "Could not loft those sections"
            return nil
        }

        var created: UUID?
        let changed = documentSession.perform("Loft") { document in
            created = document.addLoft(
                definition,
                name: "Loft",
                transform: .identity,
                layerID: nodes.last?.layerID
            )
        }
        guard changed, let created else {
            documentStatus = "Could not loft those sections"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        documentStatus = definition.summary(unit: documentSession.document.displayUnit)
        return created
    }

    /// One curve node as a world-space loft section. The node's full basis is
    /// carried through, not a normalised one, so a scaled node still lofts at the
    /// size it draws.
    static func loftSection(for node: FFNode) -> FFLoftSection? {
        guard let payload = node.geometry?.curve else { return nil }
        let matrix = node.transform.matrix
        let origin = matrix.transformedPoint(.zero)
        let xAxis = matrix.transformedVector(.unitX)
        let yAxis = matrix.transformedVector(.unitY)
        return FFLoftSection(
            payload: payload,
            origin: FFPoint3(origin),
            xAxis: FFPoint3(xAxis),
            yAxis: FFPoint3(yAxis)
        )
    }
}
