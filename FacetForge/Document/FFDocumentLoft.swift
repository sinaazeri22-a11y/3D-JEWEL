import Foundation

/// The parametric record of one committed loft.
///
/// The document stores this beside the body it produced. The mesh is the body
/// the viewport and the exporter use; the record is what says where that mesh
/// came from, so a later phase can regenerate or edit it from parameters instead
/// of reverse-engineering triangles. Every section payload and plane is copied
/// in, not referenced, so renaming, moving or deleting a source curve cannot
/// change what the loft means.
struct FFLoftDefinition: Codable, Equatable, Sendable {
    var sections: [FFLoftSection]
    var parameters: FFLoftParameters
    /// The curve nodes the body was made from, in section order, for the object
    /// tree's provenance. Empty when the sections came from somewhere a document
    /// no longer knows about.
    var sourceSectionNodeIDs: [UUID]

    init(
        sections: [FFLoftSection],
        parameters: FFLoftParameters = FFLoftParameters(),
        sourceSectionNodeIDs: [UUID] = []
    ) {
        self.sections = sections
        self.parameters = parameters
        self.sourceSectionNodeIDs = sourceSectionNodeIDs
    }

    /// Rebuilds the body from the record. This is the only function that turns
    /// the stored sections and parameters back into triangles, so the mesh
    /// written at commit and the mesh a later edit regenerates cannot drift
    /// apart.
    func mesh() throws -> IndexedMesh {
        try FFLoft(sections: sections, parameters: parameters).mesh()
    }

    /// The one spoken line both a panel and the object tree use.
    func summary(unit: FFLengthUnit) -> String {
        var parts = ["Loft", "\(sections.count) sections"]
        if let detail = parameters.detail { parts.append(detail) }
        if let length = try? span(unit: unit) {
            parts.append(length)
        }
        return parts.joined(separator: " · ")
    }

    /// The straight-line distance from the first section's centre to the last,
    /// which is the span a jeweller reads off a lofted shank.
    func span(unit: FFLengthUnit) throws -> String {
        guard let first = sections.first?.origin, let last = sections.last?.origin else {
            throw FFLoftError.notEnoughSections(sections.count)
        }
        let distance = first.vector.distance(to: last.vector)
        return FFPrecision.lengthString(millimetres: distance, unit: unit)
    }
}

/// The read-only projection a panel or a test reads: which node owns the record
/// and what the committed body currently is. The view never keeps a second copy
/// that could disagree with the document.
struct FFLoftInfo: Equatable, Sendable {
    var nodeID: UUID
    var name: String
    var definition: FFLoftDefinition
    var triangleCount: Int
}

extension FFDocument {
    /// The loft record for one node, or nil when that node is not a parametric
    /// loft.
    func loftInfo(for id: UUID) -> FFLoftInfo? {
        guard let node = node(withID: id), let definition = node.loft,
              let payload = node.geometry?.mesh
        else { return nil }
        return FFLoftInfo(
            nodeID: id,
            name: node.name,
            definition: definition,
            triangleCount: payload.triangles.count
        )
    }

    /// Commits a loft as one ordinary solid node, inserted directly above the
    /// last section it was made from.
    ///
    /// The mesh is built here, from the record that is about to be stored, so a
    /// document can never hold a record and a body that disagree. The node
    /// inherits the last section curve's placement and layer, which keeps the
    /// body on the sketch plane its sections were drawn on; every section curve
    /// stays in the document.
    @discardableResult
    mutating func addLoft(
        _ definition: FFLoftDefinition,
        name: String,
        transform: FFTransform = .identity,
        layerID: UUID? = nil
    ) -> UUID? {
        guard let mesh = try? definition.mesh() else { return nil }
        let created = FFNode(
            name: uniqueNodeName(name),
            transform: transform,
            geometry: .mesh(FFMeshPayload(mesh)),
            kind: .solid,
            layerID: layerID ?? currentLayerID,
            loft: definition
        )
        let source = definition.sourceSectionNodeIDs.last
        let parent = source.flatMap { parentID(of: $0) }
        let siblings = parent.flatMap { self.node(withID: $0)?.children } ?? rootNodes
        var index = siblings.count
        if let source, let position = siblings.firstIndex(where: { $0.id == source }) {
            index = position + 1
        }
        guard insertNode(created, into: parent, at: index) else { return nil }
        return created.id
    }
}
