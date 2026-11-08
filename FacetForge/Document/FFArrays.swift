import Foundation

/// A local axis. Linear arrays travel along one and radial arrays turn about
/// one; the document stores the name so a file never depends on a vector's
/// floating-point form.
enum FFAxis: String, CaseIterable, Codable, Identifiable, Sendable {
    case x
    case y
    case z

    var id: String { rawValue }

    var label: String { rawValue.uppercased() }

    var vector: Vec3 {
        switch self {
        case .x: Vec3(x: 1, y: 0, z: 0)
        case .y: Vec3(x: 0, y: 1, z: 0)
        case .z: Vec3(x: 0, y: 0, z: 1)
        }
    }

    func rotation(_ radians: Double) -> Mat4 {
        switch self {
        case .x: Mat4.rotationX(radians)
        case .y: Mat4.rotationY(radians)
        case .z: Mat4.rotationZ(radians)
        }
    }
}

enum FFArrayKind: String, Codable, Sendable {
    case linear
    case radial

    var label: String {
        switch self {
        case .linear: "Linear"
        case .radial: "Radial"
        }
    }
}

/// The instructing parameters of one array. The group that carries these owns
/// concrete child nodes, so every other consumer — renderer, picking, OBJ
/// export, thumbnails, bounds — sees ordinary nodes and needs no instance
/// expansion. Editing a parameter rebuilds those children from the first one.
struct FFArrayParameters: Codable, Equatable, Sendable {
    static let minimumCount = 2
    static let maximumCount = 100
    static let fullCircle = 360.0
    static let offsetStep = 1.0
    static let angleStep = 15.0

    var kind: FFArrayKind
    var count: Int
    /// Spacing between neighbours in millimetres, linear arrays only.
    var offset: Double
    /// The axis a linear array travels along.
    var direction: FFAxis
    /// The axis a radial array turns about.
    var axis: FFAxis
    /// The sweep in degrees, radial arrays only.
    var totalAngle: Double

    init(
        kind: FFArrayKind,
        count: Int,
        offset: Double = 10,
        direction: FFAxis = .x,
        axis: FFAxis = .y,
        totalAngle: Double = fullCircle
    ) {
        self.kind = kind
        self.count = count
        self.offset = offset
        self.direction = direction
        self.axis = axis
        self.totalAngle = totalAngle
    }

    static func linear(
        count: Int = 3,
        offset: Double = 10,
        direction: FFAxis = .x
    ) -> FFArrayParameters {
        FFArrayParameters(kind: .linear, count: count, offset: offset, direction: direction)
    }

    static func radial(
        count: Int = 12,
        axis: FFAxis = .y,
        totalAngle: Double = fullCircle
    ) -> FFArrayParameters {
        FFArrayParameters(kind: .radial, count: count, axis: axis, totalAngle: totalAngle)
    }

    var isValid: Bool {
        guard count >= Self.minimumCount,
              count <= Self.maximumCount,
              offset.isFinite,
              offset >= 0,
              totalAngle.isFinite
        else { return false }
        switch kind {
        case .linear:
            return true
        case .radial:
            return totalAngle > 0 && totalAngle <= Self.fullCircle
        }
    }

    /// A complete circle closes on itself, so its last member must not repeat
    /// the first: the step is the sweep divided by the count. An open arc has
    /// two ends, so its members span the sweep and the step divides by
    /// `count - 1`. That is why twelve members over 360° are exactly 30° apart.
    var isFullCircle: Bool {
        kind == .radial && abs(totalAngle - Self.fullCircle) <= 1e-9
    }

    var angularStepDegrees: Double {
        guard kind == .radial, count >= 2 else { return 0 }
        return totalAngle / Double(isFullCircle ? count : count - 1)
    }
}

/// What the array panel needs about the selected node. The document produces it
/// so the panel never recomputes spacing or member counts itself.
struct FFArrayInfo: Equatable, Sendable {
    let nodeID: UUID
    let name: String
    let sourceName: String?
    let parameters: FFArrayParameters
    let memberCount: Int
    let isLocked: Bool
}

// MARK: - Copying subtrees

extension FFNode {
    /// A structurally identical subtree with fresh node identities. Array
    /// parameters travel with the copy, so duplicating an array group yields an
    /// independent group that can still be edited rather than a frozen result.
    func copied(named name: String? = nil) -> FFNode {
        var copy = self
        copy.id = UUID()
        if let name { copy.name = name }
        copy.children = children.map { $0.copied() }
        return copy
    }
}

// MARK: - Duplication and arrays

extension FFDocument {
    /// The unique name is a user-facing courtesy, not a constraint: two rows may
    /// legitimately share a name after a rename, but a command never creates a
    /// second `Stone copy` when it can pick `Stone copy 2`.
    func uniqueNodeName(_ preferred: String) -> String {
        var names = Set<String>()
        func visit(_ node: FFNode) {
            names.insert(node.name.lowercased())
            node.children.forEach(visit)
        }
        rootNodes.forEach(visit)

        var candidate = preferred
        var index = 2
        while names.contains(candidate.lowercased()) {
            candidate = "\(preferred) \(index)"
            index += 1
        }
        return candidate
    }

    /// One existing, unlocked node under an unlocked parent. A locked container
    /// may not receive a duplicate or an array group, just as it may not receive
    /// a nest or a group in Phase 32/33.
    func canCopyNode(_ id: UUID) -> Bool {
        guard node(withID: id) != nil, !isLocked(nodeID: id) else { return false }
        if let parentID = parentID(of: id) {
            guard node(withID: parentID) != nil, !isLocked(nodeID: parentID) else { return false }
        }
        return true
    }

    func arrayInfo(for id: UUID) -> FFArrayInfo? {
        guard let node = node(withID: id),
              let parameters = node.array,
              parameters.isValid
        else { return nil }
        return FFArrayInfo(
            nodeID: id,
            name: node.name,
            sourceName: node.children.first?.name,
            parameters: parameters,
            memberCount: node.children.count,
            isLocked: isLocked(nodeID: id)
        )
    }

    /// Copies one node's subtree beside it. The copy keeps the source's local
    /// transform, so it overlays the original until it is moved; that is the
    /// conventional duplicate behaviour and makes the new row obvious without
    /// inventing a displacement.
    @discardableResult
    mutating func duplicateNode(_ id: UUID) -> UUID? {
        guard canCopyNode(id),
              let location = location(of: id),
              let source = node(withID: id)
        else { return nil }
        let name = uniqueNodeName("\(source.name) copy")
        let copy = source.copied(named: name)
        guard insertNode(copy, into: location.parent, at: location.index + 1) else {
            return nil
        }
        return copy.id
    }

    /// Wraps one node in an array group at the node's own place and layer. The
    /// group's identity transform means member zero keeps the exact world
    /// matrix it had before the command.
    @discardableResult
    mutating func makeArray(_ id: UUID, parameters: FFArrayParameters) -> UUID? {
        guard parameters.isValid,
              canCopyNode(id),
              let location = location(of: id),
              let source = detachNode(id)
        else { return nil }
        let group = FFNode(
            name: uniqueNodeName("\(source.name) Array"),
            layerID: source.layerID,
            array: parameters,
            children: arrayMembers(template: source, parameters: parameters)
        )
        guard insertNode(group, into: location.parent, at: location.index) else {
            return nil
        }
        return group.id
    }

    /// Rewrites an existing array's parameters and regenerates its members.
    /// Member zero is the template and keeps its identity; the copies are
    /// replaced, so a hand-edited copy is discarded by the next parameter
    /// change. That is stated in the panel. A locked array or a value outside
    /// the supported range is refused without touching the document.
    @discardableResult
    mutating func setArrayParameters(_ id: UUID, _ parameters: FFArrayParameters) -> Bool {
        guard parameters.isValid,
              !isLocked(nodeID: id),
              let node = node(withID: id),
              let existing = node.array,
              existing != parameters,
              let template = node.children.first
        else { return false }
        let members = arrayMembers(template: template, parameters: parameters)
        return updateNode(withID: id) { group in
            group.array = parameters
            group.children = members
        }
    }

    /// Member zero is the source untouched. Linear copies shift along the
    /// direction; radial copies are the source's local matrix turned about the
    /// group origin, which is the array's own space. The two kinds therefore
    /// have one rule each rather than a shared offset field with two meanings.
    func arrayMembers(template: FFNode, parameters: FFArrayParameters) -> [FFNode] {
        var base = template
        base.array = nil
        guard parameters.count > 1 else { return [base] }

        var members: [FFNode] = [base]
        members.reserveCapacity(parameters.count)
        let step = parameters.angularStepDegrees
        for index in 1..<parameters.count {
            var member = base.copied(named: "\(base.name) \(index + 1)")
            switch parameters.kind {
            case .linear:
                let shift = parameters.offset * Double(index)
                member.transform.translation = FFPoint3(
                    x: base.transform.translation.x + parameters.direction.vector.x * shift,
                    y: base.transform.translation.y + parameters.direction.vector.y * shift,
                    z: base.transform.translation.z + parameters.direction.vector.z * shift
                )
            case .radial:
                let angle = FFMath.radians(step * Double(index))
                member.transform = FFTransform(
                    matrix: parameters.axis.rotation(angle) * base.localMatrix
                )
                member.pivot = nil
            }
            members.append(member)
        }
        return members
    }
}
