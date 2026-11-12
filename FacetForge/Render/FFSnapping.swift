import CoreGraphics
import Foundation

/// The snap vocabulary of the viewport. Every kind is a separate candidate, so
/// the marker list can show a jeweller what the cursor is considering instead of
/// silently jumping to one answer.
enum FFSnapKind: String, CaseIterable, Identifiable, Sendable {
    case vertex
    case endpoint
    case midpoint
    case centre
    case intersection
    case perpendicular
    case tangent
    case onCurve
    case angle
    case grid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertex: return "Vertex"
        case .endpoint: return "Endpoint"
        case .midpoint: return "Midpoint"
        case .centre: return "Centre"
        case .intersection: return "Intersection"
        case .perpendicular: return "Perpendicular"
        case .tangent: return "Tangent"
        case .onCurve: return "On curve"
        case .angle: return "Angle"
        case .grid: return "Grid"
        }
    }

    /// Lower breaks a sub-pixel tie: an endpoint and the on-curve point at the
    /// same screen position resolve to the endpoint. Proximity still outranks
    /// kind, so a strong snap never steals the cursor from a closer one.
    var priority: Int {
        switch self {
        case .vertex: return 0
        case .endpoint: return 1
        case .midpoint: return 2
        case .centre: return 3
        case .intersection: return 4
        case .perpendicular: return 5
        case .tangent: return 6
        case .onCurve: return 7
        case .angle: return 8
        case .grid: return 9
        }
    }

    /// Angle and grid are inference, not geometry the jeweller drew. They only
    /// answer when no real snap is under the cursor, and angle outranks grid.
    var isProjectionAid: Bool {
        switch self {
        case .angle, .grid: return true
        default: return false
        }
    }
}

struct FFSnapPoint: Equatable, Sendable {
    var position: Vec3
    var kind: FFSnapKind

    init(_ position: Vec3, kind: FFSnapKind = .vertex) {
        self.position = position
        self.kind = kind
    }
}

struct FFSnapSegment: Equatable, Sendable {
    var a: Vec3
    var b: Vec3

    init(_ a: Vec3, _ b: Vec3) {
        self.a = a
        self.b = b
    }
}

/// A circle in 3-D. Tangency is solved in the circle's own plane, so a tilted
/// stone facet girdle snaps as correctly as a flat ring.
struct FFSnapCircle: Equatable, Sendable {
    var centre: Vec3
    var normal: Vec3
    var radius: Double

    init(centre: Vec3, normal: Vec3 = .unitY, radius: Double) {
        self.centre = centre
        self.normal = normal
        self.radius = max(0, radius)
    }
}

struct FFSnapGeometry: Equatable, Sendable {
    var points: [FFSnapPoint] = []
    var segments: [FFSnapSegment] = []
    var circles: [FFSnapCircle] = []
    var gridStep: Double = 1
    var gridPlaneY: Double = 0

    /// Feature geometry for the object being transformed. Vertices and mesh
    /// edges come from the selection only: snapping is an aid to the gesture in
    /// progress, and every other object contributes its centre. The vertex and
    /// edge caps keep a dense export mesh from turning a mouse move into a
    /// scene-wide traversal.
    static func features(of scene: FFViewportScene, selectedID: UUID?) -> FFSnapGeometry {
        features(of: scene, selectedIDs: selectedID.map { Set([$0]) } ?? [])
    }

    /// Several nodes can contribute vertices and edges at once. Measuring needs
    /// that: its points may lie on any visible object, not only on the one the
    /// gizmo happens to own. The per-node caps still bound the work.
    static func features(of scene: FFViewportScene, selectedIDs: Set<UUID>) -> FFSnapGeometry {
        var geometry = FFSnapGeometry()
        let vertexCap = 2_048
        let edgeCap = 4_096

        for node in scene.nodes {
            if let bounds = node.mesh.bounds {
                let local = Vec3(
                    x: (bounds.minimum.x + bounds.maximum.x) * 0.5,
                    y: (bounds.minimum.y + bounds.maximum.y) * 0.5,
                    z: (bounds.minimum.z + bounds.maximum.z) * 0.5
                )
                let world = node.transform * Vec4(x: local.x, y: local.y, z: local.z, w: 1)
                if abs(world.w) > FFMath.eps {
                    geometry.points.append(FFSnapPoint(
                        Vec3(x: world.x / world.w, y: world.y / world.w, z: world.z / world.w),
                        kind: .centre
                    ))
                }
            }

            guard selectedIDs.contains(node.id), node.isVisible else { continue }
            let positions = node.mesh.positions.map { position -> Vec3 in
                let world = node.transform * Vec4(
                    x: position.x,
                    y: position.y,
                    z: position.z,
                    w: 1
                )
                guard abs(world.w) > FFMath.eps else { return position }
                return Vec3(x: world.x / world.w, y: world.y / world.w, z: world.z / world.w)
            }

            for index in 0..<min(positions.count, vertexCap) {
                geometry.points.append(FFSnapPoint(positions[index], kind: .vertex))
            }

            var seen = Set<UInt64>()
            let indices = node.mesh.indices
            var edgeCount = 0
            var triangle = 0
            while triangle + 2 < indices.count, edgeCount < edgeCap {
                let triple = [
                    Int(indices[triangle]),
                    Int(indices[triangle + 1]),
                    Int(indices[triangle + 2])
                ]
                triangle += 3
                for pair in [(0, 1), (1, 2), (2, 0)] {
                    let first = triple[pair.0]
                    let second = triple[pair.1]
                    guard first < positions.count, second < positions.count else { continue }
                    let low = UInt64(min(first, second))
                    let high = UInt64(max(first, second))
                    let key = low << 32 | high
                    guard seen.insert(key).inserted else { continue }
                    geometry.segments.append(FFSnapSegment(positions[first], positions[second]))
                    edgeCount += 1
                    if edgeCount >= edgeCap { break }
                }
            }
        }
        return geometry
    }
}

struct FFSnapCandidate: Equatable, Sendable {
    var kind: FFSnapKind
    var position: Vec3
    var screen: Vec2
    var distance: Double
}

struct FFSnapMarker: Equatable, Sendable, Identifiable {
    var kind: FFSnapKind
    var screen: Vec2
    var label: String
    var isBest: Bool

    var id: String {
        "\(kind.rawValue)-\(Int(screen.x.rounded()))-\(Int(screen.y.rounded()))"
    }
}

struct FFSnapResult: Equatable, Sendable {
    var best: FFSnapCandidate
    var markers: [FFSnapMarker]
}

/// Screen-space snapping with 3-D truth. Every candidate is a real world point
/// projected through the live camera, so the marker the user sees is the point
/// the next command will use.
enum FFSnapResolver {
    static let defaultTolerance: Double = 8

    /// How far off a sketch plane a candidate may sit and still be accepted as
    /// one of its vertices. Mesh vertices on the plane are already exact to
    /// arithmetic noise, so this only has to exclude points that are genuinely
    /// somewhere else.
    static let planeTolerance: Double = 1e-6

    /// `on` restricts every candidate to points that lie in that plane. A planar
    /// sketch cannot hold a vertex that is not in its plane: flattening one into
    /// the plane's coordinates would store a point different from the marker the
    /// user aimed at. The default accepts every candidate, so the hover markers
    /// and the measuring tool keep their unwindowed vocabulary.
    static func resolve(
        hover: Vec2,
        reference: Vec3?,
        geometry: FFSnapGeometry,
        camera: FFCamera,
        viewport: Vec2,
        tolerance: Double = defaultTolerance,
        on plane: FFPlane3D? = nil
    ) -> FFSnapResult? {
        guard viewport.x > FFMath.eps, viewport.y > FFMath.eps,
              hover.x.isFinite, hover.y.isFinite, tolerance > 0
        else { return nil }

        var byKind: [FFSnapKind: FFSnapCandidate] = [:]

        func add(_ kind: FFSnapKind, _ position: Vec3) {
            guard let screen = camera.screenPoint(for: position, viewport: viewport),
                  screen.x.isFinite, screen.y.isFinite
            else { return }
            if let plane, abs(plane.signedDistance(of: position)) > Self.planeTolerance {
                return
            }
            let distance = (hover - screen).length
            guard distance <= tolerance else { return }
            if let current = byKind[kind], current.distance <= distance { return }
            byKind[kind] = FFSnapCandidate(
                kind: kind,
                position: position,
                screen: screen,
                distance: distance
            )
        }

        for point in geometry.points {
            add(point.kind, point.position)
        }

        for circle in geometry.circles {
            add(.centre, circle.centre)
        }

        var nearbySegments: [(segment: FFSnapSegment, index: Int)] = []
        for (index, segment) in geometry.segments.enumerated() {
            add(.endpoint, segment.a)
            add(.endpoint, segment.b)
            add(.midpoint, (segment.a + segment.b) * 0.5)

            guard let a = camera.screenPoint(for: segment.a, viewport: viewport),
                  let b = camera.screenPoint(for: segment.b, viewport: viewport)
            else { continue }
            let edge = b - a
            let lengthSquared = edge.lengthSquared
            var t = 0.0
            if lengthSquared > FFMath.eps {
                t = FFMath.clamp((hover - a).dot(edge) / lengthSquared, to: 0...1)
            }
            let closest = a + edge * t
            if (hover - closest).length <= tolerance * 2.5 {
                nearbySegments.append((segment, index))
            }
            if (hover - closest).length <= tolerance,
               let point = worldPointUnderCursor(
                   on: segment,
                   hover: hover,
                   camera: camera,
                   viewport: viewport
               ) {
                add(.onCurve, point)
            }

            if let reference {
                let direction = segment.b - segment.a
                let denominator = direction.lengthSquared
                if denominator > FFMath.eps {
                    let foot = FFMath.clamp(
                        (reference - segment.a).dot(direction) / denominator,
                        to: 0...1
                    )
                    add(.perpendicular, segment.a + direction * foot)
                }
            }
        }

        // Intersections are only meaningful for segments that are already under
        // the cursor; this keeps the pairwise solve small instead of quadratic
        // over a dense mesh.
        let intersectionPool = nearbySegments.prefix(24)
        for first in intersectionPool {
            for second in intersectionPool where second.index != first.index {
                guard let (p, q) = closestPoints(
                    first.segment.a, first.segment.b,
                    second.segment.a, second.segment.b
                ), (p - q).length <= FFTolerance.snapping else { continue }
                add(.intersection, (p + q) * 0.5)
            }
        }

        if let reference {
            for circle in geometry.circles {
                guard let plane = Plane(normal: circle.normal, point: circle.centre) else { continue }
                let projected = plane.project(reference)
                let outward = projected - circle.centre
                let distance = outward.length
                guard distance > circle.radius + FFMath.eps,
                      let unit = outward.normalized(),
                      let inPlane = circle.normal.cross(unit).normalized()
                else { continue }
                let base = circle.centre + unit * (circle.radius * circle.radius / distance)
                let height = circle.radius
                    * (max(0, distance * distance - circle.radius * circle.radius)).squareRoot()
                    / distance
                add(.tangent, base + inPlane * height)
                add(.tangent, base - inPlane * height)
            }
        }

        if let ray = camera.ray(at: hover, viewport: viewport),
           let plane = Plane(normal: .unitY, offset: geometry.gridPlaneY),
           let distance = ray.intersection(with: plane) {
            let hit = ray.point(at: distance)
            let step = geometry.gridStep
            if step > FFMath.eps {
                let snapped = Vec3(
                    x: (hit.x / step).rounded() * step,
                    y: geometry.gridPlaneY,
                    z: (hit.z / step).rounded() * step
                )
                add(.grid, snapped)
            }
        }

        if let reference,
           let referenceScreen = camera.screenPoint(for: reference, viewport: viewport) {
            let direction = hover - referenceScreen
            let radius = direction.length
            if radius > FFMath.eps {
                let increment = Double.pi / 12
                let angle = atan2(direction.y, direction.x)
                let snappedAngle = (angle / increment).rounded() * increment
                let target = referenceScreen + Vec2(
                    x: cos(snappedAngle) * radius,
                    y: sin(snappedAngle) * radius
                )
                if let ray = camera.ray(at: target, viewport: viewport),
                   let plane = Plane(normal: camera.basis.forward, point: reference),
                   let distance = ray.intersection(with: plane) {
                    add(.angle, ray.point(at: distance))
                }
            }
        }

        let candidates = Array(byKind.values)
        guard let best = select(from: candidates) else { return nil }

        let markers = candidates
            .sorted { lhs, rhs in
                if lhs.kind.priority != rhs.kind.priority {
                    return lhs.kind.priority < rhs.kind.priority
                }
                return lhs.distance < rhs.distance
            }
            .map { candidate in
                FFSnapMarker(
                    kind: candidate.kind,
                    screen: candidate.screen,
                    label: candidate.kind.label,
                    isBest: candidate.kind == best.kind
                )
            }
        return FFSnapResult(best: best, markers: markers)
    }

    /// Real geometry first, nearest point wins; kind priority only breaks a
    /// sub-pixel tie. Projection aids answer only when no geometry is under the
    /// cursor, angle before grid, so a snapped grid point can never outbid the
    /// intersection the jeweller actually aimed at.
    private static func select(from candidates: [FFSnapCandidate]) -> FFSnapCandidate? {
        let geometry = candidates.filter { !$0.kind.isProjectionAid }
        if let best = nearest(geometry) { return best }
        if let angle = candidates.first(where: { $0.kind == .angle }) { return angle }
        return nearest(candidates.filter { $0.kind == .grid })
    }

    private static func nearest(_ candidates: [FFSnapCandidate]) -> FFSnapCandidate? {
        guard let closest = candidates.map(\.distance).min() else { return nil }
        let finalists = candidates.filter { $0.distance <= closest + 0.6 }
        return finalists.min { lhs, rhs in
            if lhs.kind.priority != rhs.kind.priority {
                return lhs.kind.priority < rhs.kind.priority
            }
            return lhs.distance < rhs.distance
        }
    }

    /// The point of a world segment that lies under the cursor: the closest
    /// approach between the pick ray and the segment. Lerping in screen space
    /// drifts under perspective, so the solve happens in 3-D.
    private static func worldPointUnderCursor(
        on segment: FFSnapSegment,
        hover: Vec2,
        camera: FFCamera,
        viewport: Vec2
    ) -> Vec3? {
        guard let ray = camera.ray(at: hover, viewport: viewport),
              let direction = ray.direction.normalized()
        else { return nil }
        let span = segment.b - segment.a
        let lengthSquared = span.lengthSquared
        guard lengthSquared > FFMath.eps else { return segment.a }

        let offset = ray.origin - segment.a
        let alongRay = direction.dot(offset)
        let alongSpan = span.dot(offset)
        let cross = direction.dot(span)
        let denominator = lengthSquared - cross * cross
        var t = 0.0
        if abs(denominator) > FFMath.eps {
            t = (alongSpan - alongRay * cross) / denominator
        }
        return segment.a + span * FFMath.clamp(t, to: 0...1)
    }

    /// Closest points between two finite segments; `nil` for a degenerate one.
    private static func closestPoints(
        _ a0: Vec3, _ a1: Vec3,
        _ b0: Vec3, _ b1: Vec3
    ) -> (Vec3, Vec3)? {
        let u = a1 - a0
        let v = b1 - b0
        let w = a0 - b0
        let a = u.dot(u)
        let e = v.dot(v)
        guard a > FFMath.eps, e > FFMath.eps else { return nil }
        let b = u.dot(v)
        let c = u.dot(w)
        let f = v.dot(w)
        let denominator = a * e - b * b

        var s: Double
        if denominator > FFMath.eps {
            s = FFMath.clamp((b * f - c * e) / denominator, to: 0...1)
        } else {
            s = 0
        }
        var t = (b * s + f) / e
        if t < 0 {
            t = 0
            s = FFMath.clamp(-c / a, to: 0...1)
        } else if t > 1 {
            t = 1
            s = FFMath.clamp((b - c) / a, to: 0...1)
        }
        return (a0 + u * s, b0 + v * t)
    }
}

/// The one entry point the viewport uses for a hover sample, so the timing test
/// measures the production path including feature extraction.
enum FFSnapHover {
    static func markers(
        hover: Vec2,
        scene: FFViewportScene,
        selectedID: UUID?,
        reference: Vec3?,
        camera: FFCamera,
        viewport: Vec2,
        tolerance: Double = FFSnapResolver.defaultTolerance
    ) -> [FFSnapMarker] {
        let geometry = FFSnapGeometry.features(of: scene, selectedID: selectedID)
        return FFSnapResolver.resolve(
            hover: hover,
            reference: reference,
            geometry: geometry,
            camera: camera,
            viewport: viewport,
            tolerance: tolerance
        )?.markers ?? []
    }
}
