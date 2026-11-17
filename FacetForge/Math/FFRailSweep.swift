import Foundation

/// How the section is oriented as it travels along the rail.
///
/// `follow` keeps the section perpendicular to the rail: the frame is the
/// minimal rotation from the profile plane's +Z to the rail's tangent, which is
/// stable for the planar rails this phase accepts. `fixed` keeps the section in
/// its drawn orientation and only translates it, so a rail that climbs produces
/// an oblique body rather than a turning one.
enum FFRailOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case follow
    case fixed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .follow: "Follow"
        case .fixed: "Fixed"
        }
    }
}

/// Whether a closed section closes the two ends of the sweep.
///
/// An open profile has no end to cap, so this choice only applies to a closed
/// profile. A rail has ends because this phase refuses a closed rail.
enum FFRailCaps: String, Codable, CaseIterable, Identifiable, Sendable {
    case capped
    case open

    var id: String { rawValue }

    var label: String {
        switch self {
        case .capped: "Capped"
        case .open: "Open"
        }
    }
}

/// Everything a committed rail sweep is defined by.
///
/// The value is written into the document beside the body it produced, so the
/// mesh a later phase regenerates can only come from these numbers. Twist is a
/// total rotation between the two ends and scale is the section's scale at the
/// far end; the near end is always 1.
struct FFRailSweepParameters: Codable, Equatable, Sendable {
    static let defaultTwistDegrees = 0.0
    static let maximumTwistDegrees = 360.0
    static let defaultEndScale = 1.0
    static let minimumEndScale = 0.01
    static let maximumEndScale = 10.0

    var twistDegrees: Double
    var endScale: Double
    var orientation: FFRailOrientation
    var caps: FFRailCaps

    init(
        twistDegrees: Double = FFRailSweepParameters.defaultTwistDegrees,
        endScale: Double = FFRailSweepParameters.defaultEndScale,
        orientation: FFRailOrientation = .follow,
        caps: FFRailCaps = .capped
    ) {
        self.twistDegrees = twistDegrees
        self.endScale = endScale
        self.orientation = orientation
        self.caps = caps
    }

    var isTwisted: Bool { abs(twistDegrees) > 1e-9 }

    var isScaled: Bool { abs(endScale - 1) > 1e-9 }

    var isValid: Bool {
        twistDegrees.isFinite
            && abs(twistDegrees) <= Self.maximumTwistDegrees + 1e-9
            && endScale.isFinite
            && endScale >= Self.minimumEndScale - 1e-9
            && endScale <= Self.maximumEndScale + 1e-9
    }

    /// The sentence a chip shows beside the rail. Every part is named only when
    /// it carries a value, so an untwisted, unscaled sweep reads short.
    var detail: String? {
        var parts: [String] = []
        if isTwisted {
            parts.append("twist \(FFPrecision.angleString(degrees: twistDegrees))")
        }
        if isScaled {
            parts.append(String(format: "scale x%.2f", endScale))
        }
        if orientation == .fixed { parts.append("fixed") }
        if caps == .open { parts.append("open") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Why a rail sweep could not be built.
///
/// Each case carries a sentence, the rule Phases 44-58 follow: a refusal says
/// what about the input made the body impossible instead of committing a guess.
enum FFRailSweepError: Error, Equatable, LocalizedError {
    case emptyRail
    case railIsClosed
    case railSelfIntersects
    case twistOutOfRange(Double)
    case scaleOutOfRange(Double)
    case degenerateProfile
    case profileNotSimple
    case couldNotBuildMesh

    var errorDescription: String? {
        switch self {
        case .emptyRail:
            return "A rail needs at least two distinct points and a length"
        case .railIsClosed:
            return "A rail must be open; a closed rail has no ends to cap"
        case .railSelfIntersects:
            return "That rail crosses or doubles back on itself, so the sweep would overlap"
        case .twistOutOfRange(let degrees):
            return "A twist of \(FFPrecision.angleString(degrees: degrees)) is outside ±\(FFPrecision.angleString(degrees: FFRailSweepParameters.maximumTwistDegrees))"
        case .scaleOutOfRange(let scale):
            return "A scale of \(String(format: "%.2f", scale)) is outside \(String(format: "%.2f", FFRailSweepParameters.minimumEndScale))-\(String(format: "%.2f", FFRailSweepParameters.maximumEndScale))"
        case .degenerateProfile:
            return "That profile has no area to sweep"
        case .profileNotSimple:
            return "That profile crosses itself, so its end caps have no inside"
        case .couldNotBuildMesh:
            return "The rail sweep produced no triangles"
        }
    }
}

/// A rail sampled into the polyline the sweep travels along.
///
/// The rail is planar and lives in the profile plane's own coordinates, because
/// that is the plane the profile was drawn on. Sampling happens once, with the
/// same rule the profile sampler uses: a straight span contributes its start and
/// a curved span eight samples, so a 50 mm line is two points rather than a
/// hundred. The path is refused when it crosses itself, touches itself at a
/// non-adjacent vertex, or doubles back, because every one of those makes the
/// swept body overlap itself.
struct FFRailPath: Equatable, Sendable {
    let points: [Vec2]
    let length: Double

    static let samplesPerSpan = FFSurfaceSweepProfile.samplesPerSpan

    init(payload: FFCurvePayload, samplesPerSpan: Int = FFRailPath.samplesPerSpan) throws {
        guard !payload.segments.isEmpty else { throw FFRailSweepError.emptyRail }
        guard !payload.isClosed else { throw FFRailSweepError.railIsClosed }
        var raw: [Vec2] = []
        raw.reserveCapacity(payload.segments.count * 2)
        for segment in payload.segments {
            guard let curve = segment.curve else { throw FFRailSweepError.emptyRail }
            let isStraight = segment.kind == .bezier && segment.controlPoints.count == 2
            let steps = isStraight ? 1 : max(2, samplesPerSpan)
            for step in 0..<steps {
                let point = curve.point(at: Double(step) / Double(steps))
                guard point.x.isFinite, point.y.isFinite else {
                    throw FFRailSweepError.emptyRail
                }
                raw.append(point)
            }
        }
        guard let last = payload.segments.last?.curve else {
            throw FFRailSweepError.emptyRail
        }
        let end = last.point(at: 1)
        guard end.x.isFinite, end.y.isFinite else { throw FFRailSweepError.emptyRail }
        raw.append(end)
        try self.init(points: raw)
    }

    init(points: [Vec2]) throws {
        var ordered: [Vec2] = []
        ordered.reserveCapacity(points.count)
        for point in points {
            guard point.x.isFinite, point.y.isFinite else {
                throw FFRailSweepError.emptyRail
            }
            if let last = ordered.last,
               last.distance(to: point) <= FFTolerance.curveJoin {
                continue
            }
            ordered.append(point)
        }
        guard ordered.count >= 2 else { throw FFRailSweepError.emptyRail }

        var total = 0.0
        for index in 0..<(ordered.count - 1) {
            total += ordered[index].distance(to: ordered[index + 1])
        }
        guard total > FFMath.eps else { throw FFRailSweepError.emptyRail }
        guard !Self.selfIntersects(ordered) else {
            throw FFRailSweepError.railSelfIntersects
        }
        guard !Self.doublesBack(ordered) else {
            throw FFRailSweepError.railSelfIntersects
        }

        self.points = ordered
        self.length = total
    }

    /// Proper crossings between non-adjacent segments, plus a non-adjacent
    /// vertex lying on a segment. Adjacent segments share an end by
    /// construction, so they are the one pair that is not a self-intersection.
    static func selfIntersects(_ points: [Vec2]) -> Bool {
        let count = points.count
        guard count >= 4 else { return false }
        for first in 0..<(count - 1) {
            for second in (first + 1)..<(count - 1) {
                if second == first + 1 { continue }
                if properCrossing(
                    points[first], points[first + 1],
                    points[second], points[second + 1]
                ) {
                    return true
                }
            }
        }
        for segment in 0..<(count - 1) {
            for vertex in 0..<count {
                if vertex == segment || vertex == segment + 1 { continue }
                if pointOnSegment(points[vertex], points[segment], points[segment + 1]) {
                    return true
                }
            }
        }
        return false
    }

    /// A joint whose two directions are opposite folds the rail back over the
    /// segment it just travelled, so the swept sections coincide.
    private static func doublesBack(_ points: [Vec2]) -> Bool {
        guard points.count >= 3 else { return false }
        for index in 1..<(points.count - 1) {
            let incoming = points[index] - points[index - 1]
            let outgoing = points[index + 1] - points[index]
            let incomingLength = incoming.length
            let outgoingLength = outgoing.length
            guard incomingLength > FFMath.eps, outgoingLength > FFMath.eps else {
                continue
            }
            if incoming.dot(outgoing) / (incomingLength * outgoingLength) < -1 + 1e-9 {
                return true
            }
        }
        return false
    }

    private static func cross(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func properCrossing(
        _ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2
    ) -> Bool {
        let first = cross(a, b, c)
        let second = cross(a, b, d)
        let third = cross(c, d, a)
        let fourth = cross(c, d, b)
        let epsilon = 1e-12
        let straddlesFirst = (first > epsilon && second < -epsilon)
            || (first < -epsilon && second > epsilon)
        let straddlesSecond = (third > epsilon && fourth < -epsilon)
            || (third < -epsilon && fourth > epsilon)
        return straddlesFirst && straddlesSecond
    }

    private static func pointOnSegment(_ point: Vec2, _ a: Vec2, _ b: Vec2) -> Bool {
        guard abs(cross(a, b, point)) <= 1e-9 else { return false }
        let epsilon = 1e-9
        return point.x >= min(a.x, b.x) - epsilon
            && point.x <= max(a.x, b.x) + epsilon
            && point.y >= min(a.y, b.y) - epsilon
            && point.y <= max(a.y, b.y) + epsilon
    }
}

/// One rail sweep, ready to become a document node.
///
/// The value is pure geometry: the same profile, rail and parameters produce the
/// same mesh, and building it never touches a document. The section's centroid
/// rides the rail, which is what makes a profile drawn away from the origin
/// sweep without a hidden offset; scaling is about that centroid, and twist is
/// about the section normal (the rail tangent in `follow`, +Z in `fixed`).
///
/// The winding is normalised from the mesh's own signed volume at the end, so a
/// rail that runs in the opposite direction, or a fixed section that faces away
/// from the rail's travel, still produces an outward body rather than an
/// inside-out one.
struct FFRailSweep: Equatable, Sendable {
    let profile: FFSurfaceSweepProfile
    let rail: FFRailPath
    let parameters: FFRailSweepParameters

    init(
        profile: FFSurfaceSweepProfile,
        rail: FFRailPath,
        parameters: FFRailSweepParameters
    ) {
        self.profile = profile
        self.rail = rail
        self.parameters = parameters
    }

    var estimatedTriangles: Int {
        let count = profile.points.count
        let edges = profile.isClosed ? count : max(0, count - 1)
        let sides = max(0, rail.points.count - 1) * edges * 2
        let caps = profile.isClosed && parameters.caps == .capped
            ? max(0, count - 2) * 2
            : 0
        return sides + caps
    }

    func mesh() throws -> IndexedMesh {
        guard parameters.twistDegrees.isFinite,
              abs(parameters.twistDegrees) <= FFRailSweepParameters.maximumTwistDegrees + 1e-9
        else {
            throw FFRailSweepError.twistOutOfRange(
                parameters.twistDegrees.isFinite ? parameters.twistDegrees : 0
            )
        }
        guard parameters.endScale.isFinite,
              parameters.endScale >= FFRailSweepParameters.minimumEndScale - 1e-9,
              parameters.endScale <= FFRailSweepParameters.maximumEndScale + 1e-9
        else {
            throw FFRailSweepError.scaleOutOfRange(
                parameters.endScale.isFinite ? parameters.endScale : 0
            )
        }
        guard !profile.points.isEmpty else { throw FFRailSweepError.degenerateProfile }
        guard rail.points.count >= 2, rail.length > FFMath.eps else {
            throw FFRailSweepError.emptyRail
        }

        let count = profile.points.count
        let edges = profile.isClosed ? count : count - 1
        let centroid = profile.centroid
        let twist = FFMath.radians(parameters.twistDegrees)
        let total = rail.length

        var travelled: [Double] = [0]
        travelled.reserveCapacity(rail.points.count)
        for index in 0..<(rail.points.count - 1) {
            travelled.append(travelled[index] + rail.points[index].distance(to: rail.points[index + 1]))
        }

        var positions: [Vec3] = []
        positions.reserveCapacity(rail.points.count * count)
        for (index, station) in rail.points.enumerated() {
            let t = total > 0 ? min(1, travelled[index] / total) : 0
            let tangent = self.tangent(at: index)
            let axes = frame(tangent: tangent, twist: twist * t)
            let scale = 1 + (parameters.endScale - 1) * t
            let origin = Vec3(x: station.x, y: station.y, z: 0)
            for point in profile.points {
                let local = (point - centroid) * scale
                positions.append(origin + axes.x * local.x + axes.y * local.y)
            }
        }

        var triangles: [MeshTriangle] = []
        triangles.reserveCapacity(estimatedTriangles)
        for ring in 0..<(rail.points.count - 1) {
            for index in 0..<edges {
                let next = (index + 1) % count
                let a = ring * count + index
                let b = ring * count + next
                let c = (ring + 1) * count + next
                let d = (ring + 1) * count + index
                triangles.append(MeshTriangle(a, b, c))
                triangles.append(MeshTriangle(a, c, d))
            }
        }

        if profile.isClosed, parameters.caps == .capped, count >= 3 {
            let caps: [(Int, Int, Int)]
            do {
                caps = try FFPolygonTriangulator.triangulate(profile.points)
            } catch {
                throw FFRailSweepError.profileNotSimple
            }
            let last = (rail.points.count - 1) * count
            for cap in caps {
                // The start cap faces back down the rail, so its winding is the
                // reverse of the profile's own; the end cap keeps it.
                triangles.append(MeshTriangle(cap.2, cap.1, cap.0))
                triangles.append(MeshTriangle(cap.0 + last, cap.1 + last, cap.2 + last))
            }
        }

        guard let built = IndexedMesh(positions: positions, triangles: triangles) else {
            throw FFRailSweepError.couldNotBuildMesh
        }
        guard built.signedVolume() < 0 else { return built }
        let flipped = triangles.map { MeshTriangle($0.c, $0.b, $0.a) }
        guard let outward = IndexedMesh(positions: positions, triangles: flipped) else {
            throw FFRailSweepError.couldNotBuildMesh
        }
        return outward
    }

    // MARK: - Frames

    /// The rail's direction at a station: one-sided at the ends and central in
    /// the interior, so a curved rail turns smoothly rather than stepping at
    /// each sample.
    private func tangent(at index: Int) -> Vec3 {
        let last = rail.points.count - 1
        let direction: Vec2
        if index == 0 {
            direction = rail.points[1] - rail.points[0]
        } else if index == last {
            direction = rail.points[last] - rail.points[last - 1]
        } else {
            direction = rail.points[index + 1] - rail.points[index - 1]
        }
        return Vec3(x: direction.x, y: direction.y, z: 0).normalized() ?? .unitZ
    }

    private func frame(tangent: Vec3, twist: Double) -> (x: Vec3, y: Vec3) {
        var xAxis: Vec3
        var yAxis: Vec3
        var normal: Vec3
        switch parameters.orientation {
        case .follow:
            normal = tangent
            let basis = Self.basis(from: .unitZ, to: tangent)
            xAxis = basis.x
            yAxis = basis.y
        case .fixed:
            normal = .unitZ
            xAxis = .unitX
            yAxis = .unitY
        }
        if abs(twist) > 1e-12 {
            xAxis = Self.rotated(xAxis, about: normal, by: twist)
            yAxis = Self.rotated(yAxis, about: normal, by: twist)
        }
        return (xAxis, yAxis)
    }

    /// The minimal rotation that takes +Z to `target`, applied to X and Y.
    ///
    /// The reversed case is a half turn about X, chosen rather than derived from
    /// a zero-length cross product, so a rail that points straight down still
    /// has a defined frame.
    private static func basis(from source: Vec3, to target: Vec3) -> (x: Vec3, y: Vec3) {
        let dot = max(-1, min(1, source.dot(target)))
        if dot > 1 - 1e-12 { return (.unitX, .unitY) }
        if dot < -1 + 1e-12 { return (.unitX, -.unitY) }
        guard let axis = source.cross(target).normalized() else {
            return (.unitX, .unitY)
        }
        let angle = acos(dot)
        return (
            rotated(.unitX, about: axis, by: angle),
            rotated(.unitY, about: axis, by: angle)
        )
    }

    /// Rodrigues' rotation. The axis is expected to be normalized.
    private static func rotated(_ vector: Vec3, about axis: Vec3, by angle: Double) -> Vec3 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return vector * cosine
            + axis.cross(vector) * sine
            + axis * (axis.dot(vector) * (1 - cosine))
    }
}
