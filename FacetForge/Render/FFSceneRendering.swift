import Foundation
import simd

/// What a node looks like to the renderer. The document keeps a richer
/// material; this is only what the shading pass consumes.
struct FFRenderMaterial: Equatable, Sendable {
    var baseColor: FFRGBA
    var metallic: Double
    var roughness: Double

    static let gold = FFRenderMaterial(baseColor: .gold, metallic: 1.0, roughness: 0.24)
    static let gem = FFRenderMaterial(
        baseColor: FFRGBA(red: 0.52, green: 0.84, blue: 0.96),
        metallic: 0.05,
        roughness: 0.08
    )

    init(baseColor: FFRGBA, metallic: Double, roughness: Double) {
        self.baseColor = baseColor
        self.metallic = FFMath.clamp(metallic.isFinite ? metallic : 0, to: 0...1)
        self.roughness = FFMath.clamp(roughness.isFinite ? roughness : 0.5, to: 0.02...1)
    }
}

/// A triangle mesh in the flat layout the GPU wants: three positions and three
/// normals per vertex, 32-bit indices, no intermediate object graph.
struct FFRenderMesh: Equatable, Sendable {
    var positions: [Vec3]
    var normals: [Vec3]
    var indices: [UInt32]
    var bounds: AABB?

    var triangleCount: Int { indices.count / 3 }

    init?(mesh: IndexedMesh) {
        guard !mesh.positions.isEmpty, !mesh.triangles.isEmpty else { return nil }
        let normals = mesh.vertexNormals()
        guard normals.count == mesh.positions.count else { return nil }
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.triangles.count * 3)
        for triangle in mesh.triangles {
            indices.append(UInt32(triangle.a))
            indices.append(UInt32(triangle.b))
            indices.append(UInt32(triangle.c))
        }
        self.positions = mesh.positions
        self.normals = normals
        self.indices = indices
        self.bounds = mesh.bounds
    }

    init(positions: [Vec3], normals: [Vec3], indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.bounds = Self.bounds(of: positions)
    }

    private static func bounds(of positions: [Vec3]) -> AABB? {
        guard let first = positions.first else { return nil }
        var box = AABB(minimum: first, maximum: first)
        for position in positions.dropFirst() {
            box = box.union(AABB(minimum: position, maximum: position))
        }
        return box
    }
}

/// One material's slice of a node's faces. `id` is the face group that owns
/// the material (or the node itself for the base slice), so the renderer can
/// cache an unchanged part across frames. Parts partition the node's triangles;
/// the node's `mesh` remains the whole payload for picking and bounds.
struct FFRenderPart: Equatable, Sendable, Identifiable {
    let id: UUID
    var mesh: FFRenderMesh
    var material: FFRenderMaterial

    init(id: UUID, mesh: FFRenderMesh, material: FFRenderMaterial) {
        self.id = id
        self.mesh = mesh
        self.material = material
    }

    var triangleCount: Int { mesh.triangleCount }

    /// FNV-1a over this part's indices. A face group's id survives a
    /// reassignment that moves triangles between materials, so the count alone
    /// cannot tell the renderer that its cached buffer is stale; this can.
    var signature: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for index in mesh.indices {
            hash = (hash ^ UInt64(index)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// One mesh placed in the world. `id` is stable so the renderer can cache the
/// vertex buffers of an unchanged node across frames.
struct FFRenderNode: Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var mesh: FFRenderMesh
    var transform: Mat4
    var material: FFRenderMaterial
    var isSelected: Bool
    var kind: FFPickKind
    /// Hidden nodes are neither drawn nor written to the picking buffer. They
    /// keep their scene index so the ID mapping stays stable.
    var isVisible: Bool
    /// The colour of the layer this node draws on. Wireframe draws its line
    /// work in this colour; every other mode keeps the mode's own edge colour.
    var layerColor: FFRGBA
    /// Per-material face slices. Empty for a node with no face groups, which
    /// draws exactly as it did before Phase 35.
    var parts: [FFRenderPart]
    /// Phase 54's content hash for preview geometry. Zero for every document
    /// node, whose buffers are keyed by id alone; a preview reuses its derived
    /// id across rebuilds, so it needs the hash to prove the buffer is current.
    var cacheSignature: UInt64

    init(
        id: UUID = UUID(),
        name: String,
        mesh: FFRenderMesh,
        transform: Mat4 = .identity,
        material: FFRenderMaterial = .gold,
        isSelected: Bool = false,
        kind: FFPickKind = .solid,
        isVisible: Bool = true,
        layerColor: FFRGBA = .gold,
        parts: [FFRenderPart] = [],
        cacheSignature: UInt64 = 0
    ) {
        self.id = id
        self.name = name
        self.mesh = mesh
        self.transform = transform
        self.material = material
        self.isSelected = isSelected
        self.kind = kind
        self.isVisible = isVisible
        self.layerColor = layerColor
        self.parts = parts
        self.cacheSignature = cacheSignature
    }
}

/// Everything the viewport draws in one frame. The scene is a value so a test
/// can compare two frames without touching the renderer.
struct FFViewportScene: Equatable, Sendable {
    var nodes: [FFRenderNode]
    /// Phase 54's ghost geometry: a profile sweep that is being previewed but
    /// has not been committed. It lives beside the document nodes rather than
    /// in them so picking, selection, bounds and the triangle count are all
    /// exactly what they were before a preview opened; the renderer draws this
    /// list in its own blended pass.
    var preview: [FFRenderNode]

    static let empty = FFViewportScene(nodes: [])

    init(nodes: [FFRenderNode], preview: [FFRenderNode] = []) {
        self.nodes = nodes
        self.preview = preview
    }

    var triangleCount: Int {
        nodes.reduce(0) { $0 + $1.mesh.triangleCount }
    }

    var previewTriangleCount: Int {
        preview.reduce(0) { $0 + $1.mesh.triangleCount }
    }

    /// The scene a preview pass draws. Nil when there is nothing to ghost, so a
    /// document with no preview keeps the scene it always had.
    func showingPreview(_ nodes: [FFRenderNode]) -> FFViewportScene {
        guard !nodes.isEmpty else { return self }
        return FFViewportScene(nodes: self.nodes, preview: nodes)
    }

    var selectedNodeIDs: [UUID] {
        nodes.filter(\.isSelected).map(\.id)
    }

    /// The world bounds of every node, including each node's transform.
    var bounds: AABB? {
        var box: AABB?
        for node in nodes {
            guard let local = node.mesh.bounds else { continue }
            let minimum = local.minimum
            let maximum = local.maximum
            let corners = [
                Vec3(x: minimum.x, y: minimum.y, z: minimum.z),
                Vec3(x: maximum.x, y: minimum.y, z: minimum.z),
                Vec3(x: minimum.x, y: maximum.y, z: minimum.z),
                Vec3(x: maximum.x, y: maximum.y, z: minimum.z),
                Vec3(x: minimum.x, y: minimum.y, z: maximum.z),
                Vec3(x: maximum.x, y: minimum.y, z: maximum.z),
                Vec3(x: minimum.x, y: maximum.y, z: maximum.z),
                Vec3(x: maximum.x, y: maximum.y, z: maximum.z)
            ]
            for corner in corners {
                let world = node.transform * Vec4(x: corner.x, y: corner.y, z: corner.z, w: 1)
                let point = AABB(
                    minimum: Vec3(x: world.x, y: world.y, z: world.z),
                    maximum: Vec3(x: world.x, y: world.y, z: world.z)
                )
                box = box.map { $0.union(point) } ?? point
            }
        }
        return box
    }

    func node(id: UUID) -> FFRenderNode? {
        nodes.first { $0.id == id }
    }

    func selecting(_ ids: [UUID]) -> FFViewportScene {
        let selected = Set(ids)
        return FFViewportScene(nodes: nodes.map { node in
            var copy = node
            copy.isSelected = selected.contains(node.id)
            return copy
        }, preview: preview)
    }
}

/// The seam between the app and whatever draws the scene. The Metal viewport
/// is the shipping implementation; the protocol keeps the viewport testable
/// through one entry point instead of a UIView subclass.
protocol ViewportRendering: AnyObject {
    var drawCallCount: Int { get }
    var lastCommandBufferError: String? { get }
    var lastSubmitMilliseconds: Double { get }

    @discardableResult
    func render(scene: FFViewportScene, camera: FFCamera, width: Int, height: Int) -> FFViewportReadback?
}

extension Mat4 {
    /// Column-major `float4x4` for Metal and RealityKit. `Mat4` stores rows,
    /// so the matrix is transposed on the way out exactly once, here.
    var simdMatrix: simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(Float(m00), Float(m10), Float(m20), Float(m30)),
            SIMD4<Float>(Float(m01), Float(m11), Float(m21), Float(m31)),
            SIMD4<Float>(Float(m02), Float(m12), Float(m22), Float(m32)),
            SIMD4<Float>(Float(m03), Float(m13), Float(m23), Float(m33))
        )
    }
}
