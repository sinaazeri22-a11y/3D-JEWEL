import Foundation

/// The read-only projection a panel or a test reads: which node owns the
/// primitive and what its parameters currently are. The view never keeps a
/// second copy that could disagree with the document.
struct FFPrimitiveInfo: Equatable, Sendable {
    var nodeID: UUID
    var name: String
    var primitive: FFCurvePrimitive
}

extension FFDocument {
    /// The primitive record for one node, or nil when that node is not a
    /// parametric primitive.
    func primitiveInfo(for id: UUID) -> FFPrimitiveInfo? {
        guard let node = node(withID: id), let primitive = node.curvePrimitive else {
            return nil
        }
        return FFPrimitiveInfo(nodeID: id, name: node.name, primitive: primitive)
    }

    /// Appends a primitive curve as one ordinary node. The generated payload is
    /// validated first, so a document can never hold a primitive whose record
    /// and geometry disagree. The name is made unique here, not by the caller.
    @discardableResult
    mutating func addPrimitive(
        _ primitive: FFCurvePrimitive,
        name: String,
        layerID: UUID? = nil
    ) -> UUID? {
        guard primitive.isValid, let payload = try? primitive.payload() else { return nil }
        let node = FFNode(
            name: uniqueNodeName(name),
            geometry: .curve(payload),
            kind: .curve,
            layerID: layerID ?? currentLayerID,
            curvePrimitive: primitive
        )
        rootNodes.append(node)
        return node.id
    }

    /// Appends a library cross-section as one ordinary closed curve node.
    ///
    /// The payload is validated before the node exists, so the document cannot
    /// hold a section that failed to build. The node carries no profile record:
    /// what opens is the exact curve, edited afterwards by the same control
    /// points as any other payload, which is what keeps the file format and the
    /// canonical hash unchanged.
    @discardableResult
    mutating func addProfile(
        _ profile: FFRingProfile,
        name: String,
        layerID: UUID? = nil
    ) -> UUID? {
        guard let payload = try? profile.payload() else { return nil }
        let node = FFNode(
            name: uniqueNodeName(name),
            geometry: .curve(payload),
            kind: .curve,
            layerID: layerID ?? currentLayerID
        )
        rootNodes.append(node)
        return node.id
    }

    /// Applies one parameter edit and regenerates the payload in the same
    /// mutation, so undo restores the old parameters and the old geometry
    /// together. The node's transform is untouched, which is what keeps a
    /// radius, diameter or side-count change from moving the primitive.
    @discardableResult
    mutating func setPrimitive(
        _ id: UUID,
        _ edit: (inout FFCurvePrimitive) -> Bool
    ) -> Bool {
        guard !isLocked(nodeID: id),
              let node = node(withID: id),
              var primitive = node.curvePrimitive
        else { return false }
        let before = primitive
        guard edit(&primitive), primitive != before, primitive.isValid,
              let payload = try? primitive.payload()
        else { return false }
        return updateNode(withID: id) { target in
            target.curvePrimitive = primitive
            target.geometry = .curve(payload)
        }
    }
}
