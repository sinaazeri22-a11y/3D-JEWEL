import Foundation

/// Which way a revolution sweeps from the profile plane.
///
/// The axis is the profile plane's own vertical axis through its origin, which
/// is the axis Phase 54's live preview already revolved about. A forward
/// revolution sweeps toward the plane's +Z, a reversed one toward -Z, so the
/// choice is which side of the sketch the body occupies rather than a hidden
/// flag. A full turn has no side, so the card does not offer the choice there.
enum FFRevolveDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case forward
    case reversed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forward: "Forward"
        case .reversed: "Reversed"
        }
    }
}

/// Whether a partial revolution closes its two ends.
///
/// A full turn has no ends to cap, so this choice only applies to a partial
/// revolution of a closed profile. The panel says so instead of showing an
/// option that does nothing.
enum FFRevolveCaps: String, Codable, CaseIterable, Identifiable, Sendable {
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

/// Everything a committed revolution is defined by.
///
/// The value is written into the document beside the body it produced, so the
/// mesh a later phase regenerates can only come from these numbers. It carries
/// no reference to the profile node: the payload itself is stored, which keeps
/// the record stable when the source curve is renamed, moved or deleted.
struct FFRevolveParameters: Codable, Equatable, Sendable {
    /// The same floor Phase 54's preview clamps to, so the card and the builder
    /// cannot disagree about whether a sliver is a revolution.
    static let minimumAngleDegrees = 5.0
    static let maximumAngleDegrees = 360.0
    static let defaultAngleDegrees = 90.0

    /// Always positive; the direction carries which side the body occupies.
    var angleDegrees: Double
    var direction: FFRevolveDirection
    var caps: FFRevolveCaps

    init(
        angleDegrees: Double = FFRevolveParameters.defaultAngleDegrees,
        direction: FFRevolveDirection = .forward,
        caps: FFRevolveCaps = .capped
    ) {
        self.angleDegrees = angleDegrees
        self.direction = direction
        self.caps = caps
    }

    var isFullTurn: Bool {
        abs(angleDegrees - Self.maximumAngleDegrees) <= 1e-9
    }

    /// The angle the mesh is built with. A reversed revolution sweeps the same
    /// magnitude to the other side of the sketch plane.
    var signedAngleDegrees: Double {
        direction == .forward ? angleDegrees : -angleDegrees
    }

    var isValid: Bool {
        angleDegrees.isFinite
            && angleDegrees >= Self.minimumAngleDegrees - 1e-9
            && angleDegrees <= Self.maximumAngleDegrees + 1e-9
    }

    /// The sentence a chip shows beside the angle. A full turn has no ends, so
    /// neither direction nor caps are named there: they would describe a choice
    /// the body cannot have.
    var detail: String? {
        guard !isFullTurn else { return nil }
        var parts: [String] = []
        if direction == .reversed { parts.append("reversed") }
        if caps == .open { parts.append("open") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Why a profile could not be revolved.
///
/// Each case carries a sentence, the rule Phases 44-57 follow: a refusal says
/// what about the input made the body impossible instead of committing a guess.
enum FFRevolveError: Error, Equatable, LocalizedError {
    case nonPositiveAngle
    case angleOutOfRange(Double)
    case profileCrossesAxis
    case degenerateProfile
    case couldNotBuildMesh

    var errorDescription: String? {
        switch self {
        case .nonPositiveAngle:
            return "An angle must be greater than zero"
        case .angleOutOfRange(let degrees):
            return "A revolution of \(FFPrecision.angleString(degrees: degrees)) is outside \(FFPrecision.angleString(degrees: FFRevolveParameters.minimumAngleDegrees))-\(FFPrecision.angleString(degrees: FFRevolveParameters.maximumAngleDegrees))"
        case .profileCrossesAxis:
            return "That profile crosses the axis it would revolve about"
        case .degenerateProfile:
            return "That profile has no area to revolve"
        case .couldNotBuildMesh:
            return "The revolution produced no triangles"
        }
    }
}

/// One revolution, ready to become a document node.
///
/// The value is pure geometry: the same profile and parameters produce the same
/// mesh, and building it never touches a document. The profile is sampled once
/// by `FFSurfaceSweepProfile`, so a drag rebuilds triangles and not samples.
///
/// The rings are emitted from the profile plane first, and a reversed body is
/// built forward and then mirrored with every triangle's winding reversed, so
/// both directions share one side-and-cap loop and the signed volume stays
/// positive forward and reversed. A full turn welds its last ring to the first
/// by index, which is what makes the 360-degree body watertight.
struct FFRevolve: Equatable, Sendable {
    let profile: FFSurfaceSweepProfile
    let parameters: FFRevolveParameters
    /// Explicit angular resolution. Nil derives it from the angle exactly as
    /// the Phase 54 preview did, so a live ghost keeps the counts it had before
    /// this phase: a quarter turn is 12 rings, a full turn 48.
    let angularSegments: Int?

    static let fullTurnSegments = 48
    static let minimumSegments = 3
    /// A profile point this close to the axis sweeps to a point rather than a
    /// circle. The same tolerance Phase 54 used, so the refusal boundary is
    /// unchanged.
    static let onAxis = 1e-9

    init(
        profile: FFSurfaceSweepProfile,
        parameters: FFRevolveParameters,
        angularSegments: Int? = nil
    ) {
        self.profile = profile
        self.parameters = parameters
        self.angularSegments = angularSegments
    }

    /// The angular steps this revolution will use, before any geometry exists.
    var steps: Int {
        if let angularSegments { return max(Self.minimumSegments, angularSegments) }
        let sweep = abs(parameters.angleDegrees)
        let derived = Int((Double(Self.fullTurnSegments) * sweep / 360).rounded(.up))
        return max(Self.minimumSegments, derived)
    }

    /// The triangle count the mesh will have, without building it.
    var estimatedTriangles: Int {
        let edges = profile.isClosed ? profile.points.count : max(0, profile.points.count - 1)
        let sides = steps * edges * 2
        let caps = profile.isClosed
            && !parameters.isFullTurn
            && parameters.caps == .capped
            && profile.points.count >= 3
            ? max(0, profile.points.count - 2) * 2
            : 0
        return sides + caps
    }

    func mesh() throws -> IndexedMesh {
        guard parameters.angleDegrees.isFinite else {
            throw FFRevolveError.angleOutOfRange(0)
        }
        guard parameters.angleDegrees > FFMath.eps else {
            throw FFRevolveError.nonPositiveAngle
        }
        guard parameters.isValid else {
            throw FFRevolveError.angleOutOfRange(parameters.angleDegrees)
        }
        guard !profile.points.isEmpty else { throw FFRevolveError.degenerateProfile }
        for point in profile.points where point.x < -Self.onAxis {
            throw FFRevolveError.profileCrossesAxis
        }
        let radii = profile.points.map(\.x)
        guard radii.contains(where: { $0 > Self.onAxis }) else {
            throw FFRevolveError.degenerateProfile
        }

        let count = profile.points.count
        let stepCount = steps
        let full = parameters.isFullTurn
        let rings = full ? stepCount : stepCount + 1
        let angle = abs(parameters.angleDegrees) * Double.pi / 180

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
                // quad to draw, and drawing one would add degenerate faces.
                if abs(radii[index]) <= Self.onAxis,
                   abs(radii[next]) <= Self.onAxis {
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

        if profile.isClosed, !full, parameters.caps == .capped, count >= 3 {
            let caps = try FFPolygonTriangulator.triangulate(profile.points)
            let last = stepCount * count
            for cap in caps {
                // The start cap faces the sweep's other direction, so its
                // winding is the reverse of the profile's own; the end cap
                // keeps it. Flipping either leaves the body closed but inwards,
                // which is the mistake the volume tests exist to catch.
                triangles.append(MeshTriangle(cap.2, cap.1, cap.0))
                triangles.append(MeshTriangle(
                    cap.0 + last,
                    cap.1 + last,
                    cap.2 + last
                ))
            }
        }

        // One mirror and one winding flip, rather than a second side-and-cap
        // loop: a reversed revolution is the same body on the other side of
        // the sketch plane, so it must share every count with the forward one.
        if parameters.direction == .reversed {
            for index in positions.indices {
                let point = positions[index]
                positions[index] = Vec3(x: point.x, y: point.y, z: -point.z)
            }
            for index in triangles.indices {
                let triangle = triangles[index]
                triangles[index] = MeshTriangle(triangle.c, triangle.b, triangle.a)
            }
        }

        guard let mesh = IndexedMesh(positions: positions, triangles: triangles) else {
            throw FFRevolveError.couldNotBuildMesh
        }
        return mesh
    }
}
