import Foundation

/// Which way a committed extrusion leaves the profile's plane.
///
/// The profile stays an ordinary curve; the body is a separate solid node. A
/// forward extrusion builds along the profile node's local +Z, a reversed one
/// along its -Z, so the choice is visible as which side of the sketch the body
/// occupies rather than as a hidden flag.
enum FFExtrudeDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case reversed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: "Forward"
        case .reversed: "Reversed"
        }
    }
}

/// Whether a closed extrusion closes its ends.
///
/// An open profile has no end to cap, so this choice only applies to a closed
/// profile. The panel says so instead of showing an option that does nothing.
enum FFExtrudeCaps: String, Codable, CaseIterable, Identifiable, Sendable {
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

/// Everything a committed extrusion is defined by.
///
/// The value is written into the document beside the body it produced, so the
/// mesh a later phase regenerates can only come from these numbers. It carries
/// no reference to the profile node: the payload itself is stored, which keeps
/// the record stable when the source curve is renamed, moved or deleted.
struct FFExtrusionParameters: Codable, Equatable, Sendable {
    static let maximumHeight = 400.0
    static let maximumDraftDegrees = 45.0
    static let defaultHeight = 6.0

    var height: Double
    /// Positive widens the section as it leaves the sketch plane, which is the
    /// direction a mould is drafted for release. Negative narrows it.
    var draftDegrees: Double
    var direction: FFExtrudeDirection
    /// Splits the height evenly either side of the profile plane. Direction is
    /// then moot, because the body already occupies both sides.
    var isSymmetric: Bool
    var caps: FFExtrudeCaps

    init(
        height: Double = FFExtrusionParameters.defaultHeight,
        draftDegrees: Double = 0,
        direction: FFExtrudeDirection = .normal,
        isSymmetric: Bool = false,
        caps: FFExtrudeCaps = .capped
    ) {
        self.height = height
        self.draftDegrees = draftDegrees
        self.direction = direction
        self.isSymmetric = isSymmetric
        self.caps = caps
    }

    var isDrafted: Bool { abs(draftDegrees) > 1e-9 }

    var draftTangent: Double { tan(FFMath.radians(draftDegrees)) }

    /// The two plane distances the body spans, low first.
    ///
    /// Both ends are expressed as ascending positions so the side winding and
    /// the cap winding can be written once: a reversed body starts at -height
    /// and ends at the profile plane, and a symmetric body straddles it.
    var zRange: (low: Double, high: Double) {
        if isSymmetric { return (-height / 2, height / 2) }
        switch direction {
        case .normal: return (0, height)
        case .reversed: return (-height, 0)
        }
    }

    /// How far the section has moved outward at a plane distance. Draft is
    /// measured per side, so this is the offset a wall travels, not a scale.
    func offset(atDistance distance: Double) -> Double {
        abs(distance) * draftTangent
    }

    var isValid: Bool {
        height.isFinite
            && height > FFMath.eps
            && height <= Self.maximumHeight
            && draftDegrees.isFinite
            && abs(draftDegrees) <= Self.maximumDraftDegrees
    }

    /// The sentence a chip shows beside the parameter. Draft is only named when
    /// it is carrying a value, so an undrafted body reads the same as it did
    /// before this phase.
    var detail: String? {
        guard isDrafted else { return nil }
        return "draft \(FFPrecision.angleString(degrees: draftDegrees))"
    }
}

/// Why a profile could not become a solid.
///
/// Each case carries a sentence, the rule Phases 44-56 follow: a refusal says
/// what about the input made the body impossible instead of committing a guess.
enum FFExtrudeError: Error, Equatable, LocalizedError {
    case nonPositiveHeight
    case heightOutOfRange(Double)
    case draftOutOfRange(Double)
    case draftNeedsClosedProfile
    case draftCollapsesProfile
    case draftTooSharp
    case degenerateProfile
    case couldNotBuildMesh

    var errorDescription: String? {
        switch self {
        case .nonPositiveHeight:
            return "A height must be greater than zero"
        case .heightOutOfRange(let millimetres):
            return "\(FFPrecision.lengthString(millimetres: millimetres, unit: .millimetres)) is taller than the \(FFPrecision.lengthString(millimetres: FFExtrusionParameters.maximumHeight, unit: .millimetres)) limit"
        case .draftOutOfRange(let degrees):
            return "A draft of \(FFPrecision.angleString(degrees: degrees)) is outside ±\(FFPrecision.angleString(degrees: FFExtrusionParameters.maximumDraftDegrees))"
        case .draftNeedsClosedProfile:
            return "Draft needs a closed profile; an open profile extrudes as a ribbon"
        case .draftCollapsesProfile:
            return "That draft closes the profile on itself before it reaches the end"
        case .draftTooSharp:
            return "That profile has a spike sharper than the draft can mitre"
        case .degenerateProfile:
            return "That profile has no area to extrude"
        case .couldNotBuildMesh:
            return "The extrusion produced no triangles"
        }
    }
}

/// One extrusion, ready to become a document node.
///
/// The value is pure geometry: the same profile and parameters produce the same
/// mesh, and building it never touches a document. Draft is a real mitre offset
/// of the section at each end rather than a scale about the centroid, because a
/// jeweller's draft is a constant wall angle: on a 40 mm long bar every wall
/// leans by the same distance per millimetre of height, whatever the bar's
/// aspect ratio, which a scale cannot produce.
///
/// The two rings are emitted low end first, so the side and cap winding is
/// written once for a forward, reversed or symmetric body and the signed volume
/// stays positive in all three.
struct FFExtrusion: Equatable, Sendable {
    let profile: FFSurfaceSweepProfile
    let parameters: FFExtrusionParameters

    /// The longest mitre a corner may grow to, as a multiple of the draft
    /// distance. A 10-degree wedge is about 11.5; beyond this the corner is a
    /// spike and the body is refused rather than drawn with a wing.
    static let miterLimit = 12.0

    init(profile: FFSurfaceSweepProfile, parameters: FFExtrusionParameters) {
        self.profile = profile
        self.parameters = parameters
    }

    /// The body's section at a distance from the profile plane, already offset
    /// by the draft. Distance 0 is the profile itself.
    func ring(atDistance distance: Double) throws -> [Vec2] {
        guard distance.isFinite else { throw FFExtrudeError.degenerateProfile }
        let offset = parameters.offset(atDistance: distance)
        guard abs(offset) > 1e-12 else { return profile.points }
        guard profile.isClosed else { throw FFExtrudeError.draftNeedsClosedProfile }
        return try Self.offsetRing(profile.points, by: offset)
    }

    func mesh() throws -> IndexedMesh {
        guard parameters.height.isFinite, parameters.height > FFMath.eps else {
            throw FFExtrudeError.nonPositiveHeight
        }
        guard parameters.height <= FFExtrusionParameters.maximumHeight else {
            throw FFExtrudeError.heightOutOfRange(parameters.height)
        }
        guard parameters.draftDegrees.isFinite,
              abs(parameters.draftDegrees) <= FFExtrusionParameters.maximumDraftDegrees
        else {
            throw FFExtrudeError.draftOutOfRange(
                parameters.draftDegrees.isFinite ? parameters.draftDegrees : 0
            )
        }
        guard !parameters.isDrafted || profile.isClosed else {
            throw FFExtrudeError.draftNeedsClosedProfile
        }
        guard !profile.points.isEmpty else { throw FFExtrudeError.degenerateProfile }

        let span = parameters.zRange
        let lowRing = try ring(atDistance: span.low)
        let highRing = try ring(atDistance: span.high)
        let count = profile.points.count
        guard lowRing.count == count, highRing.count == count else {
            throw FFExtrudeError.degenerateProfile
        }
        guard lowRing.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              highRing.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else {
            throw FFExtrudeError.degenerateProfile
        }

        // A drafted ring is a new polygon, and the ear clipper is the one
        // triangulation this codebase trusts. Running it on both rings is also
        // the cheapest proof that the offset did not fold the profile over
        // itself before the caps are even asked for.
        if parameters.isDrafted, profile.isClosed {
            _ = try FFPolygonTriangulator.triangulate(lowRing)
            _ = try FFPolygonTriangulator.triangulate(highRing)
        }

        var positions: [Vec3] = []
        positions.reserveCapacity(count * 2)
        for point in lowRing {
            positions.append(Vec3(x: point.x, y: point.y, z: span.low))
        }
        for point in highRing {
            positions.append(Vec3(x: point.x, y: point.y, z: span.high))
        }

        var triangles: [MeshTriangle] = []
        triangles.reserveCapacity(profile.isClosed ? count * 4 - 4 : count * 2)
        let edges = profile.isClosed ? count : count - 1
        for index in 0..<edges {
            let next = (index + 1) % count
            let lowA = index
            let lowB = next
            let highA = index + count
            let highB = next + count
            triangles.append(MeshTriangle(lowA, lowB, highB))
            triangles.append(MeshTriangle(lowA, highB, highA))
        }

        if profile.isClosed, parameters.caps == .capped {
            let highCaps = try FFPolygonTriangulator.triangulate(highRing)
            let lowCaps = parameters.isDrafted
                ? try FFPolygonTriangulator.triangulate(lowRing)
                : highCaps
            guard lowCaps.count == highCaps.count else {
                throw FFExtrudeError.draftCollapsesProfile
            }
            for index in highCaps.indices {
                let high = highCaps[index]
                let low = lowCaps[index]
                // The high cap keeps the profile's own counter-clockwise order,
                // so its normal is +Z; the low cap is the reverse. Flipping
                // either one leaves the mesh watertight but makes the signed
                // volume smaller by twice the cap's share, which is exactly the
                // mistake the prism volume test exists to catch.
                triangles.append(MeshTriangle(high.0 + count, high.1 + count, high.2 + count))
                triangles.append(MeshTriangle(low.2, low.1, low.0))
            }
        }

        guard let mesh = IndexedMesh(positions: positions, triangles: triangles) else {
            throw FFExtrudeError.couldNotBuildMesh
        }
        return mesh
    }

    /// A mitred outward offset of a counter-clockwise closed polygon.
    ///
    /// Each vertex moves to the intersection of its two offset edge lines, so a
    /// straight run keeps its length and a corner keeps its angle. The result is
    /// refused when the offset would invert the polygon's winding, which is what
    /// a draft larger than the profile's own half-width does.
    static func offsetRing(_ points: [Vec2], by distance: Double) throws -> [Vec2] {
        let count = points.count
        guard count >= 3 else { throw FFExtrudeError.degenerateProfile }
        guard distance.isFinite else { throw FFExtrudeError.degenerateProfile }

        var normals: [Vec2] = []
        normals.reserveCapacity(count)
        for index in 0..<count {
            let next = (index + 1) % count
            let edge = points[next] - points[index]
            let length = edge.length
            guard length > 1e-12 else { throw FFExtrudeError.degenerateProfile }
            // A counter-clockwise polygon's outside is to the right of travel.
            normals.append(Vec2(x: edge.y / length, y: -edge.x / length))
        }

        var result: [Vec2] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let incoming = normals[(index + count - 1) % count]
            let outgoing = normals[index]
            let denominator = 1 + incoming.dot(outgoing)
            guard denominator > 1e-6 else { throw FFExtrudeError.draftTooSharp }
            let miter = (incoming + outgoing) / denominator
            guard miter.length <= miterLimit else { throw FFExtrudeError.draftTooSharp }
            result.append(points[index] + miter * distance)
        }

        guard FFSurfaceSweepProfile.area(of: result) > FFMath.eps else {
            throw FFExtrudeError.draftCollapsesProfile
        }
        return result
    }
}
