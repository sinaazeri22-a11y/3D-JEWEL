import CryptoKit
import Foundation

/// Version zero of the FacetForge document model.
///
/// The model is deliberately plain data: a tree of nodes, each with a local
/// transform, optional geometry and an optional material reference. Geometry is
/// stored as a serialisable payload (control points, triangles) rather than as
/// the kernel types, so a document never depends on a particular in-memory
/// representation and an unsupported payload can be rejected on load instead of
/// crashing the app.
enum FFDocumentError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case corruptPayload(String)
}

/// A rejection a user can read. Phase 38's acceptance requires every refused
/// document to explain itself, so the typed errors carry a sentence rather than
/// only a case name.
extension FFDocumentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "this document uses schema version \(version); this app reads up to \(FFDocument.currentSchemaVersion)"
        case .corruptPayload(let detail):
            return "the document body is corrupt (\(detail))"
        }
    }
}

// MARK: - Primitive payloads

/// A serialisable two-dimensional point. Kept separate from `Vec2` so the file
/// format is stable even if the kernel type changes.
struct FFPoint2: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: Vec2) {
        self.init(x: point.x, y: point.y)
    }

    var vector: Vec2 { Vec2(x: x, y: y) }
}

struct FFPoint3: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ point: Vec3) {
        self.init(x: point.x, y: point.y, z: point.z)
    }

    var vector: Vec3 { Vec3(x: x, y: y, z: z) }
}

/// Linear-space colour with premultiplied-free alpha, matching the renderer's
/// sRGB pipeline.
struct FFRGBA: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let gold = FFRGBA(red: 0.83, green: 0.68, blue: 0.33, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Translation in millimetres, Euler rotation in radians (X then Y then Z) and
/// a per-axis scale. Composing as T * Rz * Ry * Rx * S keeps the matrix
/// deterministic and easy to mirror in the renderer.
struct FFTransform: Codable, Equatable, Sendable {
    var translation: FFPoint3
    var rotation: FFPoint3
    var scale: FFPoint3

    static let identity = FFTransform(
        translation: FFPoint3(x: 0, y: 0, z: 0),
        rotation: FFPoint3(x: 0, y: 0, z: 0),
        scale: FFPoint3(x: 1, y: 1, z: 1)
    )

    init(translation: FFPoint3, rotation: FFPoint3, scale: FFPoint3) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    /// Decomposes a world or local matrix back into the document's T * Rz * Ry
    /// * Rx * S form. The gizmo edits matrices, so the commit path needs one
    /// conversion rather than a second matrix field in the file format. Shear
    /// is not representable; the orthogonal columns of a T * R * S product are
    /// exact, and a singular axis falls back to a scale of one rather than a
    /// non-finite value.
    init(matrix: Mat4) {
        let columnX = Vec3(x: matrix.m00, y: matrix.m10, z: matrix.m20)
        let columnY = Vec3(x: matrix.m01, y: matrix.m11, z: matrix.m21)
        let columnZ = Vec3(x: matrix.m02, y: matrix.m12, z: matrix.m22)
        let scaleX = max(columnX.length, FFMath.eps)
        let scaleY = max(columnY.length, FFMath.eps)
        let scaleZ = max(columnZ.length, FFMath.eps)

        // R = Rz * Ry * Rx, so its third row is (-sin y, cos y sin x, cos y cos x).
        let r20 = matrix.m20 / scaleX
        let r21 = matrix.m21 / scaleY
        let r22 = matrix.m22 / scaleZ
        let r00 = matrix.m00 / scaleX
        let r10 = matrix.m10 / scaleX
        let r01 = matrix.m01 / scaleY
        let r11 = matrix.m11 / scaleY

        let pitch = asin(FFMath.clamp(-r20, to: -1...1))
        let roll: Double
        let yaw: Double
        if abs(cos(pitch)) > 1e-9 {
            roll = atan2(r21, r22)
            yaw = atan2(r10, r00)
        } else {
            // Gimbal lock: only the sum or difference of roll and yaw is
            // observable, so pin roll and put the whole turn in yaw.
            roll = 0
            yaw = atan2(-r01, r11)
        }

        self.init(
            translation: FFPoint3(x: matrix.m03, y: matrix.m13, z: matrix.m23),
            rotation: FFPoint3(x: roll, y: pitch, z: yaw),
            scale: FFPoint3(x: scaleX, y: scaleY, z: scaleZ)
        )
    }

    var matrix: Mat4 {
        matrix(pivot: Vec3(x: 0, y: 0, z: 0))
    }

    /// The same T * R * S composition with rotation and scale taken about
    /// `pivot`, a point in the node's own local space:
    ///
    ///     T * P * Rz * Ry * Rx * S * P⁻¹
    ///
    /// A zero pivot multiplies out to exactly the old matrix, so every
    /// document written before Phase 33 keeps its geometry untouched. The
    /// pivot is one owner: the renderer, the OBJ exporter and the thumbnail
    /// all compose through this method rather than each adding a translation.
    func matrix(pivot: Vec3) -> Mat4 {
        // A zero pivot keeps the exact operation order every document used
        // before Phase 33, so no pivot-less scene or snapshot fixture can drift.
        guard pivot != Vec3(x: 0, y: 0, z: 0) else {
            return Mat4.translation(translation.vector)
                * Mat4.rotationZ(rotation.z)
                * Mat4.rotationY(rotation.y)
                * Mat4.rotationX(rotation.x)
                * Mat4.scale(x: scale.x, y: scale.y, z: scale.z)
        }
        return Mat4.translation(translation.vector)
            * Mat4.translation(pivot)
            * Mat4.rotationZ(rotation.z)
            * Mat4.rotationY(rotation.y)
            * Mat4.rotationX(rotation.x)
            * Mat4.scale(x: scale.x, y: scale.y, z: scale.z)
            * Mat4.translation(Vec3(x: -pivot.x, y: -pivot.y, z: -pivot.z))
    }

    /// Decomposes a matrix into the pivot-aware form above, keeping `pivot`
    /// fixed. The linear part decides R and S, and the translation is solved
    /// from M = T + P − R·S·P, so a gizmo drag on a node with a pivot moves it
    /// without the pivot's offset being baked into its translation.
    init(matrix: Mat4, pivot: Vec3) {
        let bare = FFTransform(matrix: matrix)
        guard pivot != Vec3(x: 0, y: 0, z: 0) else {
            self = bare
            return
        }
        let rotationScale = Mat4.rotationZ(bare.rotation.z)
            * Mat4.rotationY(bare.rotation.y)
            * Mat4.rotationX(bare.rotation.x)
            * Mat4.scale(x: bare.scale.x, y: bare.scale.y, z: bare.scale.z)
        let turned = rotationScale.transformedVector(pivot)
        self.init(
            translation: FFPoint3(
                x: matrix.m03 - pivot.x + turned.x,
                y: matrix.m13 - pivot.y + turned.y,
                z: matrix.m23 - pivot.z + turned.z
            ),
            rotation: bare.rotation,
            scale: bare.scale
        )
    }
}

// MARK: - Geometry payloads

enum FFCurveKind: String, Codable, Sendable {
    case bezier
    case nurbs
}

/// One curve segment in file form. A Bézier segment carries four control
/// points and no weights or knots; a NURBS segment carries its degree, weights
/// and normalised knot vector.
struct FFCurveSegment: Codable, Equatable, Sendable {
    var kind: FFCurveKind
    var controlPoints: [FFPoint2]
    var weights: [Double]
    var degree: Int
    var knots: [Double]

    init(
        kind: FFCurveKind,
        controlPoints: [FFPoint2],
        weights: [Double] = [],
        degree: Int = 1,
        knots: [Double] = []
    ) {
        self.kind = kind
        self.controlPoints = controlPoints
        self.weights = weights
        self.degree = degree
        self.knots = knots
    }

    init(_ curve: Curve2D) {
        switch curve {
        case .bezier(let bezier):
            self.init(kind: .bezier, controlPoints: bezier.controlPoints.map { FFPoint2($0) })
        case .nurbs(let nurbs):
            self.init(
                kind: .nurbs,
                controlPoints: nurbs.controlPoints.map { FFPoint2($0) },
                weights: nurbs.weights,
                degree: nurbs.degree,
                knots: nurbs.knots
            )
        }
    }

    /// Rebuilds the kernel curve, returning nil when the payload is invalid.
    /// This is the validation seam: a hand-edited or truncated file fails here
    /// instead of producing a curve that silently ignores data.
    var curve: Curve2D? {
        let points = controlPoints.map(\.vector)
        switch kind {
        case .bezier:
            guard weights.isEmpty, knots.isEmpty, points.count >= 2 else { return nil }
            guard let bezier = Bezier2D(points) else { return nil }
            return .bezier(bezier)
        case .nurbs:
            guard let nurbs = NURBSCurve2D(
                degree: degree,
                controlPoints: points,
                weights: weights.isEmpty ? nil : weights,
                knots: knots.isEmpty ? nil : knots
            ) else { return nil }
            return .nurbs(nurbs)
        }
    }
}

/// A connected path of curve segments. `isClosed` is intent, not geometry; the
/// kernel still reports whether the ends meet.
struct FFCurvePayload: Codable, Equatable, Sendable {
    var segments: [FFCurveSegment]
    var isClosed: Bool

    init(segments: [FFCurveSegment], isClosed: Bool = false) {
        self.segments = segments
        self.isClosed = isClosed
    }

    init(_ path: CurvePath2D) {
        self.init(segments: path.curves.map { FFCurveSegment($0) }, isClosed: path.isClosed())
    }

    func path(tolerance: Double = FFTolerance.curveJoin) -> CurvePath2D? {
        let curves = segments.compactMap(\.curve)
        guard curves.count == segments.count, !curves.isEmpty else { return nil }
        return CurvePath2D.joining(curves, tolerance: tolerance)
    }
}

struct FFTriangleIndex: Codable, Equatable, Sendable {
    var a: Int
    var b: Int
    var c: Int

    init(a: Int, b: Int, c: Int) {
        self.a = a
        self.b = b
        self.c = c
    }

    init(_ triangle: MeshTriangle) {
        self.init(a: triangle.a, b: triangle.b, c: triangle.c)
    }

    var triangle: MeshTriangle { MeshTriangle(a, b, c) }
}

/// Indexed triangle mesh in file form. The kernel validates indices on rebuild,
/// so out-of-range or degenerate triangles are rejected rather than loaded.
struct FFMeshPayload: Codable, Equatable, Sendable {
    var positions: [FFPoint3]
    var triangles: [FFTriangleIndex]

    init(positions: [FFPoint3], triangles: [FFTriangleIndex]) {
        self.positions = positions
        self.triangles = triangles
    }

    init(_ mesh: IndexedMesh) {
        self.init(
            positions: mesh.positions.map { FFPoint3($0) },
            triangles: mesh.triangles.map { FFTriangleIndex($0) }
        )
    }

    var mesh: IndexedMesh? {
        IndexedMesh(
            positions: positions.map(\.vector),
            triangles: triangles.map(\.triangle)
        )
    }
}

enum FFNodeGeometry: Codable, Equatable, Sendable {
    case curve(FFCurvePayload)
    case mesh(FFMeshPayload)

    var curve: FFCurvePayload? {
        guard case .curve(let payload) = self else { return nil }
        return payload
    }

    var mesh: FFMeshPayload? {
        guard case .mesh(let payload) = self else { return nil }
        return payload
    }
}

// MARK: - Scene tree

struct FFMaterial: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var baseColor: FFRGBA
    var metallic: Double
    var roughness: Double
    /// The alloy preset that last wrote the three surface values. Optional so
    /// schema-1 documents written before Phase 35 still decode; a missing
    /// preset means the material is custom. Encoding omits it while nil, so an
    /// untouched document's canonical hash does not move.
    var preset: FFAlloyPreset?

    init(
        id: UUID = UUID(),
        name: String,
        baseColor: FFRGBA = .gold,
        metallic: Double = 1,
        roughness: Double = 0.25,
        preset: FFAlloyPreset? = nil
    ) {
        self.id = id
        self.name = name
        self.baseColor = baseColor
        self.metallic = FFMath.clamp(metallic, to: 0...1)
        self.roughness = FFMath.clamp(roughness, to: 0...1)
        self.preset = preset
    }
}

struct FFNode: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var transform: FFTransform
    var isVisible: Bool
    var geometry: FFNodeGeometry?
    var materialID: UUID?
    /// The kind a pick filter sees. Optional so schema-1 documents written
    /// before Phase 18 still decode; a missing kind is a solid.
    var kind: FFPickKind?
    /// The layer this node draws on. Optional so schema-1 documents written
    /// before Phase 20 still decode; a missing assignment belongs to the
    /// document's first layer.
    var layerID: UUID?
    /// The point this node's rotation and scale turn about, in its own local
    /// space. Optional so schema-1 documents written before Phase 33 still
    /// decode; a missing pivot is the origin, which is exactly how every
    /// earlier transform composed. Encoding omits it while it is nil, so an
    /// untouched document's canonical hash does not move.
    var pivot: FFPoint3?
    /// Phase 34's array parameters for a group whose children are the array's
    /// members. Optional so schema-1 documents written before Phase 34 still
    /// decode; a missing array is an ordinary group. Encoding omits it while
    /// nil, so an untouched document's canonical hash does not move.
    var array: FFArrayParameters?
    /// Phase 35's per-face material groups. Optional so schema-1 documents
    /// written before Phase 35 still decode; a missing array means the whole
    /// mesh uses `materialID`. Encoding omits it while nil, so an untouched
    /// document's canonical hash does not move.
    var faceGroups: [FFFaceGroup]?
    /// Phase 41's parametric definition for a primitive curve. Optional so
    /// schema-1 documents written before Phase 41 still decode; encoding omits
    /// it while nil, so an untouched document's canonical hash does not move.
    var curvePrimitive: FFCurvePrimitive?
    /// Phase 53's driving dimensions. Optional so schema-1 documents written
    /// before this field still decode; encoding omits it while nil, so an
    /// untouched document's canonical hash does not move.
    var dimensions: [FFDimensionAnnotation]?
    var children: [FFNode]

    init(
        id: UUID = UUID(),
        name: String,
        transform: FFTransform = .identity,
        isVisible: Bool = true,
        geometry: FFNodeGeometry? = nil,
        materialID: UUID? = nil,
        kind: FFPickKind? = nil,
        layerID: UUID? = nil,
        pivot: FFPoint3? = nil,
        array: FFArrayParameters? = nil,
        faceGroups: [FFFaceGroup]? = nil,
        curvePrimitive: FFCurvePrimitive? = nil,
        dimensions: [FFDimensionAnnotation]? = nil,
        children: [FFNode] = []
    ) {
        self.id = id
        self.name = name
        self.transform = transform
        self.isVisible = isVisible
        self.geometry = geometry
        self.materialID = materialID
        self.kind = kind
        self.layerID = layerID
        self.pivot = pivot
        self.array = array
        self.faceGroups = faceGroups
        self.curvePrimitive = curvePrimitive
        self.dimensions = dimensions
        self.children = children
    }

    var nodeCount: Int {
        1 + children.reduce(0) { $0 + $1.nodeCount }
    }

    func node(withID target: UUID) -> FFNode? {
        if id == target { return self }
        for child in children {
            if let match = child.node(withID: target) { return match }
        }
        return nil
    }

    /// Returns a copy with the matching node replaced, or nil when the subtree
    /// does not contain it. Used by the document's node editing helpers.
    func replacingNode(withID target: UUID, with replacement: (inout FFNode) -> Void) -> FFNode? {
        if id == target {
            var copy = self
            replacement(&copy)
            return copy
        }
        for index in children.indices {
            if let updated = children[index].replacingNode(withID: target, with: replacement) {
                var copy = self
                copy.children[index] = updated
                return copy
            }
        }
        return nil
    }
}

struct FFDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case displayUnit
        case materials
        case rootNodes
        case displayModes
        case layers
        case currentLayerID
        case layerSets
        case activeLayerSetID
        case measurements
        case metadata
    }

    var schemaVersion: Int
    var name: String
    var displayUnit: FFLengthUnit
    var materials: [FFMaterial]
    var rootNodes: [FFNode]
    /// Each viewport keeps its own display mode, keyed by pane id. The field is
    /// additive in schema 1: an older document decodes to an empty map and
    /// every pane opens Shaded.
    var displayModes: [String: FFDisplayMode]
    /// Drawing layers and the layer new nodes are assigned to. Phase 20 makes
    /// these document state so membership, visibility, lock and colour survive
    /// save and reopen.
    var layers: [FFLayer]
    var currentLayerID: UUID?
    /// Phase 31's named snapshots of the layer states. A file written before
    /// this field decodes to one Default set capturing its decoded layers, so
    /// every document can switch sets from the first open.
    var layerSets: [FFLayerSet]
    var activeLayerSetID: UUID?
    /// Committed measurements. Phase 19 kept them in the pane's tool session;
    /// Phase 23 makes them document annotations so a measurement is one undo
    /// step and survives save and reopen. Additive in schema 1: a file written
    /// before this field decodes to no annotations.
    var measurements: [FFMeasurementAnnotation]
    /// Phase 36's production paperwork. Optional so schema-1 documents written
    /// before this field still decode; encoding omits it while nil, so an
    /// untouched document's canonical hash does not move.
    var metadata: FFMetadata?

    init(
        name: String = "Untitled",
        displayUnit: FFLengthUnit = .millimetres,
        materials: [FFMaterial] = [],
        rootNodes: [FFNode] = [],
        displayModes: [String: FFDisplayMode] = [:],
        layers: [FFLayer] = [FFLayer.defaultLayer],
        currentLayerID: UUID? = nil,
        layerSets: [FFLayerSet] = [],
        activeLayerSetID: UUID? = nil,
        measurements: [FFMeasurementAnnotation] = [],
        metadata: FFMetadata? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.displayUnit = displayUnit
        self.materials = materials
        self.rootNodes = rootNodes
        self.displayModes = displayModes
        self.layers = layers.isEmpty ? [FFLayer.defaultLayer] : layers
        self.currentLayerID = currentLayerID ?? self.layers.first?.id
        let resolvedSets = layerSets.isEmpty
            ? [FFLayerSet.capturing(self.layers, name: "Default")]
            : layerSets
        self.layerSets = resolvedSets
        self.activeLayerSetID = resolvedSets.contains { $0.id == activeLayerSetID }
            ? activeLayerSetID
            : resolvedSets.first?.id
        self.measurements = measurements
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version <= Self.currentSchemaVersion else {
            throw FFDocumentError.unsupportedSchemaVersion(version)
        }
        self.schemaVersion = version
        self.name = try container.decode(String.self, forKey: .name)
        self.displayUnit = try container.decodeIfPresent(FFLengthUnit.self, forKey: .displayUnit) ?? .millimetres
        self.materials = try container.decodeIfPresent([FFMaterial].self, forKey: .materials) ?? []
        self.rootNodes = try container.decodeIfPresent([FFNode].self, forKey: .rootNodes) ?? []
        self.displayModes = try container.decodeIfPresent(
            [String: FFDisplayMode].self,
            forKey: .displayModes
        ) ?? [:]
        let decodedLayers = try container.decodeIfPresent([FFLayer].self, forKey: .layers) ?? []
        self.layers = decodedLayers.isEmpty ? [FFLayer.defaultLayer] : decodedLayers
        self.currentLayerID = try container.decodeIfPresent(UUID.self, forKey: .currentLayerID)
            ?? self.layers.first?.id
        let decodedSets = try container.decodeIfPresent([FFLayerSet].self, forKey: .layerSets) ?? []
        self.layerSets = decodedSets.isEmpty
            ? [FFLayerSet.capturing(self.layers, name: "Default")]
            : decodedSets
        let decodedActive = try container.decodeIfPresent(UUID.self, forKey: .activeLayerSetID)
        self.activeLayerSetID = self.layerSets.contains { $0.id == decodedActive }
            ? decodedActive
            : self.layerSets.first?.id
        self.measurements = try container.decodeIfPresent(
            [FFMeasurementAnnotation].self,
            forKey: .measurements
        ) ?? []
        self.metadata = try container.decodeIfPresent(FFMetadata.self, forKey: .metadata)
    }

    var nodeCount: Int {
        rootNodes.reduce(0) { $0 + $1.nodeCount }
    }

    var curveNodeCount: Int {
        rootNodes.reduce(0) { total, node in
            total + Self.countNodes(in: node) { $0.geometry?.curve != nil }
        }
    }

    var meshNodeCount: Int {
        rootNodes.reduce(0) { total, node in
            total + Self.countNodes(in: node) { $0.geometry?.mesh != nil }
        }
    }

    func node(withID target: UUID) -> FFNode? {
        for root in rootNodes {
            if let match = root.node(withID: target) { return match }
        }
        return nil
    }

    func material(withID target: UUID) -> FFMaterial? {
        materials.first { $0.id == target }
    }

    /// Mutates the node with `target`, returning false when it is absent. The
    /// session's commands use this so an edit never silently does nothing.
    @discardableResult
    mutating func updateNode(withID target: UUID, _ edit: (inout FFNode) -> Void) -> Bool {
        for index in rootNodes.indices {
            if let updated = rootNodes[index].replacingNode(withID: target, with: edit) {
                rootNodes[index] = updated
                return true
            }
        }
        return false
    }

    /// Canonical JSON for hashing and for the save path. Sorted keys make the
    /// output independent of dictionary order and therefore hash-stable.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> FFDocument {
        try JSONDecoder().decode(FFDocument.self, from: data)
    }

    /// SHA-256 of the canonical encoding. Used by the undo/redo tests to prove
    /// that a round trip restores the exact document, not merely an equal one.
    var stateHash: String {
        guard let data = try? encoded() else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func countNodes(in node: FFNode, where predicate: (FFNode) -> Bool) -> Int {
        let own = predicate(node) ? 1 : 0
        return own + node.children.reduce(0) { $0 + countNodes(in: $1, where: predicate) }
    }
}
