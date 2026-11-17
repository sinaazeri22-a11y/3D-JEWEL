import Foundation

/// The parametric record of one committed rail sweep.
///
/// The document stores this beside the body it produced. The mesh is the body
/// the viewport and the exporter use; the record is what says where that mesh
/// came from, so a later phase can regenerate or edit it from parameters instead
/// of reverse-engineering triangles. Both payloads are copied in, not
/// referenced, so renaming, moving or deleting either source curve cannot change
/// what the sweep means.
struct FFRailSweepDefinition: Codable, Equatable, Sendable {
    var profile: FFCurvePayload
    var rail: FFCurvePayload
    var parameters: FFRailSweepParameters
    /// The profile curve the body was made from, for the object tree's
    /// provenance.
    var sourceProfileNodeID: UUID?
    /// The rail curve the body was made from.
    var sourceRailNodeID: UUID?

    init(
        profile: FFCurvePayload,
        rail: FFCurvePayload,
        parameters: FFRailSweepParameters = FFRailSweepParameters(),
        sourceProfileNodeID: UUID? = nil,
        sourceRailNodeID: UUID? = nil
    ) {
        self.profile = profile
        self.rail = rail
        self.parameters = parameters
        self.sourceProfileNodeID = sourceProfileNodeID
        self.sourceRailNodeID = sourceRailNodeID
    }

    /// Rebuilds the body from the record. This is the only function that turns
    /// the stored parameters back into triangles, so the mesh written at commit
    /// and the mesh a later edit regenerates cannot drift apart.
    func mesh() throws -> IndexedMesh {
        let sampledProfile = try FFSurfaceSweepProfile(payload: profile)
        let sampledRail = try FFRailPath(payload: rail)
        return try FFRailSweep(
            profile: sampledProfile,
            rail: sampledRail,
            parameters: parameters
        ).mesh()
    }

    /// The one spoken line both the panel and the object tree use.
    func summary(unit: FFLengthUnit) -> String {
        var parts = ["Rail sweep"]
        if let path = try? FFRailPath(payload: rail) {
            parts.append(FFPrecision.lengthString(millimetres: path.length, unit: unit))
        }
        if let detail = parameters.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

/// The read-only projection a panel or a test reads: which node owns the record
/// and what the committed body currently is. The view never keeps a second copy
/// that could disagree with the document.
struct FFRailSweepInfo: Equatable, Sendable {
    var nodeID: UUID
    var name: String
    var definition: FFRailSweepDefinition
    var triangleCount: Int
}

extension FFDocument {
    /// The rail-sweep record for one node, or nil when that node is not a
    /// parametric rail sweep.
    func railSweepInfo(for id: UUID) -> FFRailSweepInfo? {
        guard let node = node(withID: id), let definition = node.railSweep,
              let payload = node.geometry?.mesh
        else { return nil }
        return FFRailSweepInfo(
            nodeID: id,
            name: node.name,
            definition: definition,
            triangleCount: payload.triangles.count
        )
    }

    /// Commits a rail sweep as one ordinary solid node, inserted directly above
    /// the profile it was made from.
    ///
    /// The mesh is built here, from the record that is about to be stored, so a
    /// document can never hold a record and a body that disagree. The node
    /// inherits the profile curve's placement and layer, which is what puts the
    /// body on the sketch plane rather than at the world origin; the rail is
    /// copied into the record and stays in the document.
    @discardableResult
    mutating func addRailSweep(
        _ definition: FFRailSweepDefinition,
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
            railSweep: definition
        )
        let source = definition.sourceProfileNodeID
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
