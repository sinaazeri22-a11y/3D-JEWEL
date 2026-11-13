import Foundation

/// A triangle addressing three vertices of an `IndexedMesh`.
struct MeshTriangle: Equatable, Hashable, Sendable {
    let a: Int
    let b: Int
    let c: Int

    init(_ a: Int, _ b: Int, _ c: Int) {
        self.a = a
        self.b = b
        self.c = c
    }

    var indices: [Int] { [a, b, c] }

    func vertex(_ position: Int) -> Int {
        switch position {
        case 0: return a
        case 1: return b
        default: return c
        }
    }
}

/// A ray hit on a triangle, including barycentric weights for the three
/// vertices in winding order.
struct MeshRayHit: Equatable, Sendable {
    let triangleIndex: Int
    let distance: Double
    let point: Vec3
    let barycentric: Vec3
}

/// The result of the Phase 7 classification predicates.
struct MeshClassification: Equatable, Sendable {
    let isManifold: Bool
    let isWatertight: Bool
    let isConsistentlyOriented: Bool
    let boundaryEdgeCount: Int
    let nonManifoldEdgeCount: Int
    let nonManifoldVertexCount: Int
}

private struct MeshUndirectedEdge: Hashable {
    let low: Int
    let high: Int

    init(_ first: Int, _ second: Int) {
        low = min(first, second)
        high = max(first, second)
    }
}

private struct MeshDirectedEdge: Hashable {
    let from: Int
    let to: Int
}

private struct MeshHalfEdge {
    let origin: Int
    let destination: Int
    let next: Int
    let face: Int
}

/// An indexed triangle mesh in millimetres.
///
/// The kernel deliberately rejects repeated vertex indices in a triangle:
/// a zero-area face has no normal and would make every later predicate
/// ambiguous. Collinear vertices are allowed so callers can weld or repair a
/// mesh before using it.
struct IndexedMesh: Equatable, Sendable {
    let positions: [Vec3]
    let triangles: [MeshTriangle]

    init?(positions: [Vec3], triangles: [MeshTriangle]) {
        guard positions.allSatisfy({ position in
            position.x.isFinite && position.y.isFinite && position.z.isFinite
        }) else { return nil }

        for triangle in triangles {
            let indices = triangle.indices
            guard indices.allSatisfy({ $0 >= 0 && $0 < positions.count }) else { return nil }
            guard Set(indices).count == 3 else { return nil }
        }

        self.positions = positions
        self.triangles = triangles
    }

    init?(positions: [Vec3], indices: [Int]) {
        guard indices.count % 3 == 0 else { return nil }
        var triangles: [MeshTriangle] = []
        triangles.reserveCapacity(indices.count / 3)
        for start in stride(from: 0, to: indices.count, by: 3) {
            triangles.append(MeshTriangle(indices[start], indices[start + 1], indices[start + 2]))
        }
        self.init(positions: positions, triangles: triangles)
    }

    var triangleCount: Int { triangles.count }

    var bounds: AABB? {
        guard let first = positions.first else { return nil }
        var box = AABB(minimum: first, maximum: first)
        for position in positions.dropFirst() {
            box = box.union(AABB(minimum: position, maximum: position))
        }
        return box
    }

    func vertices(of triangleIndex: Int) -> (Vec3, Vec3, Vec3) {
        let triangle = triangles[triangleIndex]
        return (
            positions[triangle.a],
            positions[triangle.b],
            positions[triangle.c]
        )
    }

    func faceNormal(_ triangleIndex: Int, tolerance: Double = 1e-12) -> Vec3? {
        let (a, b, c) = vertices(of: triangleIndex)
        return (b - a).cross(c - a).normalized(tolerance: tolerance)
    }

    func triangleArea(_ triangleIndex: Int) -> Double {
        let (a, b, c) = vertices(of: triangleIndex)
        return (b - a).cross(c - a).length * 0.5
    }

    func triangleBounds(_ triangleIndex: Int) -> AABB {
        let (a, b, c) = vertices(of: triangleIndex)
        return AABB(
            minimum: a.componentMin(b).componentMin(c),
            maximum: a.componentMax(b).componentMax(c)
        )
    }

    /// Area-weighted vertex normals. A vertex with no non-degenerate incident
    /// face returns the zero vector rather than an arbitrary direction.
    ///
    /// A face's area-weighted normal is `normalize(cross) * (|cross| / 2)`, and
    /// those two factors cancel exactly: `|cross|` is twice the triangle's area,
    /// so the result is `cross / 2`. Computing it that way costs one cross
    /// product and one vertex fetch per face instead of two of each plus two
    /// square roots and three per-axis divisions. `faceNormal`'s tolerance
    /// survives as the length test that decides whether a face is degenerate.
    func vertexNormals() -> [Vec3] {
        var accumulated = [Vec3](repeating: .zero, count: positions.count)
        for triangle in triangles {
            let a = positions[triangle.a]
            let b = positions[triangle.b]
            let c = positions[triangle.c]
            let cross = (b - a).cross(c - a)
            guard cross.length > 1e-12 else { continue }
            let weighted = cross * 0.5
            accumulated[triangle.a] = accumulated[triangle.a] + weighted
            accumulated[triangle.b] = accumulated[triangle.b] + weighted
            accumulated[triangle.c] = accumulated[triangle.c] + weighted
        }
        return accumulated.map { $0.normalized() ?? .zero }
    }

    /// The signed volume of the closed surface, positive for outward winding.
    /// For an open mesh the value depends on the chosen origin and is not a
    /// watertightness proof.
    func signedVolume() -> Double {
        var total = 0.0
        for triangleIndex in triangles.indices {
            let (a, b, c) = vertices(of: triangleIndex)
            total += a.dot(b.cross(c))
        }
        return total / 6
    }

    /// Merges vertices closer than `tolerance`, remaps triangles and drops
    /// faces that collapse to an edge or a point.
    func welded(tolerance: Double = 1e-9) -> IndexedMesh {
        guard tolerance > 0, !positions.isEmpty else { return self }

        var uniquePositions: [Vec3] = []
        var remap = [Int](repeating: -1, count: positions.count)
        for (index, position) in positions.enumerated() {
            if let existing = uniquePositions.firstIndex(where: {
                $0.distance(to: position) <= tolerance
            }) {
                remap[index] = existing
            } else {
                remap[index] = uniquePositions.count
                uniquePositions.append(position)
            }
        }

        var weldedTriangles: [MeshTriangle] = []
        weldedTriangles.reserveCapacity(triangles.count)
        for triangle in triangles {
            let a = remap[triangle.a]
            let b = remap[triangle.b]
            let c = remap[triangle.c]
            guard Set([a, b, c]).count == 3 else { continue }
            weldedTriangles.append(MeshTriangle(a, b, c))
        }

        return IndexedMesh(positions: uniquePositions, triangles: weldedTriangles) ?? self
    }

    /// Builds half-edge adjacency and the manifold, watertight and orientation
    /// predicates in one pass over the edges and one pass over the vertices.
    ///
    /// A vertex whose outgoing half-edges form more than one fan is reported
    /// as non-manifold. That includes the classic bow-tie (two triangles that
    /// meet only at a vertex) and a fan whose winding prevents a twin link.
    var classification: MeshClassification {
        var halfEdges: [MeshHalfEdge] = []
        halfEdges.reserveCapacity(triangles.count * 3)
        for (face, triangle) in triangles.enumerated() {
            let indices = triangle.indices
            for corner in 0..<3 {
                halfEdges.append(MeshHalfEdge(
                    origin: indices[corner],
                    destination: indices[(corner + 1) % 3],
                    next: face * 3 + (corner + 1) % 3,
                    face: face
                ))
            }
        }

        var undirected: [MeshUndirectedEdge: [Int]] = [:]
        var directed: [MeshDirectedEdge: [Int]] = [:]
        for (index, halfEdge) in halfEdges.enumerated() {
            undirected[
                MeshUndirectedEdge(halfEdge.origin, halfEdge.destination),
                default: []
            ].append(index)
            directed[
                MeshDirectedEdge(from: halfEdge.origin, to: halfEdge.destination),
                default: []
            ].append(index)
        }

        var twins = [Int?](repeating: nil, count: halfEdges.count)
        var boundaryEdgeCount = 0
        var nonManifoldEdgeCount = 0
        var oriented = true

        for (_, incident) in undirected {
            if incident.count == 1 {
                boundaryEdgeCount += 1
                continue
            }
            guard incident.count == 2 else {
                nonManifoldEdgeCount += 1
                oriented = false
                continue
            }
            let first = incident[0]
            let second = incident[1]
            if halfEdges[first].origin == halfEdges[second].destination
                && halfEdges[first].destination == halfEdges[second].origin
            {
                twins[first] = second
                twins[second] = first
            } else {
                oriented = false
            }
        }
        for (_, incident) in directed where incident.count > 1 {
            oriented = false
        }

        // Outgoing half-edges are bucketed once, in ascending half-edge order,
        // which is exactly the order the per-vertex filter produced. Filtering
        // the whole half-edge array for every vertex is quadratic in mesh size:
        // on a 55k-vertex, 110k-triangle ring sweep that is ~9 billion
        // comparisons, measured at 240.0 s on the gate runner and 248.8 s on a
        // loaded one. The bucket makes the pass O(vertices + half-edges) without
        // changing a single predicate below.
        var outgoingByVertex = [[Int]](repeating: [], count: positions.count)
        for (index, halfEdge) in halfEdges.enumerated() {
            outgoingByVertex[halfEdge.origin].append(index)
        }

        var nonManifoldVertexCount = 0
        for outgoing in outgoingByVertex where outgoing.count > 1 {

            var parent = Array(0..<outgoing.count)
            func root(_ value: Int) -> Int {
                var current = value
                while parent[current] != current {
                    parent[current] = parent[parent[current]]
                    current = parent[current]
                }
                return current
            }
            func unite(_ first: Int, _ second: Int) {
                let firstRoot = root(first)
                let secondRoot = root(second)
                if firstRoot != secondRoot {
                    parent[secondRoot] = firstRoot
                }
            }

            for localIndex in outgoing.indices {
                guard let twin = twins[outgoing[localIndex]] else { continue }
                let next = halfEdges[twin].next
                if let other = outgoing.firstIndex(of: next) {
                    unite(localIndex, other)
                }
            }

            var components = Set<Int>()
            for localIndex in outgoing.indices {
                components.insert(root(localIndex))
            }
            if components.count > 1 {
                nonManifoldVertexCount += 1
            }
        }

        let isManifold = nonManifoldEdgeCount == 0 && nonManifoldVertexCount == 0
        return MeshClassification(
            isManifold: isManifold,
            isWatertight: isManifold && boundaryEdgeCount == 0 && oriented,
            isConsistentlyOriented: oriented,
            boundaryEdgeCount: boundaryEdgeCount,
            nonManifoldEdgeCount: nonManifoldEdgeCount,
            nonManifoldVertexCount: nonManifoldVertexCount
        )
    }

    func rayHit(
        triangleIndex: Int,
        ray: Ray,
        tolerance: Double = 1e-9
    ) -> MeshRayHit? {
        let (a, b, c) = vertices(of: triangleIndex)
        let edgeAB = b - a
        let edgeAC = c - a
        let perpendicular = ray.direction.cross(edgeAC)
        let determinant = edgeAB.dot(perpendicular)
        guard abs(determinant) > tolerance else { return nil }

        let inverse = 1 / determinant
        let toOrigin = ray.origin - a
        let u = toOrigin.dot(perpendicular) * inverse
        guard u >= -tolerance, u <= 1 + tolerance else { return nil }

        let cross = toOrigin.cross(edgeAB)
        let v = ray.direction.dot(cross) * inverse
        guard v >= -tolerance, u + v <= 1 + tolerance else { return nil }

        let distance = edgeAC.dot(cross) * inverse
        guard distance >= -tolerance else { return nil }
        let t = max(0, distance)
        return MeshRayHit(
            triangleIndex: triangleIndex,
            distance: t,
            point: ray.point(at: t),
            barycentric: Vec3(x: 1 - u - v, y: u, z: v)
        )
    }

    /// Brute-force reference used by the BVH acceptance test.
    func raycast(_ ray: Ray, tolerance: Double = 1e-9) -> MeshRayHit? {
        var best: MeshRayHit?
        for triangleIndex in triangles.indices {
            guard let hit = rayHit(
                triangleIndex: triangleIndex,
                ray: ray,
                tolerance: tolerance
            ) else { continue }
            if let current = best {
                if hit.distance < current.distance - 1e-12
                    || (abs(hit.distance - current.distance) <= 1e-12
                        && hit.triangleIndex < current.triangleIndex)
                {
                    best = hit
                }
            } else {
                best = hit
            }
        }
        return best
    }
}

/// A bounding-volume hierarchy over the mesh triangles. Leaves hold at most
/// `leafSize` triangle indices; internal nodes split the centroid axis with
/// the largest spread.
struct MeshBVH {
    struct Node: Equatable, Sendable {
        let bounds: AABB
        let left: Int
        let right: Int
        let start: Int
        let count: Int

        var isLeaf: Bool { count > 0 }
    }

    let mesh: IndexedMesh
    let nodes: [Node]
    let triangleOrder: [Int]

    init(mesh: IndexedMesh, leafSize: Int = 4) {
        self.mesh = mesh
        let triangleCount = mesh.triangles.count
        guard triangleCount > 0 else {
            nodes = []
            triangleOrder = []
            return
        }

        let safeLeafSize = max(1, leafSize)
        var order = Array(0..<triangleCount)
        let bounds = mesh.triangles.indices.map { mesh.triangleBounds($0) }
        let centroids = mesh.triangles.indices.map { index -> Vec3 in
            let (a, b, c) = mesh.vertices(of: index)
            return (a + b + c) / 3
        }
        var builtNodes: [Node] = []

        func build(start: Int, end: Int) -> Int {
            var nodeBounds = bounds[order[start]]
            for index in (start + 1)..<end {
                nodeBounds = nodeBounds.union(bounds[order[index]])
            }

            let nodeIndex = builtNodes.count
            builtNodes.append(Node(
                bounds: nodeBounds,
                left: -1,
                right: -1,
                start: 0,
                count: 0
            ))

            if end - start <= safeLeafSize {
                builtNodes[nodeIndex] = Node(
                    bounds: nodeBounds,
                    left: -1,
                    right: -1,
                    start: start,
                    count: end - start
                )
                return nodeIndex
            }

            var minimum = centroids[order[start]]
            var maximum = minimum
            for index in (start + 1)..<end {
                let centroid = centroids[order[index]]
                minimum = minimum.componentMin(centroid)
                maximum = maximum.componentMax(centroid)
            }
            let spread = maximum - minimum
            let axis: Int
            if spread.x >= spread.y && spread.x >= spread.z {
                axis = 0
            } else if spread.y >= spread.z {
                axis = 1
            } else {
                axis = 2
            }

            let sorted = order[start..<end].sorted { first, second in
                let firstValue = Self.component(centroids[first], axis)
                let secondValue = Self.component(centroids[second], axis)
                if firstValue != secondValue {
                    return firstValue < secondValue
                }
                return first < second
            }
            order.replaceSubrange(start..<end, with: sorted)
            let middle = (start + end) / 2
            let left = build(start: start, end: middle)
            let right = build(start: middle, end: end)
            builtNodes[nodeIndex] = Node(
                bounds: nodeBounds,
                left: left,
                right: right,
                start: 0,
                count: 0
            )
            return nodeIndex
        }

        _ = build(start: 0, end: triangleCount)
        nodes = builtNodes
        triangleOrder = order
    }

    func raycast(_ ray: Ray, tolerance: Double = 1e-9) -> MeshRayHit? {
        guard !nodes.isEmpty else { return nil }
        var stack = [0]
        var best: MeshRayHit?

        while let nodeIndex = stack.popLast() {
            let node = nodes[nodeIndex]
            guard ray.intersection(with: node.bounds) != nil else { continue }

            if node.isLeaf {
                for offset in 0..<node.count {
                    let triangleIndex = triangleOrder[node.start + offset]
                    guard let hit = mesh.rayHit(
                        triangleIndex: triangleIndex,
                        ray: ray,
                        tolerance: tolerance
                    ) else { continue }
                    if let current = best {
                        if hit.distance < current.distance - 1e-12
                            || (abs(hit.distance - current.distance) <= 1e-12
                                && hit.triangleIndex < current.triangleIndex)
                        {
                            best = hit
                        }
                    } else {
                        best = hit
                    }
                }
            } else {
                if node.left >= 0 { stack.append(node.left) }
                if node.right >= 0 { stack.append(node.right) }
            }
        }
        return best
    }

    private static func component(_ vector: Vec3, _ axis: Int) -> Double {
        switch axis {
        case 0: return vector.x
        case 1: return vector.y
        default: return vector.z
        }
    }
}
