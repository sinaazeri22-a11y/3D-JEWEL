import Foundation

/// Phase 35's alloy presets. They are ordinary document data: a preset writes
/// a colour, metallic and roughness value that the user may then adjust, and it
/// carries no read-only "studio" tier. Values are approximations for shading,
/// not a certification of alloy composition.
enum FFAlloyPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case yellowGold18K = "yellow-gold-18k"
    case roseGold18K = "rose-gold-18k"
    case whiteGold18K = "white-gold-18k"
    case platinum950 = "platinum-950"
    case palladium950 = "palladium-950"
    case sterlingSilver = "sterling-silver"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yellowGold18K: return "18K yellow gold"
        case .roseGold18K: return "18K rose gold"
        case .whiteGold18K: return "18K white gold"
        case .platinum950: return "Platinum 950"
        case .palladium950: return "Palladium 950"
        case .sterlingSilver: return "Sterling silver"
        }
    }

    var baseColor: FFRGBA {
        switch self {
        case .yellowGold18K:
            return FFRGBA(red: 0.93, green: 0.78, blue: 0.40)
        case .roseGold18K:
            return FFRGBA(red: 0.92, green: 0.66, blue: 0.56)
        case .whiteGold18K:
            return FFRGBA(red: 0.90, green: 0.90, blue: 0.88)
        case .platinum950:
            return FFRGBA(red: 0.86, green: 0.86, blue: 0.84)
        case .palladium950:
            return FFRGBA(red: 0.80, green: 0.80, blue: 0.78)
        case .sterlingSilver:
            return FFRGBA(red: 0.91, green: 0.91, blue: 0.89)
        }
    }

    var metallic: Double { 1 }

    var roughness: Double {
        switch self {
        case .yellowGold18K: return 0.18
        case .roseGold18K: return 0.20
        case .whiteGold18K: return 0.16
        case .platinum950: return 0.22
        case .palladium950: return 0.24
        case .sterlingSilver: return 0.20
        }
    }
}

/// A named set of triangles on one mesh node. The node's own `materialID` is
/// the base material for every face no group claims, so assigning a subset
/// never leaves a face without a material. Triangle indices address the node's
/// mesh payload, which is the stable identity saved in the document.
struct FFFaceGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var materialID: UUID
    var triangles: [Int]

    init(
        id: UUID = UUID(),
        name: String,
        materialID: UUID,
        triangles: [Int]
    ) {
        self.id = id
        self.name = name
        self.materialID = materialID
        self.triangles = triangles
    }
}

/// One material's contiguous slice of a node's faces, in the order the face
/// groups were declared with the base material last. The renderer and the OBJ
/// writer both consume this same projection, so they cannot disagree about
/// which faces belong to which material.
struct FFFaceAssignment: Equatable, Sendable {
    var materialID: UUID?
    var groupIDs: [UUID]
    var triangles: [Int]
}

/// What the material inspector renders. It is a read-only projection of the
/// document; the panel owns only which material row is selected.
struct FFMaterialInfo: Equatable, Sendable {
    struct MaterialRow: Identifiable, Equatable, Sendable {
        var id: UUID
        var name: String
        var preset: FFAlloyPreset?
        var baseColor: FFRGBA
        var metallic: Double
        var roughness: Double
        /// How many mesh nodes use this material, by base assignment or by a
        /// face group.
        var nodeCount: Int
        /// How many triangles draw with this material across the document.
        var faceCount: Int
    }

    struct FaceGroupRow: Identifiable, Equatable, Sendable {
        var id: UUID
        var name: String
        var materialID: UUID
        var materialName: String
        var triangleCount: Int
    }

    var materials: [MaterialRow]
    var selectedNodeID: UUID?
    var selectedNodeName: String?
    var selectedNodeMaterialID: UUID?
    var selectedNodeTriangleCount: Int
    var faceGroups: [FaceGroupRow]
    var unassignedTriangleCount: Int
    var canEditSelection: Bool
}

extension FFNode {
    var meshTriangleCount: Int {
        guard case .mesh(let payload)? = geometry, let mesh = payload.mesh else {
            return 0
        }
        return mesh.triangleCount
    }
}

extension FFDocument {
    /// The material editor's projection. `isLocked` is supplied by the session
    /// because lock is a layer rule the document stores but does not consult
    /// when projecting.
    func materialInfo(for nodeID: UUID?, isLocked: Bool) -> FFMaterialInfo {
        var faceCounts: [UUID: Int] = [:]
        var nodeCounts: [UUID: Int] = [:]
        for root in rootNodes {
            for node in root.flattenedNodes() {
                guard case .mesh(let payload)? = node.geometry,
                      let mesh = payload.mesh
                else { continue }
                let assignments = faceAssignments(for: node.id)
                if assignments.isEmpty {
                    guard let materialID = node.materialID else { continue }
                    faceCounts[materialID, default: 0] += mesh.triangleCount
                    nodeCounts[materialID, default: 0] += 1
                } else {
                    var used: Set<UUID> = []
                    for assignment in assignments {
                        guard let materialID = assignment.materialID else { continue }
                        faceCounts[materialID, default: 0] += assignment.triangles.count
                        used.insert(materialID)
                    }
                    for materialID in used {
                        nodeCounts[materialID, default: 0] += 1
                    }
                }
            }
        }

        let rows = materials.map { material in
            FFMaterialInfo.MaterialRow(
                id: material.id,
                name: material.name.isEmpty ? "Material" : material.name,
                preset: material.preset,
                baseColor: material.baseColor,
                metallic: material.metallic,
                roughness: material.roughness,
                nodeCount: nodeCounts[material.id] ?? 0,
                faceCount: faceCounts[material.id] ?? 0
            )
        }

        guard let nodeID, let node = node(withID: nodeID) else {
            return FFMaterialInfo(
                materials: rows,
                selectedNodeID: nil,
                selectedNodeName: nil,
                selectedNodeMaterialID: nil,
                selectedNodeTriangleCount: 0,
                faceGroups: [],
                unassignedTriangleCount: 0,
                canEditSelection: false
            )
        }

        let groupRows = (node.faceGroups ?? []).map { group -> FFMaterialInfo.FaceGroupRow? in
            guard case .mesh(let payload)? = node.geometry,
                  let mesh = payload.mesh
            else { return nil }
            let valid = Set(group.triangles.filter { $0 >= 0 && $0 < mesh.triangleCount })
            guard !valid.isEmpty else { return nil }
            let materialName = material(withID: group.materialID)?.name ?? "Unassigned"
            return FFMaterialInfo.FaceGroupRow(
                id: group.id,
                name: group.name,
                materialID: group.materialID,
                materialName: materialName.isEmpty ? "Material" : materialName,
                triangleCount: valid.count
            )
        }.compactMap { $0 }

        return FFMaterialInfo(
            materials: rows,
            selectedNodeID: node.id,
            selectedNodeName: node.name,
            selectedNodeMaterialID: node.materialID
                ?? node.faceGroups?.first(where: { material(withID: $0.materialID) != nil })?.materialID,
            selectedNodeTriangleCount: node.meshTriangleCount,
            faceGroups: groupRows,
            unassignedTriangleCount: unassignedTriangleCount(for: node.id),
            canEditSelection: node.meshTriangleCount > 0 && !isLocked
        )
    }

    /// Assigns `triangles` to one material as a named face group. The faces are
    /// removed from any group that previously held them, so groups never
    /// overlap; a group left with no faces disappears. Reassigning exactly the
    /// same triangle set updates that group instead of creating a duplicate.
    @discardableResult
    mutating func assignFaceGroup(
        nodeID: UUID,
        name: String,
        materialID: UUID,
        triangles: [Int]
    ) -> UUID? {
        guard let node = node(withID: nodeID),
              case .mesh(let payload)? = node.geometry,
              let mesh = payload.mesh,
              material(withID: materialID) != nil
        else { return nil }
        let valid = Set(triangles.filter { $0 >= 0 && $0 < mesh.triangleCount })
        guard !valid.isEmpty else { return nil }
        let existing = node.faceGroups ?? []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var groups: [FFFaceGroup] = []
        var created: UUID?

        func trimmedGroup(_ group: FFFaceGroup) -> FFFaceGroup? {
            let remaining = group.triangles.filter { !valid.contains($0) }
            guard !remaining.isEmpty else { return nil }
            var copy = group
            copy.triangles = remaining
            return copy
        }

        if let match = existing.firstIndex(where: { Set($0.triangles) == valid }) {
            // The same triangle set keeps its identity: update that group in
            // place and only remove the claimed faces from the others, so a
            // reassignment is one changed material, not a delete and a create.
            for (index, group) in existing.enumerated() {
                if index == match {
                    var copy = group
                    copy.materialID = materialID
                    if !trimmed.isEmpty { copy.name = trimmed }
                    groups.append(copy)
                    created = copy.id
                } else if let rest = trimmedGroup(group) {
                    groups.append(rest)
                }
            }
        } else {
            for group in existing {
                if let rest = trimmedGroup(group) {
                    groups.append(rest)
                }
            }
            let group = FFFaceGroup(
                name: trimmed.isEmpty ? "Faces \(groups.count + 1)" : trimmed,
                materialID: materialID,
                triangles: valid.sorted()
            )
            groups.append(group)
            created = group.id
        }

        guard updateNode(withID: nodeID, { $0.faceGroups = groups }) else { return nil }
        return created
    }

    @discardableResult
    mutating func setFaceGroupMaterial(
        nodeID: UUID,
        groupID: UUID,
        materialID: UUID
    ) -> Bool {
        guard let node = node(withID: nodeID),
              var groups = node.faceGroups,
              let index = groups.firstIndex(where: { $0.id == groupID }),
              groups[index].materialID != materialID,
              material(withID: materialID) != nil
        else { return false }
        groups[index].materialID = materialID
        return updateNode(withID: nodeID, { $0.faceGroups = groups })
    }

    @discardableResult
    mutating func removeFaceGroup(nodeID: UUID, groupID: UUID) -> Bool {
        guard let node = node(withID: nodeID),
              var groups = node.faceGroups,
              let index = groups.firstIndex(where: { $0.id == groupID })
        else { return false }
        groups.remove(at: index)
        let replacement: [FFFaceGroup]? = groups.isEmpty ? nil : groups
        return updateNode(withID: nodeID, { $0.faceGroups = replacement })
    }

    @discardableResult
    mutating func setNodeMaterial(nodeID: UUID, materialID: UUID) -> Bool {
        guard let node = node(withID: nodeID),
              node.geometry?.mesh != nil,
              node.materialID != materialID,
              material(withID: materialID) != nil
        else { return false }
        return updateNode(withID: nodeID, { $0.materialID = materialID })
    }

    /// Applies all three preset values in one document change. Changing the
    /// preset updates every face that references the material because nodes and
    /// face groups store only its id.
    @discardableResult
    mutating func setMaterialPreset(_ materialID: UUID, preset: FFAlloyPreset) -> Bool {
        guard let index = materials.firstIndex(where: { $0.id == materialID }) else {
            return false
        }
        let next = FFMaterial(
            id: materials[index].id,
            name: materials[index].name,
            baseColor: preset.baseColor,
            metallic: preset.metallic,
            roughness: preset.roughness,
            preset: preset
        )
        guard materials[index] != next else { return false }
        materials[index] = next
        return true
    }

    /// Direct edits are custom: they clear the preset badge rather than
    /// pretending the result is still the named alloy.
    @discardableResult
    mutating func setMaterialParameters(
        _ materialID: UUID,
        baseColor: FFRGBA? = nil,
        metallic: Double? = nil,
        roughness: Double? = nil
    ) -> Bool {
        guard let index = materials.firstIndex(where: { $0.id == materialID }) else {
            return false
        }
        var next = materials[index]
        if let baseColor {
            next.baseColor = FFRGBA(
                red: FFMath.clamp(baseColor.red.isFinite ? baseColor.red : 0, to: 0...1),
                green: FFMath.clamp(baseColor.green.isFinite ? baseColor.green : 0, to: 0...1),
                blue: FFMath.clamp(baseColor.blue.isFinite ? baseColor.blue : 0, to: 0...1),
                alpha: 1
            )
        }
        if let metallic {
            next.metallic = FFMath.clamp(metallic.isFinite ? metallic : 0, to: 0...1)
        }
        if let roughness {
            next.roughness = FFMath.clamp(roughness.isFinite ? roughness : 0, to: 0...1)
        }
        guard next != materials[index] else { return false }
        next.preset = nil
        materials[index] = next
        return true
    }

    /// The faces of one node grouped by resolved material. A nil key means the
    /// node and every group that claimed those faces name no usable material.
    /// An empty result means the node has no face groups and the whole mesh is
    /// drawn with the node's base material, preserving pre-Phase-35 scenes
    /// exactly.
    func faceAssignments(for nodeID: UUID) -> [FFFaceAssignment] {
        guard let node = node(withID: nodeID),
              case .mesh(let payload)? = node.geometry,
              let mesh = payload.mesh,
              let groups = node.faceGroups,
              !groups.isEmpty
        else { return [] }
        let total = mesh.triangleCount
        guard total > 0 else { return [] }

        func resolved(_ raw: UUID?) -> UUID? {
            if let raw, material(withID: raw) != nil { return raw }
            if let fallback = node.materialID, material(withID: fallback) != nil {
                return fallback
            }
            return nil
        }

        var assignments: [FFFaceAssignment] = []
        func index(for materialID: UUID?) -> Int {
            if let existing = assignments.firstIndex(where: { $0.materialID == materialID }) {
                return existing
            }
            assignments.append(FFFaceAssignment(
                materialID: materialID,
                groupIDs: [],
                triangles: []
            ))
            return assignments.count - 1
        }

        var claimed: Set<Int> = []
        for group in groups {
            let materialID = resolved(group.materialID)
            let target = index(for: materialID)
            if !assignments[target].groupIDs.contains(group.id) {
                assignments[target].groupIDs.append(group.id)
            }
            for triangle in group.triangles
            where triangle >= 0 && triangle < total && !claimed.contains(triangle) {
                claimed.insert(triangle)
                assignments[target].triangles.append(triangle)
            }
        }

        let base = index(for: resolved(node.materialID))
        for triangle in 0..<total where !claimed.contains(triangle) {
            assignments[base].triangles.append(triangle)
        }
        return assignments.filter { !$0.triangles.isEmpty }
    }

    func unassignedTriangleCount(for nodeID: UUID) -> Int {
        guard let node = node(withID: nodeID),
              node.meshTriangleCount > 0
        else { return 0 }
        guard let groups = node.faceGroups, !groups.isEmpty else {
            return node.meshTriangleCount
        }
        var claimed: Set<Int> = []
        for group in groups {
            for triangle in group.triangles
            where triangle >= 0 && triangle < node.meshTriangleCount {
                claimed.insert(triangle)
            }
        }
        return node.meshTriangleCount - claimed.count
    }
}

extension FFNode {
    func flattenedNodes() -> [FFNode] {
        [self] + children.flatMap { $0.flattenedNodes() }
    }
}
