import Foundation

/// The parametric record of one committed revolution.
///
/// The document stores this beside the body it produced. The mesh is the body
/// the viewport and the exporter use; the record is what says where that mesh
/// came from, so a later phase can regenerate or edit it from parameters instead
/// of reverse-engineering triangles. The profile payload is copied in, not
/// referenced, so renaming, moving or deleting the source curve cannot change
/// what the revolution means.
struct FFRevolveDefinition: Codable, Equatable, Sendable {
    var profile: FFCurvePayload
    var parameters: FFRevolveParameters
    /// The curve the body was made from, for the object tree's provenance.
    /// Optional so a record written without a source curve still decodes, which
    /// is what a ring body primitive is.
    var sourceNodeID: UUID?
    /// The angular resolution the body was tessellated at. Nil derives it from
    /// the angle, which is what an ordinary revolve does. A ring body commits
    /// its own count, so the record regenerates the body it baked rather than a
    /// coarser one whose volume would miss the row's tolerance.
    var angularSegments: Int?

    init(
        profile: FFCurvePayload,
        parameters: FFRevolveParameters,
        sourceNodeID: UUID? = nil,
        angularSegments: Int? = nil
    ) {
        self.profile = profile
        self.parameters = parameters
        self.sourceNodeID = sourceNodeID
        self.angularSegments = angularSegments
    }

    /// Rebuilds the body from the record. This is the only function that turns
    /// the stored parameters back into triangles, so the mesh written at commit
    /// and the mesh a later edit regenerates cannot drift apart.
    func mesh() throws -> IndexedMesh {
        let sampled = try FFSurfaceSweepProfile(payload: profile)
        return try FFRevolve(
            profile: sampled,
            parameters: parameters,
            angularSegments: angularSegments
        ).mesh()
    }

    /// The one spoken line both the panel and the object tree use.
    func summary(unit: FFLengthUnit) -> String {
        var parts = [
            "Revolve \(FFPrecision.angleString(degrees: parameters.angleDegrees))"
        ]
        if let detail = parameters.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

/// The read-only projection a panel or a test reads: which node owns the record
/// and what the committed body currently is. The view never keeps a second copy
/// that could disagree with the document.
struct FFRevolveInfo: Equatable, Sendable {
    var nodeID: UUID
    var name: String
    var definition: FFRevolveDefinition
    var triangleCount: Int
}

extension FFDocument {
    /// The revolve record for one node, or nil when that node is not a
    /// parametric revolution.
    func revolveInfo(for id: UUID) -> FFRevolveInfo? {
        guard let node = node(withID: id), let definition = node.revolve,
              let payload = node.geometry?.mesh
        else { return nil }
        return FFRevolveInfo(
            nodeID: id,
            name: node.name,
            definition: definition,
            triangleCount: payload.triangles.count
        )
    }

    /// Commits a revolution as one ordinary solid node, inserted directly above
    /// the curve it was made from.
    ///
    /// The mesh is built here, from the record that is about to be stored, so a
    /// document can never hold a record and a body that disagree. The node
    /// inherits the source curve's placement, which is what puts the body on the
    /// sketch plane rather than at the world origin, and takes the source's
    /// layer so a body made from a sketch on a layer draws on that layer.
    @discardableResult
    mutating func addRevolve(
        _ definition: FFRevolveDefinition,
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
            revolve: definition
        )
        let source = definition.sourceNodeID
        let parent = source.flatMap { parentID(of: $0) }
        let siblings = parent.flatMap { self.node(withID: $0)?.children } ?? rootNodes
        var index = siblings.count
        if let source, let position = siblings.firstIndex(where: { $0.id == source }) {
            index = position + 1
        }
        guard insertNode(created, into: parent, at: index) else { return nil }
        return created.id
    }

    /// The ring body primitive as one ordinary solid node.
    ///
    /// The body is built from the same record a sketch-driven revolution stores,
    /// with no source curve and the primitive's own angular count, so one undo
    /// removes it, the object tree sees a solid, and a later phase can edit it
    /// through the parameters that already exist rather than a second record
    /// type.
    @discardableResult
    mutating func addRingBody(
        _ body: FFRingBody,
        name: String,
        transform: FFTransform = .identity,
        layerID: UUID? = nil
    ) -> UUID? {
        guard body.isValid, let payload = try? body.sectionPayload() else { return nil }
        let definition = FFRevolveDefinition(
            profile: payload,
            parameters: FFRevolveParameters(
                angleDegrees: FFRevolveParameters.maximumAngleDegrees
            ),
            angularSegments: body.angularSegments
        )
        guard let mesh = try? definition.mesh() else { return nil }
        let created = FFNode(
            name: uniqueNodeName(name),
            transform: transform,
            geometry: .mesh(FFMeshPayload(mesh)),
            kind: .solid,
            layerID: layerID ?? currentLayerID,
            revolve: definition
        )
        rootNodes.append(created)
        return created.id
    }
}
