import Foundation

/// The parametric record of one committed extrusion.
///
/// The document stores this beside the body it produced. The mesh is the body
/// the viewport and the exporter use; the record is what says where that mesh
/// came from, so a later phase can regenerate or edit it from parameters instead
/// of reverse-engineering triangles. The profile payload is copied in, not
/// referenced, so renaming, moving or deleting the source curve cannot change
/// what the extrusion means.
struct FFExtrusionDefinition: Codable, Equatable, Sendable {
    var profile: FFCurvePayload
    var parameters: FFExtrusionParameters
    /// The curve the body was made from, for the object tree's provenance.
    /// Optional so a record written without a source curve still decodes.
    var sourceNodeID: UUID?

    init(
        profile: FFCurvePayload,
        parameters: FFExtrusionParameters,
        sourceNodeID: UUID? = nil
    ) {
        self.profile = profile
        self.parameters = parameters
        self.sourceNodeID = sourceNodeID
    }

    /// Rebuilds the body from the record. This is the only function that turns
    /// the stored parameters back into triangles, so the mesh written at commit
    /// and the mesh a later edit regenerates cannot drift apart.
    func mesh() throws -> IndexedMesh {
        let sampled = try FFSurfaceSweepProfile(payload: profile)
        return try FFExtrusion(profile: sampled, parameters: parameters).mesh()
    }

    /// The one spoken line both the panel and the object tree use.
    func summary(unit: FFLengthUnit) -> String {
        var parts = [
            "Extrude \(FFPrecision.lengthString(millimetres: parameters.height, unit: unit))"
        ]
        if let detail = parameters.detail { parts.append(detail) }
        if parameters.isSymmetric { parts.append("symmetric") }
        if parameters.direction == .reversed, !parameters.isSymmetric { parts.append("reversed") }
        if parameters.caps == .open { parts.append("open") }
        return parts.joined(separator: " · ")
    }
}

/// The read-only projection a panel or a test reads: which node owns the record
/// and what the committed body currently is. The view never keeps a second copy
/// that could disagree with the document.
struct FFExtrusionInfo: Equatable, Sendable {
    var nodeID: UUID
    var name: String
    var definition: FFExtrusionDefinition
    var triangleCount: Int
}

extension FFDocument {
    /// The extrusion record for one node, or nil when that node is not a
    /// parametric extrusion.
    func extrusionInfo(for id: UUID) -> FFExtrusionInfo? {
        guard let node = node(withID: id), let definition = node.extrusion,
              let payload = node.geometry?.mesh
        else { return nil }
        return FFExtrusionInfo(
            nodeID: id,
            name: node.name,
            definition: definition,
            triangleCount: payload.triangles.count
        )
    }

    /// Commits an extrusion as one ordinary solid node, inserted directly above
    /// the curve it was made from.
    ///
    /// The mesh is built here, from the record that is about to be stored, so a
    /// document can never hold a record and a body that disagree. The node
    /// inherits the source curve's placement, which is what puts the body on the
    /// sketch plane rather than at the world origin, and takes the source's
    /// layer so a body made from a sketch on a layer draws on that layer.
    @discardableResult
    mutating func addExtrusion(
        _ definition: FFExtrusionDefinition,
        name: String,
        transform: FFTransform = .identity,
        layerID: UUID? = nil
    ) -> UUID? {
        guard let mesh = try? definition.mesh() else { return nil }
        let node = FFNode(
            name: uniqueNodeName(name),
            transform: transform,
            geometry: .mesh(FFMeshPayload(mesh)),
            kind: .solid,
            layerID: layerID ?? currentLayerID,
            extrusion: definition
        )
        let source = definition.sourceNodeID
        let parent = source.flatMap { parentID(of: $0) }
        let siblings = parent.flatMap { node(withID: $0)?.children } ?? rootNodes
        let index = source
            .flatMap { id in siblings.firstIndex { $0.id == id } }
            .map { $0 + 1 }
            ?? siblings.count
        guard insertNode(node, into: parent, at: index) else { return nil }
        return node.id
    }
}
