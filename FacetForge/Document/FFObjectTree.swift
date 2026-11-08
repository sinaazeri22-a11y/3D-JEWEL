import Foundation

/// The four row types the Phase 32 tree names. A container is a group; a node
/// with curve geometry is a curve; a mesh node is a stone or a solid from its
/// pick kind. The type is derived from the node, never stored twice.
enum FFObjectKind: String, CaseIterable, Equatable, Sendable {
    case group
    case solid
    case stone
    case curve

    var label: String {
        switch self {
        case .group: "Group"
        case .solid: "Solid"
        case .stone: "Stone"
        case .curve: "Curve"
        }
    }

    var systemImage: String {
        switch self {
        case .group: "folder"
        case .solid: "cube"
        case .stone: "diamond"
        case .curve: "scribble"
        }
    }

    static func classify(_ node: FFNode) -> FFObjectKind {
        guard let geometry = node.geometry else { return .group }
        switch geometry {
        case .curve:
            return .curve
        case .mesh:
            return node.kind == .stone ? .stone : .solid
        }
    }
}

/// One visible line of the object tree. Rows are value data so the panel only
/// renders them and the unit tests can read the same flattening the UI shows.
struct FFObjectTreeRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: FFObjectKind
    let depth: Int
    let childCount: Int
    let isLocked: Bool

    var isGroup: Bool { kind == .group }
}

/// The pure tree functions Phase 32 needs: flattening, search by name and type,
/// and the structural edits (detach, insert, reorder) that the session commits
/// through one `perform` block. The document remains the only stored truth.
enum FFObjectTree {
    /// Flattens document order, keeping depth so the panel can indent. A query
    /// matches a node's name or its type label, case-insensitively; a match
    /// keeps its ancestors and, when a group matches, its descendants.
    static func rows(in document: FFDocument, query: String = "") -> [FFObjectTreeRow] {
        rows(in: document.rootNodes, query: query, isLocked: { document.isLocked(nodeID: $0) })
    }

    static func rows(
        in nodes: [FFNode],
        query: String,
        isLocked: (UUID) -> Bool = { _ in false }
    ) -> [FFObjectTreeRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows(in: nodes, needle: needle, isLocked: isLocked)
    }

    static func rows(
        in nodes: [FFNode],
        needle: String,
        isLocked: (UUID) -> Bool = { _ in false }
    ) -> [FFObjectTreeRow] {
        func visit(
            _ node: FFNode,
            depth: Int,
            ancestorMatches: Bool
        ) -> (rows: [FFObjectTreeRow], matched: Bool) {
            let selfMatches = !needle.isEmpty && matches(node, needle)
            var childRows: [FFObjectTreeRow] = []
            var anyChildMatches = false
            for child in node.children {
                let result = visit(
                    child,
                    depth: depth + 1,
                    ancestorMatches: ancestorMatches || selfMatches
                )
                childRows.append(contentsOf: result.rows)
                anyChildMatches = anyChildMatches || result.matched
            }

            let subtreeMatches = selfMatches || anyChildMatches
            var rows: [FFObjectTreeRow] = []
            if needle.isEmpty || ancestorMatches || selfMatches || subtreeMatches {
                rows.append(FFObjectTreeRow(
                    id: node.id,
                    name: node.name,
                    kind: FFObjectKind.classify(node),
                    depth: depth,
                    childCount: node.children.count,
                    isLocked: isLocked(node.id)
                ))
            }
            if needle.isEmpty || ancestorMatches || selfMatches || anyChildMatches {
                rows.append(contentsOf: childRows)
            }
            return (rows, subtreeMatches)
        }

        var rows: [FFObjectTreeRow] = []
        for node in nodes {
            rows.append(contentsOf: visit(node, depth: 0, ancestorMatches: false).rows)
        }
        return rows
    }

    static func matches(_ node: FFNode, _ needle: String) -> Bool {
        let kind = FFObjectKind.classify(node)
        return node.name.lowercased().contains(needle)
            || kind.label.lowercased().contains(needle)
            || kind.rawValue.contains(needle)
    }

    /// A stable, unique default name for a new empty group.
    static func newGroupName(in document: FFDocument) -> String {
        var names = Set<String>()
        func visit(_ node: FFNode) {
            names.insert(node.name.lowercased())
            node.children.forEach(visit)
        }
        document.rootNodes.forEach(visit)
        var index = 1
        while names.contains("group \(index)") {
            index += 1
        }
        return "Group \(index)"
    }
}

// MARK: - Document tree geometry

extension FFNode {
    /// The parent and sibling index of a node below this subtree.
    func location(of target: UUID) -> (parent: UUID?, index: Int)? {
        if let index = children.firstIndex(where: { $0.id == target }) {
            return (id, index)
        }
        for child in children {
            if let found = child.location(of: target) { return found }
        }
        return nil
    }

    /// Removes a matching descendant and returns the detached subtree.
    mutating func detachDescendant(_ target: UUID) -> FFNode? {
        if let index = children.firstIndex(where: { $0.id == target }) {
            return children.remove(at: index)
        }
        for index in children.indices {
            if let removed = children[index].detachDescendant(target) {
                return removed
            }
        }
        return nil
    }
}

extension FFDocument {
    func location(of nodeID: UUID) -> (parent: UUID?, index: Int)? {
        if let index = rootNodes.firstIndex(where: { $0.id == nodeID }) {
            return (nil, index)
        }
        for root in rootNodes {
            if let found = root.location(of: nodeID) { return found }
        }
        return nil
    }

    func parentID(of nodeID: UUID) -> UUID? {
        location(of: nodeID)?.parent
    }

    func isLocked(nodeID: UUID) -> Bool {
        layer(forNodeID: nodeID)?.isLocked ?? false
    }

    /// Removes the node and returns its subtree, or nil when it is absent.
    mutating func detachNode(_ id: UUID) -> FFNode? {
        if let index = rootNodes.firstIndex(where: { $0.id == id }) {
            return rootNodes.remove(at: index)
        }
        for index in rootNodes.indices {
            if let removed = rootNodes[index].detachDescendant(id) {
                return removed
            }
        }
        return nil
    }

    /// Inserts a detached subtree. `index` is a position in the array after the
    /// move, so a caller that moved a node within its own siblings can pass the
    /// final index directly.
    @discardableResult
    mutating func insertNode(_ node: FFNode, into parentID: UUID?, at index: Int) -> Bool {
        if let parentID {
            guard node(withID: parentID) != nil else { return false }
            let insertion = min(max(0, index), node(withID: parentID)?.children.count ?? 0)
            return updateNode(withID: parentID) { parent in
                parent.children.insert(node, at: insertion)
            }
        }
        rootNodes.insert(node, at: min(max(0, index), rootNodes.count))
        return true
    }

    /// Appends a subtree to a container. Moving a node into itself or into its
    /// own descendant is refused, so a drag can never make a cycle.
    @discardableResult
    mutating func moveNode(_ id: UUID, into parentID: UUID) -> Bool {
        guard id != parentID,
              let moving = node(withID: id),
              let destination = node(withID: parentID),
              moving.node(withID: parentID) == nil,
              destination.geometry == nil,
              !isLocked(nodeID: parentID),
              let node = detachNode(id)
        else { return false }
        return insertNode(node, into: parentID, at: destination.children.count)
    }

    /// Moves one step among its own siblings (-1 up, +1 down). The target is a
    /// final index, so the node lands where the button says even after detach.
    @discardableResult
    mutating func moveNode(_ id: UUID, by offset: Int) -> Bool {
        guard offset != 0, let location = location(of: id) else { return false }
        let siblingCount = location.parent
            .flatMap { node(withID: $0)?.children.count }
            ?? rootNodes.count
        let target = location.index + offset
        guard target >= 0, target < siblingCount, let node = detachNode(id) else {
            return false
        }
        return insertNode(node, into: location.parent, at: target)
    }
}
