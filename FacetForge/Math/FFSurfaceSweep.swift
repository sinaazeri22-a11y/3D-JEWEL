import Dispatch
import Foundation

/// How a profile becomes a surface.
///
/// Two modes, because those are the two the row names: an extrusion along the
/// profile plane's normal, and a revolution about the plane's vertical axis.
/// The preview never commits, so neither mode produces a document node; they
/// produce a mesh a viewport can draw beside the real geometry.
enum FFSweepMode: String, CaseIterable, Identifiable, Sendable {
    case extrude
    case revolve

    var id: String { rawValue }

    var label: String {
        switch self {
        case .extrude: "Extrude"
        case .revolve: "Revolve"
        }
    }

    /// The default parameter for this mode: a jeweller's 6 mm band, or a
    /// quarter turn, which is the arc a ring's shoulder is swept through.
    var defaultParameter: Double {
        switch self {
        case .extrude: 6
        case .revolve: 90
        }
    }

    var parameterUnit: String {
        switch self {
        case .extrude: "mm"
        case .revolve: "°"
        }
    }
}

/// Why a profile could not be swept.
///
/// Every case carries a sentence, the same rule Phases 44-53 follow: a preview
/// that refuses must say what about the input made it impossible rather than
/// drawing a guess.
enum FFSweepError: Error, Equatable, LocalizedError {
    case emptyProfile
    case profileNotClosed
    case degenerateProfile
    case profileCrossesAxis
    case profileNotSimple
    case nonPositiveParameter(String)
    case angleOutOfRange(Double)

    var errorDescription: String? {
        switch self {
        case .emptyProfile:
            return "Select a curve with at least one drawable span"
        case .profileNotClosed:
            return "A closed profile must end where it starts before it can be swept"
        case .degenerateProfile:
            return "That profile has no area to sweep"
        case .profileCrossesAxis:
            return "That profile crosses the axis it would revolve about"
        case .profileNotSimple:
            return "That profile crosses itself, so its end caps have no inside"
        case .nonPositiveParameter(let label):
            return "\(label) must be greater than zero"
        case .angleOutOfRange(let degrees):
            return "A revolution of \(degrees)° is outside 0-360 degrees"
        }
    }
}

/// A profile sampled into a list of points the sweeps can use.
///
/// Sampling happens once per preview, not once per drag: a straight span needs
/// only its start point, because the next span supplies the join, and a curved
/// span is sampled `samplesPerSpan` times. That is what keeps a 200-span profile
/// at 200 points and a revolve update at 9,600 vertices rather than exploding
/// with the sample count.
///
/// A closed profile is normalised to counter-clockwise order so the side winding
/// and the cap winding can be written once. An open profile keeps its path order
/// and is swept as a ribbon with no caps.
struct FFSurfaceSweepProfile: Equatable, Sendable {
    let points: [Vec2]
    let isClosed: Bool
    /// Signed area in the profile plane, positive for the normalised order.
    let signedArea: Double
    /// How long the one-time sampling took, in milliseconds.
    let sampleMilliseconds: Double

    static let samplesPerSpan = 8

    init(payload: FFCurvePayload, samplesPerSpan: Int = FFSurfaceSweepProfile.samplesPerSpan) throws {
        guard !payload.segments.isEmpty else { throw FFSweepError.emptyProfile }
        let started = DispatchTime.now().uptimeNanoseconds
        var raw: [Vec2] = []
        raw.reserveCapacity(payload.segments.count * 2)
        for segment in payload.segments {
            guard let curve = segment.curve else { throw FFSweepError.emptyProfile }
            let isStraight = segment.kind == .bezier && segment.controlPoints.count == 2
            let steps = isStraight ? 1 : max(2, samplesPerSpan)
            for step in 0..<steps {
                let parameter = Double(step) / Double(steps)
                let point = curve.point(at: parameter)
                guard point.x.isFinite, point.y.isFinite else {
                    throw FFSweepError.emptyProfile
                }
                raw.append(point)
            }
        }
        if !payload.isClosed {
            guard let last = payload.segments.last?.curve else {
                throw FFSweepError.emptyProfile
            }
            let end = last.point(at: 1)
            guard end.x.isFinite, end.y.isFinite else { throw FFSweepError.emptyProfile }
            raw.append(end)
        }

        // Joins are stored once. A span's start is the previous span's end, and a
        // closed payload's last sample is its first, so both are dropped here.
        var points: [Vec2] = []
        points.reserveCapacity(raw.count)
        for point in raw {
            if let last = points.last, last.distance(to: point) <= FFTolerance.curveJoin {
                continue
            }
            points.append(point)
        }
        if payload.isClosed, points.count > 1,
           let first = points.first, let last = points.last,
           first.distance(to: last) <= FFTolerance.curveJoin {
            points.removeLast()
        }

        if payload.isClosed {
            guard points.count >= 3 else { throw FFSweepError.degenerateProfile }
            var area = Self.area(of: points)
            if abs(area) <= FFMath.eps { throw FFSweepError.degenerateProfile }
            if area < 0 {
                points.reverse()
                area = -area
            }
            self.points = points
            self.isClosed = true
            self.signedArea = area
        } else {
            guard points.count >= 2 else { throw FFSweepError.degenerateProfile }
            self.points = points
            self.isClosed = false
            self.signedArea = Self.area(of: points)
        }
        self.sampleMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000
    }

    /// A profile built from explicit points, for tests and for a future tool that
    /// sweeps something that is not a stored payload.
    init(points: [Vec2], isClosed: Bool) throws {
        var ordered = points
        if isClosed {
            guard ordered.count >= 3 else { throw FFSweepError.degenerateProfile }
            if let first = ordered.first, let last = ordered.last,
               first.distance(to: last) <= FFTolerance.curveJoin {
                ordered.removeLast()
            }
            var area = Self.area(of: ordered)
            guard abs(area) > FFMath.eps else { throw FFSweepError.degenerateProfile }
            if area < 0 {
                ordered.reverse()
                area = -area
            }
            self.points = ordered
            self.isClosed = true
            self.signedArea = area
        } else {
            guard ordered.count >= 2 else { throw FFSweepError.degenerateProfile }
            self.points = ordered
            self.isClosed = false
            self.signedArea = Self.area(of: ordered)
        }
        self.sampleMilliseconds = 0
    }

    var centroid: Vec2 {
        guard !points.isEmpty else { return .zero }
        var sum = Vec2.zero
        for point in points { sum = sum + point }
        return sum / Double(points.count)
    }

    /// The smallest x coordinate, which decides whether a revolution is legal.
    var smallestRadius: Double {
        points.map(\.x).min() ?? 0
    }

    /// The shoelace area. For an open profile it is still a useful measure of how
    /// the path is wound, but nothing depends on its sign.
    static func area(of points: [Vec2]) -> Double {
        guard points.count >= 3 else { return 0 }
        var total = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            total += current.x * next.y - next.x * current.y
        }
        return total / 2
    }
}

/// One sweep, ready to build a mesh.
///
/// The value is pure: the same profile and parameters produce the same mesh, and
/// building it never touches a document. The session holds the sampled profile
/// across a drag, so a rebuild allocates the mesh and nothing else.
struct FFSurfaceSweep: Equatable, Sendable {
    let profile: FFSurfaceSweepProfile
    let mode: FFSweepMode
    let height: Double
    let angleDegrees: Double
    /// Explicit angular resolution. Nil derives it from the angle so a full turn
    /// is smooth and a quarter turn does not pay for segments it does not show.
    let angularSegments: Int?

    static let fullTurnSegments = 48
    static let onAxis: Double = 1e-9

    init(
        profile: FFSurfaceSweepProfile,
        mode: FFSweepMode,
        height: Double,
        angleDegrees: Double,
        angularSegments: Int? = nil
    ) {
        self.profile = profile
        self.mode = mode
        self.height = height
        self.angleDegrees = angleDegrees
        self.angularSegments = angularSegments
    }

    /// The angular steps this sweep will use, before any geometry exists. A view
    /// can show the number without building the mesh.
    var steps: Int {
        switch mode {
        case .extrude:
            return 1
        case .revolve:
            if let angularSegments { return max(3, angularSegments) }
            let sweep = abs(angleDegrees)
            let derived = Int((Double(Self.fullTurnSegments) * sweep / 360).rounded(.up))
            return max(3, derived)
        }
    }

    /// The triangle count the mesh will have, without building it.
    var estimatedTriangles: Int {
        let edges = profile.isClosed ? profile.points.count : profile.points.count - 1
        switch mode {
        case .extrude:
            let sides = edges * 2
            let caps = profile.isClosed ? max(0, profile.points.count - 2) * 2 : 0
            return sides + caps
        case .revolve:
            let sides = steps * edges * 2
            let capped = profile.isClosed && !isFullTurn
            let caps = capped ? max(0, profile.points.count - 2) * 2 : 0
            return sides + caps
        }
    }

    var isFullTurn: Bool {
        abs(abs(angleDegrees) - 360) <= 1e-9
    }

    func mesh() throws -> IndexedMesh {
        switch mode {
        case .extrude:
            return try extruded()
        case .revolve:
            return try revolved()
        }
    }

    // MARK: - Extrude

    private func extruded() throws -> IndexedMesh {
        guard height.isFinite, height > FFMath.eps else {
            throw FFSweepError.nonPositiveParameter("A height")
        }
        let points = profile.points
        let count = points.count
        var positions: [Vec3] = []
        positions.reserveCapacity(count * 2)
        for point in points {
            positions.append(Vec3(x: point.x, y: point.y, z: 0))
        }
        for point in points {
            positions.append(Vec3(x: point.x, y: point.y, z: height))
        }

        var triangles: [MeshTriangle] = []
        triangles.reserveCapacity(estimatedTriangles)
        let edges = profile.isClosed ? count : count - 1
        for index in 0..<edges {
            let next = (index + 1) % count
            let bottomA = index
            let bottomB = next
            let topA = index + count
            let topB = next + count
            triangles.append(MeshTriangle(bottomA, bottomB, topB))
            triangles.append(MeshTriangle(bottomA, topB, topA))
        }

        if profile.isClosed {
            let caps = try FFPolygonTriangulator.triangulate(points)
            for cap in caps {
                // The top cap keeps the profile's own counter-clockwise order,
                // so its normal is +Z; the bottom cap is the reverse. Flipping
                // either one leaves the mesh watertight but makes the signed
                // volume smaller by twice the cap's share, which is exactly the
                // mistake the prism volume test exists to catch.
                triangles.append(MeshTriangle(cap.0 + count, cap.1 + count, cap.2 + count))
                triangles.append(MeshTriangle(cap.2, cap.1, cap.0))
            }
        }
        guard let mesh = IndexedMesh(positions: positions, triangles: triangles) else {
            throw FFSweepError.degenerateProfile
        }
        return mesh
    }

    // MARK: - Revolve

    private func revolved() throws -> IndexedMesh {
        guard angleDegrees.isFinite, abs(angleDegrees) > FFMath.eps,
              abs(angleDegrees) <= 360 + 1e-9
        else {
            throw FFSweepError.angleOutOfRange(angleDegrees.isFinite ? angleDegrees : 0)
        }
        for point in profile.points where point.x < -FFSurfaceSweep.onAxis {
            throw FFSweepError.profileCrossesAxis
        }
        let radii = profile.points.map(\.x)
        guard radii.contains(where: { $0 > FFSurfaceSweep.onAxis }) else {
            throw FFSweepError.degenerateProfile
        }

        let stepCount = steps
        let full = isFullTurn
        let rings = full ? stepCount : stepCount + 1
        let angle = abs(angleDegrees) * Double.pi / 180
        let count = profile.points.count

        var positions: [Vec3] = []
        positions.reserveCapacity(rings * count)
        for ring in 0..<rings {
            let theta = angle * Double(ring) / Double(stepCount)
            let cosine = cos(theta)
            let sine = sin(theta)
            for point in profile.points {
                positions.append(Vec3(
                    x: point.x * cosine,
                    y: point.y,
                    z: point.x * sine
                ))
            }
        }

        var triangles: [MeshTriangle] = []
        triangles.reserveCapacity(estimatedTriangles)
        let edges = profile.isClosed ? count : count - 1
        for ring in 0..<stepCount {
            let nextRing = (ring + 1) % rings
            for index in 0..<edges {
                let next = (index + 1) % count
                // A span that touches the axis sweeps to a point: there is no
                // quad to draw, and drawing one would add degenerate triangles.
                if abs(radii[index]) <= FFSurfaceSweep.onAxis,
                   abs(radii[next]) <= FFSurfaceSweep.onAxis {
                    continue
                }
                let a = ring * count + index
                let b = ring * count + next
                let c = nextRing * count + next
                let d = nextRing * count + index
                triangles.append(MeshTriangle(a, b, c))
                triangles.append(MeshTriangle(a, c, d))
            }
        }

        if profile.isClosed, !full {
            let caps = try FFPolygonTriangulator.triangulate(profile.points)
            let last = stepCount * count
            for cap in caps {
                // The start cap faces the sweep's other direction, so its winding
                // is the reverse of the profile's own.
                triangles.append(MeshTriangle(cap.2, cap.1, cap.0))
                triangles.append(MeshTriangle(
                    cap.0 + last,
                    cap.1 + last,
                    cap.2 + last
                ))
            }
        }
        guard let mesh = IndexedMesh(positions: positions, triangles: triangles) else {
            throw FFSweepError.degenerateProfile
        }
        return mesh
    }
}

/// Ear clipping for a simple counter-clockwise polygon.
///
/// This exists for one purpose: a closed profile's end caps. A fan from the
/// centroid would be wrong for any concave section a jeweller actually draws,
/// and a cap is where a preview's watertightness is decided, so the clip is a
/// real triangulation rather than an approximation. A degenerate ear (three
/// collinear points) is clipped without emitting a triangle; a polygon that
/// cannot be reduced is refused instead of half-capped.
enum FFPolygonTriangulator {
    static func triangulate(_ points: [Vec2]) throws -> [(Int, Int, Int)] {
        guard points.count >= 3 else { return [] }
        var indices = Array(points.indices)
        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(points.count - 2)
        var guardCount = 0

        while indices.count > 3 {
            guardCount += 1
            guard guardCount <= points.count * 2 + 32 else {
                throw FFSweepError.profileNotSimple
            }
            var clipped = false
            let count = indices.count
            for position in 0..<count {
                let previous = indices[(position + count - 1) % count]
                let current = indices[position]
                let next = indices[(position + 1) % count]
                let a = points[previous]
                let b = points[current]
                let c = points[next]
                let turn = cross(a, b, c)
                if abs(turn) <= 1e-12 {
                    // Collinear: no triangle, but the vertex must go or the
                    // polygon never reduces.
                    indices.remove(at: position)
                    clipped = true
                    break
                }
                if turn < 0 { continue }
                var blocked = false
                for other in indices where other != previous && other != current && other != next {
                    if contains(points[other], a, b, c) {
                        blocked = true
                        break
                    }
                }
                if blocked { continue }
                triangles.append((previous, current, next))
                indices.remove(at: position)
                clipped = true
                break
            }
            if !clipped { throw FFSweepError.profileNotSimple }
        }
        if indices.count == 3 {
            triangles.append((indices[0], indices[1], indices[2]))
        }
        return triangles
    }

    private static func cross(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// Whether a point lies inside the triangle, edges included. Points exactly
    /// on an edge count as inside, which makes the clip refuse an ear that would
    /// swallow a collinear vertex.
    private static func contains(_ point: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let first = cross(a, b, point)
        let second = cross(b, c, point)
        let third = cross(c, a, point)
        return first >= -1e-12 && second >= -1e-12 && third >= -1e-12
    }
}

extension IndexedMesh {
    /// Every undirected edge and how many triangles use it. A closed body uses
    /// each exactly twice; a ribbon with a boundary uses some once.
    var edgeUseCounts: [UInt64: Int] {
        var counts: [UInt64: Int] = [:]
        for triangle in triangles {
            for pair in [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)] {
                let low = UInt64(min(pair.0, pair.1))
                let high = UInt64(max(pair.0, pair.1))
                let key = low << 32 | high
                counts[key, default: 0] += 1
            }
        }
        return counts
    }

    var isWatertight: Bool {
        !triangles.isEmpty && edgeUseCounts.values.allSatisfy { $0 == 2 }
    }
}
