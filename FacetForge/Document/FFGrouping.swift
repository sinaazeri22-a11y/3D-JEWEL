import Foundation

/// Where a pivot preset puts the pivot. The points are expressed in the node's
/// own local space, taken from the bounds of everything below it, so a group's
/// pivot is the centre of what the group contains rather than the world origin.
enum FFPivotPreset: String, CaseIterable, Identifiable, Sendable {
    case centre
    case origin
    case x
    case y
    case z

    var id: String { rawValue }

    var label: String {
        switch self {
        case .centre: "Centre"
        case .origin: "Origin"
        case .x: "X"
        case .y: "Y"
        case .z: "Z"
        }
    }

    var systemImage: String {
        switch self {
        case .centre: "scope"
        case .origin: "smallcircle.filled.circle"
        case .x: "arrow.left.and.right"
        case .y: "arrow.up.and.down"
        case .z: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Centre is the middle of the subtree's bounds; Origin is the local zero;
    /// X, Y and Z are that centre projected onto each local axis line, which
    /// puts a hinge on the axis through the middle of the object.
    func point(in bounds: AABB?) -> Vec3 {
        let centre = bounds?.center ?? Vec3(x: 0, y: 0, z: 0)
        switch self {
        case .centre:
            return centre
        case .origin:
            return Vec3(x: 0, y: 0, z: 0)
        case .x:
            return Vec3(x: centre.x, y: 0, z: 0)
        case .y:
            return Vec3(x: 0, y: centre.y, z: 0)
        case .z:
            return Vec3(x: 0, y: 0, z: centre.z)
        }
    }
}

/// Everything the Phase 33 transform panel reads about one node. The panel
/// formats and renders it; the math that produces it lives on the document, so
/// the inspector never re-derives an inherited world position itself.
struct FFTransformInfo: Equatable, Sendable {
    let nodeID: UUID
    let name: String
    let kind: FFObjectKind
    /// The container this node is nested in. `nil` means a document root.
    let parentName: String?
    let isLocked: Bool
    let localTranslation: FFPoint3
    let worldTranslation: FFPoint3
    let pivot: FFPoint3
    let rotationDegrees: FFPoint3
    let canUngroup: Bool
}

// MARK: - Pivot-aware node geometry

extension FFNode {
    /// The stored pivot, or the origin for a node that has never had one.
    var effectivePivot: FFPoint3 {
        pivot ?? FFPoint3(x: 0, y: 0, z: 0)
    }

    /// The node's local matrix with its pivot applied. Every consumer composes
    /// through this property, so a pivot cannot be honoured in one view and
    /// forgotten in another.
    var localMatrix: Mat4 {
        transform.matrix(pivot: effectivePivot.vector)
    }

    /// The bounds of this subtree as seen from this node's own space: its own
    /// geometry untransformed, and each descendant through its local matrix.
    /// That makes a pivot preset independent of where the node itself sits.
    var localBounds: AABB? {
        var box: AABB?

        func include(_ point: Vec3) {
            let pointBox = AABB(minimum: point, maximum: point)
            box = box.map { $0.union(pointBox) } ?? pointBox
        }

        func visit(_ node: FFNode, parent: Mat4) {
            if let mesh = node.geometry?.mesh {
                for position in mesh.positions {
                    include(parent.transformedPoint(position.vector))
                }
            }
            if let curve = node.geometry?.curve {
                for segment in curve.segments {
                    for point in segment.controlPoints {
                        include(parent.transformedPoint(Vec3(x: point.x, y: point.y, z: 0)))
                    }
                }
            }
            for child in node.children {
                visit(child, parent: parent * child.localMatrix)
            }
        }

        visit(self, parent: .identity)
        return box
    }
}

extension AABB {
    /// A covering box of this box's eight corners after `matrix`. Rotating a box
    /// turns it into a frustum; this returns the axis-aligned box around it,
    /// which is what a pivot centre and a preset need and all they need.
    func transformed(by matrix: Mat4) -> AABB {
        var box: AABB?
        for x in [minimum.x, maximum.x] {
            for y in [minimum.y, maximum.y] {
                for z in [minimum.z, maximum.z] {
                    let point = matrix.transformedPoint(Vec3(x: x, y: y, z: z))
                    let pointBox = AABB(minimum: point, maximum: point)
                    box = box.map { $0.union(pointBox) } ?? pointBox
                }
            }
        }
        return box ?? self
    }
}

// MARK: - Transform inheritance and grouping

extension FFDocument {
    /// The parent world matrix and the node's world matrix. One traversal keeps
    /// the two answers consistent; `worldMatrix` and `parentWorldMatrix` are
    /// views of the same chain.
    func transformChain(of nodeID: UUID) -> (parent: Mat4, world: Mat4)? {
        func search(_ node: FFNode, parent: Mat4) -> (parent: Mat4, world: Mat4)? {
            let world = parent * node.localMatrix
            if node.id == nodeID { return (parent, world) }
            for child in node.children {
                if let found = search(child, parent: world) { return found }
            }
            return nil
        }
        for root in rootNodes {
            if let found = search(root, parent: .identity) { return found }
        }
        return nil
    }

    func worldMatrix(of nodeID: UUID) -> Mat4? {
        transformChain(of: nodeID)?.world
    }

    func parentWorldMatrix(of nodeID: UUID) -> Mat4? {
        transformChain(of: nodeID)?.parent
    }

    /// The panel's read-only projection of one node. Inheritance is reported
    /// from the composed chain, not from a second sum of the local values.
    func transformInfo(for nodeID: UUID) -> FFTransformInfo? {
        guard let node = self.node(withID: nodeID),
              let chain = transformChain(of: nodeID)
        else { return nil }
        let origin = chain.world.transformedPoint(Vec3(x: 0, y: 0, z: 0))
        return FFTransformInfo(
            nodeID: nodeID,
            name: node.name,
            kind: FFObjectKind.classify(node),
            parentName: parentID(of: nodeID).flatMap { self.node(withID: $0)?.name },
            isLocked: isLocked(nodeID: nodeID),
            localTranslation: node.transform.translation,
            worldTranslation: FFPoint3(origin),
            pivot: node.effectivePivot,
            rotationDegrees: FFPoint3(
                x: FFMath.degrees(node.transform.rotation.x),
                y: FFMath.degrees(node.transform.rotation.y),
                z: FFMath.degrees(node.transform.rotation.z)
            ),
            canUngroup: canUngroup(nodeID)
        )
    }

    /// The given IDs in document order, so a group's children arrive in the
    /// order the tree already shows rather than in selection order.
    func nodeIDsInDocumentOrder(from ids: [UUID]) -> [UUID] {
        var selected = Set(ids)
        var ordered: [UUID] = []
        func visit(_ node: FFNode) {
            if selected.remove(node.id) != nil { ordered.append(node.id) }
            node.children.forEach(visit)
        }
        rootNodes.forEach(visit)
        return ordered
    }

    /// A selection can be grouped when every node still exists, sits under one
    /// parent, is unlocked, and none contains another. The parent must exist
    /// too, which a locked container fails.
    func canGroup(_ ids: [UUID]) -> Bool {
        let ordered = nodeIDsInDocumentOrder(from: ids)
        guard !ordered.isEmpty, ordered.count == ids.count,
              let first = location(of: ordered[0])
        else { return false }
        if let parentID = first.parent {
            guard node(withID: parentID) != nil, !isLocked(nodeID: parentID) else { return false }
        }
        for id in ordered {
            guard let node = self.node(withID: id),
                  location(of: id)?.parent == first.parent,
                  !isLocked(nodeID: id)
            else { return false }
            for other in ordered where other != id {
                if node.node(withID: other) != nil { return false }
            }
        }
        return true
    }

    /// A group can be dissolved when it is an unlocked container and each child
    /// it is about to move is unlocked. Children on a locked layer would have
    /// their transform rewritten, so the whole command is refused instead.
    func canUngroup(_ id: UUID) -> Bool {
        guard let node = self.node(withID: id),
              node.geometry == nil,
              !isLocked(nodeID: id)
        else { return false }
        return node.children.allSatisfy { !isLocked(nodeID: $0.id) }
    }

    /// Wraps the selected siblings in one new group. The group is inserted where
    /// the first selected node was and its transform is identity, so every
    /// child keeps its exact local matrix and therefore its exact world matrix.
    /// Its pivot starts at the centre of what it now contains.
    @discardableResult
    mutating func groupSelection(_ ids: [UUID], named name: String, layerID: UUID?) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canGroup(ids) else { return nil }
        let ordered = nodeIDsInDocumentOrder(from: ids)
        guard let first = location(of: ordered[0]) else { return nil }
        let parentID = first.parent
        let insertionIndex = first.index

        var children: [FFNode] = []
        for id in ordered {
            guard let detached = detachNode(id) else { return nil }
            children.append(detached)
        }

        var group = FFNode(
            name: trimmed,
            layerID: layerID ?? children.first?.layerID,
            children: children
        )
        if let centre = group.localBounds?.center {
            group.pivot = FFPoint3(centre)
        }
        guard insertNode(group, into: parentID, at: insertionIndex) else { return nil }
        return group.id
    }

    /// Dissolves a group, putting its children back where it stood. Each child's
    /// local matrix is recomposed through the group's own matrix, so its world
    /// transform is unchanged even when the group had been moved or rotated.
    @discardableResult
    mutating func ungroup(_ id: UUID) -> Bool {
        guard canUngroup(id),
              let location = location(of: id),
              let group = detachNode(id)
        else { return false }

        let groupMatrix = group.localMatrix
        var children: [FFNode] = []
        for child in group.children {
            var moved = child
            let local = groupMatrix * child.localMatrix
            moved.transform = FFTransform(matrix: local, pivot: child.effectivePivot.vector)
            children.append(moved)
        }
        for (offset, child) in children.enumerated() {
            guard insertNode(child, into: location.parent, at: location.index + offset) else {
                return false
            }
        }
        return true
    }

    /// Moves a node's pivot to one preset of its own subtree. A zero point is
    /// stored as no pivot so an untouched file's encoding does not grow.
    @discardableResult
    mutating func setPivot(_ id: UUID, to point: Vec3) -> Bool {
        guard !isLocked(nodeID: id) else { return false }
        let stored: FFPoint3? = point == Vec3(x: 0, y: 0, z: 0) ? nil : FFPoint3(point)
        return updateNode(withID: id) { $0.pivot = stored }
    }

    @discardableResult
    mutating func applyPivotPreset(_ id: UUID, preset: FFPivotPreset) -> Bool {
        guard let node = self.node(withID: id) else { return false }
        return setPivot(id, to: preset.point(in: node.localBounds))
    }

    /// Replaces a node's local rotation. Degrees are converted at the session
    /// boundary; the document keeps radians like every other transform.
    @discardableResult
    mutating func setRotation(_ id: UUID, radians: FFPoint3) -> Bool {
        guard !isLocked(nodeID: id) else { return false }
        return updateNode(withID: id) { $0.transform.rotation = radians }
    }
}
