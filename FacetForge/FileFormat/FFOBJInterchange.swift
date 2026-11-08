import Foundation

/// Errors an OBJ reader reports instead of loading geometry it cannot trust.
///
/// Geometry problems are errors; an auxiliary material-library problem is a
/// warning on the asset, because a mesh without its MTL is still usable and a
/// silent substitution is worse than a named one.
enum FFOBJError: Error, Equatable {
    case noGeometry
    case malformedNumber(String, line: Int)
    case malformedFace(String, line: Int)
    case degenerateFace(line: Int)
    case indexOutOfRange(String, line: Int)
    case unsupportedUnits(String)
}

extension FFOBJError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noGeometry:
            return "The OBJ file contains no faces."
        case .malformedNumber(let token, let line):
            return "Line \(line) is not a finite number: \(token)"
        case .malformedFace(let token, let line):
            return "Line \(line) has a face vertex that is not an index: \(token)"
        case .degenerateFace(let line):
            return "Line \(line) has a face with fewer than three distinct vertices."
        case .indexOutOfRange(let token, let line):
            return "Line \(line) refers to \(token), which is outside the file's vertex lists."
        case .unsupportedUnits(let units):
            return "The OBJ header declares \(units); only millimetres can be imported without a scale."
        }
    }
}

/// One MTL material, reduced to the subset the document can represent.
///
/// The importer reads `Kd`, `d`/`Tr`, `Ns`, `Pm` and `Pr`; every other MTL
/// directive is skipped rather than guessed at. `Pm`/`Pr` are the common PBR
/// extension that modern exporters write; a file without them falls back to
/// `Ns` for roughness and a non-metal.
struct FFOBJMaterial: Equatable, Sendable {
    var name: String
    var baseColor: FFRGBA
    var metallic: Double
    var roughness: Double

    init(
        name: String,
        baseColor: FFRGBA = FFRGBA(red: 0.8, green: 0.8, blue: 0.8, alpha: 1),
        metallic: Double = 0,
        roughness: Double = 1
    ) {
        self.name = name
        self.baseColor = baseColor
        self.metallic = FFMath.clamp(metallic, to: 0...1)
        self.roughness = FFMath.clamp(roughness, to: 0...1)
    }
}

/// One material's faces inside an OBJ group. The mesh is compacted to the
/// vertices those faces actually use, so a node's payload carries no unrelated
/// vertices from the rest of the file.
struct FFOBJSubmesh: Equatable, Sendable {
    var material: String?
    var mesh: IndexedMesh
}

/// One OBJ `g`/`o` group. A group can contain more than one material, which is
/// why it holds submeshes rather than a single mesh.
struct FFOBJGroup: Equatable, Sendable {
    var name: String
    var submeshes: [FFOBJSubmesh]

    var meshCount: Int { submeshes.count }

    var bounds: AABB? {
        var box: AABB?
        for submesh in submeshes {
            guard let submeshBounds = submesh.mesh.bounds else { continue }
            box = box.map { $0.union(submeshBounds) } ?? submeshBounds
        }
        return box
    }
}

/// A parsed interchange file, ready to become document geometry.
struct FFOBJAsset: Equatable, Sendable {
    var groups: [FFOBJGroup]
    /// Only materials a face actually uses, in first-use order.
    var materials: [FFOBJMaterial]
    var warnings: [String]
    /// What the header declared. Missing notes become millimetres with a
    /// warning; a non-millimetre note is rejected rather than silently scaled.
    var units: String
    var upAxis: String

    init(
        groups: [FFOBJGroup],
        materials: [FFOBJMaterial],
        warnings: [String] = [],
        units: String = "millimetres",
        upAxis: String = "Z"
    ) {
        self.groups = groups
        self.materials = materials
        self.warnings = warnings
        self.units = units
        self.upAxis = upAxis
    }

    var meshCount: Int {
        groups.reduce(0) { $0 + $1.meshCount }
    }

    var bounds: AABB? {
        var box: AABB?
        for group in groups {
            guard let groupBounds = group.bounds else { continue }
            box = box.map { $0.union(groupBounds) } ?? groupBounds
        }
        return box
    }
}

// MARK: - Reader

/// A strict OBJ reader for the subset the row names: `v`, `vn`, `vt`, `f`,
/// `g`/`o`, `usemtl` and `mtllib`, with the MTL subset `newmtl`, `Kd`, `d`,
/// `Tr`, `Ns`, `Pm` and `Pr`.
///
/// Coordinates are millimetres and Z-up: the file is read verbatim, with no
/// axis swap, because a hidden transform would make the export/import bounds
/// claim meaningless. The header note records the convention.
enum FFOBJImporter {
    /// The aliases accepted for the millimetre unit note. Everything else is a
    /// rejected import, never a silent scale.
    private static let millimetreAliases: Set<String> = [
        "mm", "millimetre", "millimetres", "millimeter", "millimeters",
    ]

    static func parse(
        _ text: String,
        materialLibrary: String? = nil
    ) throws -> FFOBJAsset {
        var positions: [Vec3] = []
        var normalCount = 0
        var textureCount = 0
        var faces: [Face] = []
        var currentGroup = "default"
        var currentMaterial: String?
        var units = "millimetres"
        var upAxis = "Z"
        var unitNoteSeen = false
        var axisNoteSeen = false
        var warnings: [String] = []
        var requestedLibraries: [String] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("#") {
                let comment = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                let lower = comment.lowercased()
                if lower.hasPrefix("units:") {
                    units = String(comment.dropFirst("units:".count))
                        .trimmingCharacters(in: .whitespaces)
                    unitNoteSeen = true
                } else if lower.hasPrefix("up-axis:") {
                    upAxis = String(comment.dropFirst("up-axis:".count))
                        .trimmingCharacters(in: .whitespaces)
                    axisNoteSeen = true
                }
                continue
            }

            let line = stripComment(trimmed)
            guard !line.isEmpty else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let command = tokens.first else { continue }
            let arguments = Array(tokens.dropFirst())

            switch command.lowercased() {
            case "v":
                positions.append(try vector(arguments, line: lineNumber))
            case "vn":
                _ = try vector(arguments, line: lineNumber)
                normalCount += 1
            case "vt":
                _ = try textureCoordinate(arguments, line: lineNumber)
                textureCount += 1
            case "f":
                let corners = try faceCorners(
                    arguments,
                    line: lineNumber,
                    positionCount: positions.count,
                    normalCount: normalCount,
                    textureCount: textureCount
                )
                for step in 1..<(corners.count - 1) {
                    let triangle = [corners[0], corners[step], corners[step + 1]]
                    guard Set(triangle).count == 3 else {
                        throw FFOBJError.degenerateFace(line: lineNumber)
                    }
                    faces.append(Face(
                        group: currentGroup,
                        material: currentMaterial,
                        a: triangle[0],
                        b: triangle[1],
                        c: triangle[2]
                    ))
                }
            case "g", "o":
                let name = arguments.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                currentGroup = name.isEmpty ? "default" : name
            case "usemtl":
                let name = arguments.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                currentMaterial = name.isEmpty ? nil : name
            case "mtllib":
                requestedLibraries.append(contentsOf: arguments)
            default:
                // `s`, `l`, `p`, `vp`, `curv`, `bevel` and future directives do
                // not describe a triangle surface this reader can carry.
                continue
            }
        }

        if unitNoteSeen {
            let normalized = units.lowercased()
            guard millimetreAliases.contains(normalized) else {
                throw FFOBJError.unsupportedUnits(units)
            }
            units = "millimetres"
        } else {
            warnings.append("the OBJ has no unit note; millimetres were assumed")
        }
        if axisNoteSeen, upAxis.lowercased() != "z" {
            warnings.append("the OBJ declares up-axis \(upAxis); coordinates were imported unchanged")
        }
        if materialLibrary == nil {
            for library in requestedLibraries {
                warnings.append("material library \(library) was not provided")
            }
        }
        guard !faces.isEmpty else { throw FFOBJError.noGeometry }

        let library = FFOBJMaterialLibrary.parse(materialLibrary ?? "")
        warnings.append(contentsOf: library.warnings)

        var groupOrder: [String] = []
        var facesByGroup: [String: [Face]] = [:]
        for face in faces {
            if facesByGroup[face.group] == nil { groupOrder.append(face.group) }
            facesByGroup[face.group, default: []].append(face)
        }

        var groups: [FFOBJGroup] = []
        var usedMaterials: [String] = []
        for groupName in groupOrder {
            var materialOrder: [String?] = []
            var facesByMaterial: [String?: [Face]] = [:]
            for face in facesByGroup[groupName] ?? [] {
                if facesByMaterial[face.material] == nil {
                    materialOrder.append(face.material)
                }
                facesByMaterial[face.material, default: []].append(face)
            }

            var submeshes: [FFOBJSubmesh] = []
            for material in materialOrder {
                guard let groupFaces = facesByMaterial[material],
                      let mesh = compact(groupFaces, positions: positions)
                else { continue }
                submeshes.append(FFOBJSubmesh(material: material, mesh: mesh))
                if let material, !usedMaterials.contains(material) {
                    usedMaterials.append(material)
                }
            }
            if !submeshes.isEmpty {
                groups.append(FFOBJGroup(name: groupName, submeshes: submeshes))
            }
        }
        guard !groups.isEmpty else { throw FFOBJError.noGeometry }

        var materials: [FFOBJMaterial] = []
        for name in usedMaterials {
            if let declared = library.materials.first(where: { $0.name == name }) {
                materials.append(declared)
            } else {
                materials.append(FFOBJMaterial(name: name))
                warnings.append("material \(name) is used but not declared; a default was substituted")
            }
        }

        return FFOBJAsset(
            groups: groups,
            materials: materials,
            warnings: warnings,
            units: units,
            upAxis: upAxis
        )
    }

    // MARK: - Reading helpers

    private struct Face {
        var group: String
        var material: String?
        var a: Int
        var b: Int
        var c: Int
    }

    private static func stripComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return String(line[line.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
    }

    private static func number(_ token: String, line: Int) throws -> Double {
        guard let value = Double(token), value.isFinite else {
            throw FFOBJError.malformedNumber(token, line: line)
        }
        return value
    }

    private static func vector(_ arguments: [String], line: Int) throws -> Vec3 {
        guard arguments.count >= 3 else {
            throw FFOBJError.malformedNumber(arguments.joined(separator: " "), line: line)
        }
        // A fourth `w` is legal OBJ and is ignored, as is a fifth colour value.
        return Vec3(
            x: try number(arguments[0], line: line),
            y: try number(arguments[1], line: line),
            z: try number(arguments[2], line: line)
        )
    }

    private static func textureCoordinate(_ arguments: [String], line: Int) throws -> Double {
        guard let first = arguments.first else {
            throw FFOBJError.malformedNumber("vt", line: line)
        }
        return try number(first, line: line)
    }

    /// Resolves one face's vertex references. Negative indices are relative to
    /// the current array, exactly as OBJ specifies, and a reference to a
    /// normal or texture coordinate that does not exist is rejected rather than
    /// carried as a silent zero.
    private static func faceCorners(
        _ arguments: [String],
        line: Int,
        positionCount: Int,
        normalCount: Int,
        textureCount: Int
    ) throws -> [Int] {
        guard arguments.count >= 3 else {
            throw FFOBJError.degenerateFace(line: line)
        }
        var corners: [Int] = []
        corners.reserveCapacity(arguments.count)
        for token in arguments {
            let parts = token.split(separator: "/", omittingEmptySubsequences: false)
            guard let vertexToken = parts.first, let raw = Int(vertexToken) else {
                throw FFOBJError.malformedFace(token, line: line)
            }
            let resolved = raw > 0 ? raw - 1 : positionCount + raw
            guard raw != 0, resolved >= 0, resolved < positionCount else {
                throw FFOBJError.indexOutOfRange(token, line: line)
            }
            if parts.count >= 2, let textureRaw = Int(parts[1]) {
                let texture = textureRaw > 0 ? textureRaw - 1 : textureCount + textureRaw
                guard textureRaw != 0, texture >= 0, texture < textureCount else {
                    throw FFOBJError.indexOutOfRange(token, line: line)
                }
            }
            if parts.count >= 3, !parts[2].isEmpty {
                guard let normalRaw = Int(parts[2]) else {
                    throw FFOBJError.malformedFace(token, line: line)
                }
                let normal = normalRaw > 0 ? normalRaw - 1 : normalCount + normalRaw
                guard normalRaw != 0, normal >= 0, normal < normalCount else {
                    throw FFOBJError.indexOutOfRange(token, line: line)
                }
            }
            corners.append(resolved)
        }
        return corners
    }

    /// Rebuilds one material's faces on only its own vertices. The remap is
    /// first-use ordered, so the same faces always produce the same mesh.
    private static func compact(_ faces: [Face], positions: [Vec3]) -> IndexedMesh? {
        var remap: [Int: Int] = [:]
        var vertices: [Vec3] = []
        var triangles: [MeshTriangle] = []
        vertices.reserveCapacity(min(positions.count, faces.count * 3))

        func index(_ original: Int) -> Int {
            if let existing = remap[original] { return existing }
            let next = vertices.count
            remap[original] = next
            vertices.append(positions[original])
            return next
        }

        for face in faces {
            triangles.append(MeshTriangle(index(face.a), index(face.b), index(face.c)))
        }
        return IndexedMesh(positions: vertices, triangles: triangles)
    }
}

// MARK: - Material library

/// The MTL subset reader. Malformed material lines become warnings: an MTL is
/// auxiliary, and losing one colour must not discard the whole mesh. Geometry
/// stays strict.
enum FFOBJMaterialLibrary {
    private struct Draft {
        var red = 0.8
        var green = 0.8
        var blue = 0.8
        var alpha = 1.0
        var metallic: Double?
        var roughness: Double?
        var specularExponent: Double?
        var pr: Double?
    }

    static func parse(_ text: String) -> (materials: [FFOBJMaterial], warnings: [String]) {
        var order: [String] = []
        var drafts: [String: Draft] = [:]
        var current: String?
        var warnings: [String] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[line.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let command = tokens.first else { continue }
            let arguments = Array(tokens.dropFirst())

            if command.lowercased() == "newmtl" {
                let name = arguments.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    warnings.append("line \(lineNumber): newmtl has no name")
                    current = nil
                    continue
                }
                if drafts[name] == nil {
                    drafts[name] = Draft()
                    order.append(name)
                }
                current = name
                continue
            }

            guard let name = current, var draft = drafts[name] else {
                // A directive before the first `newmtl` has no material to
                // belong to. Named once, not per line.
                if !warnings.contains(where: { $0.contains("outside any material") }) {
                    warnings.append("line \(lineNumber): directive \(command) appeared outside any material")
                }
                continue
            }

            func values() -> [Double]? {
                let parsed = arguments.compactMap { Double($0) }
                guard parsed.count == arguments.count,
                      parsed.allSatisfy({ $0.isFinite })
                else { return nil }
                return parsed
            }

            switch command.lowercased() {
            case "kd":
                if let rgb = values(), rgb.count >= 3 {
                    draft.red = FFMath.clamp(rgb[0], to: 0...1)
                    draft.green = FFMath.clamp(rgb[1], to: 0...1)
                    draft.blue = FFMath.clamp(rgb[2], to: 0...1)
                } else {
                    warnings.append("line \(lineNumber): Kd is not three numbers")
                }
            case "d":
                if let value = values()?.first {
                    draft.alpha = FFMath.clamp(value, to: 0...1)
                } else {
                    warnings.append("line \(lineNumber): d is not a number")
                }
            case "tr":
                if let value = values()?.first {
                    draft.alpha = FFMath.clamp(1 - value, to: 0...1)
                } else {
                    warnings.append("line \(lineNumber): Tr is not a number")
                }
            case "ns":
                if let value = values()?.first {
                    draft.specularExponent = value
                } else {
                    warnings.append("line \(lineNumber): Ns is not a number")
                }
            case "pm":
                if let value = values()?.first {
                    draft.metallic = FFMath.clamp(value, to: 0...1)
                } else {
                    warnings.append("line \(lineNumber): Pm is not a number")
                }
            case "pr":
                if let value = values()?.first {
                    draft.pr = FFMath.clamp(value, to: 0...1)
                } else {
                    warnings.append("line \(lineNumber): Pr is not a number")
                }
            default:
                // Ka, Ks, Ke, Ni, illum and texture maps are outside the
                // document's material model and are deliberately skipped.
                break
            }
            drafts[name] = draft
        }

        let materials = order.compactMap { name -> FFOBJMaterial? in
            guard let draft = drafts[name] else { return nil }
            let nsRoughness = draft.specularExponent.map {
                1 - FFMath.clamp($0 / 1000, to: 0...1)
            }
            return FFOBJMaterial(
                name: name,
                baseColor: FFRGBA(
                    red: draft.red,
                    green: draft.green,
                    blue: draft.blue,
                    alpha: draft.alpha
                ),
                metallic: draft.metallic ?? 0,
                roughness: draft.pr ?? nsRoughness ?? 1
            )
        }
        return (materials, warnings)
    }
}

// MARK: - Writer

/// The OBJ/MTL writer. Every mesh node becomes one `g` block whose group name
/// is its nearest container, so a document imported from three groups exports
/// as the same three groups. Coordinates are millimetres, Z-up, written with
/// six decimals; the header states both conventions so a reader never has to
/// infer them.
enum FFOBJExporter {
    static let unitNote = "millimetres"
    static let upAxis = "Z"

    static func obj(for document: FFDocument, mtlFileName: String = "materials.mtl") -> String {
        let parts = meshParts(in: document)
        var lines: [String] = [
            "# FacetForge OBJ 1.0",
            "# units: \(unitNote)",
            "# up-axis: \(upAxis)",
            "# meshes: \(parts.count)",
            "mtllib \(mtlFileName)",
            "",
        ]

        var vertexBase = 1
        for part in parts {
            lines.append("g \(part.group)")
            if let material = part.materialName {
                lines.append("usemtl \(material)")
            }
            for position in part.mesh.positions {
                lines.append("v \(number(position.x)) \(number(position.y)) \(number(position.z))")
            }
            let normals = vertexNormals(of: part.mesh)
            for normal in normals {
                lines.append("vn \(number(normal.x)) \(number(normal.y)) \(number(normal.z))")
            }
            for triangle in part.mesh.triangles {
                let a = vertexBase + triangle.a
                let b = vertexBase + triangle.b
                let c = vertexBase + triangle.c
                lines.append("f \(a)//\(a) \(b)//\(b) \(c)//\(c)")
            }
            lines.append("")
            vertexBase += part.mesh.positions.count
        }
        return lines.joined(separator: "\n")
    }

    static func mtl(for document: FFDocument) -> String {
        var lines: [String] = [
            "# FacetForge MTL 1.0",
            "# units: \(unitNote)",
            "",
        ]
        let names = materialNamesByID(document)
        for material in document.materials {
            guard let name = names[material.id] else { continue }
            lines.append("newmtl \(name)")
            lines.append("Kd \(number(material.baseColor.red)) \(number(material.baseColor.green)) \(number(material.baseColor.blue))")
            lines.append("d \(number(material.baseColor.alpha))")
            lines.append("Ns \(number((1 - material.roughness) * 1000))")
            lines.append("Pm \(number(material.metallic))")
            lines.append("Pr \(number(material.roughness))")
            lines.append("illum 2")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Scene walk

    private struct Part {
        var group: String
        var mesh: IndexedMesh
        var materialName: String?
    }

    /// Walks the tree in document order. A mesh node's group is the nearest
    /// non-mesh ancestor's name, or its own name at the root; that is exactly
    /// the shape the importer builds, so a document survives the round trip.
    ///
    /// OBJ has no node transforms, so world transforms are baked into the
    /// written vertices. A rotated document therefore still reimports with the
    /// world bounds it had before export, which is the row's acceptance.
    private static func meshParts(in document: FFDocument) -> [Part] {
        let names = materialNamesByID(document)
        var parts: [Part] = []

        func visit(_ node: FFNode, groupName: String?, parent: Mat4) {
            let world = parent * node.transform.matrix
            let isMesh = node.geometry?.mesh != nil
            let group = groupName ?? node.name
            if let payload = node.geometry?.mesh,
               let mesh = payload.mesh,
               let baked = IndexedMesh(
                   positions: mesh.positions.map(world.transformedPoint),
                   triangles: mesh.triangles
               ) {
                parts.append(Part(
                    group: group,
                    mesh: baked,
                    materialName: node.materialID.flatMap { names[$0] }
                ))
            }
            // A mesh node that carries children is itself a group boundary; a
            // container passes its own name down so several material children
            // keep writing the same `g`.
            let childGroup = isMesh ? group : node.name
            for child in node.children {
                visit(child, groupName: childGroup, parent: world)
            }
        }

        for root in document.rootNodes {
            visit(root, groupName: nil, parent: .identity)
        }
        return parts
    }

    /// Material names, made unique so two document materials with the same
    /// display name cannot merge (or shadow each other) in the MTL.
    private static func materialNamesByID(_ document: FFDocument) -> [UUID: String] {
        var used: Set<String> = []
        var mapping: [UUID: String] = [:]
        for material in document.materials {
            let base = material.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = base.isEmpty ? "Material" : base
            mapping[material.id] = unique(candidate, used: &used)
        }
        return mapping
    }

    private static func unique(_ base: String, used: inout Set<String>) -> String {
        guard used.contains(base) else {
            used.insert(base)
            return base
        }
        var index = 2
        while used.contains("\(base) \(index)") { index += 1 }
        let name = "\(base) \(index)"
        used.insert(name)
        return name
    }

    private static func vertexNormals(of mesh: IndexedMesh) -> [Vec3] {
        var accumulated = [Vec3](repeating: .zero, count: mesh.positions.count)
        for triangle in mesh.triangles {
            let a = mesh.positions[triangle.a]
            let b = mesh.positions[triangle.b]
            let c = mesh.positions[triangle.c]
            let normal = (b - a).cross(c - a)
            accumulated[triangle.a] = accumulated[triangle.a] + normal
            accumulated[triangle.b] = accumulated[triangle.b] + normal
            accumulated[triangle.c] = accumulated[triangle.c] + normal
        }
        return accumulated.map { $0.normalized() ?? Vec3(x: 0, y: 0, z: 1) }
    }

    /// Fixed-point with a POSIX locale, so the file never gains a comma
    /// decimal separator on a localised device.
    private static func number(_ value: Double) -> String {
        if value == 0 { return "0.000000" }
        return String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [value]
        )
    }
}

// MARK: - Document bridge

/// Turns a parsed asset into document materials and nodes. The session calls
/// this inside its single commit, so an import is one undo step.
enum FFOBJDocumentBuilder {
    static func build(
        _ asset: FFOBJAsset,
        layerID: UUID?,
        kind: FFPickKind = .solid
    ) -> (materials: [FFMaterial], nodes: [FFNode]) {
        var materials: [FFMaterial] = []
        var materialIDByName: [String: UUID] = [:]
        for material in asset.materials {
            let documentMaterial = FFMaterial(
                name: material.name,
                baseColor: material.baseColor,
                metallic: material.metallic,
                roughness: material.roughness
            )
            materials.append(documentMaterial)
            materialIDByName[material.name] = documentMaterial.id
        }

        var nodes: [FFNode] = []
        for group in asset.groups {
            guard !group.submeshes.isEmpty else { continue }
            if group.submeshes.count == 1 {
                // One material is still one object: keeping the group's name
                // here is what lets an export write the same `g` again. A
                // material suffix would turn `ring` into `ring · gold` and a
                // round trip would no longer see the original groups.
                let submesh = group.submeshes[0]
                nodes.append(FFNode(
                    name: group.name,
                    geometry: .mesh(FFMeshPayload(submesh.mesh)),
                    materialID: submesh.material.flatMap { materialIDByName[$0] },
                    kind: kind,
                    layerID: layerID
                ))
            } else {
                let children: [FFNode] = group.submeshes.map { submesh in
                    FFNode(
                        name: submesh.material.map { "\(group.name) · \($0)" } ?? group.name,
                        geometry: .mesh(FFMeshPayload(submesh.mesh)),
                        materialID: submesh.material.flatMap { materialIDByName[$0] },
                        kind: kind,
                        layerID: layerID
                    )
                }
                // A container keeps the group's name so the exporter still
                // writes one group for several material submeshes.
                nodes.append(FFNode(
                    name: group.name,
                    kind: nil,
                    layerID: layerID,
                    children: children
                ))
            }
        }
        return (materials, nodes)
    }
}
