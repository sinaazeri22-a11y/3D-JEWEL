import Foundation

/// How a loft travels between its sections.
///
/// `ruled` joins consecutive sections with straight sides, so a radius change is
/// an abrupt crease at every interior section — the shape a jeweller draws when
/// they want facets. `smooth` passes a cubic through the same sections, so the
/// surface is C1 in the loft direction and the interior sections are stations it
/// runs through rather than hinges.
enum FFLoftMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ruled
    case smooth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ruled: "Ruled"
        case .smooth: "Smooth"
        }
    }
}

/// Which way a smooth loft leaves its two end sections.
///
/// `natural` uses the chord to the neighbouring station, the same one-sided
/// tangent Catmull–Rom uses. `perpendicular` leaves each end along that end
/// section's own plane normal, which is what makes a blended band meet its end
/// rings square instead of leaning into the next station.
enum FFLoftEndTangency: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural
    case perpendicular

    var id: String { rawValue }

    var label: String {
        switch self {
        case .natural: "Natural"
        case .perpendicular: "Perpendicular"
        }
    }
}

/// Whether the two end sections of a closed loft are capped.
///
/// An open section has no inside to cap, so this choice only applies when every
/// section is closed.
enum FFLoftCaps: String, Codable, CaseIterable, Identifiable, Sendable {
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

/// Everything a committed loft is defined by.
///
/// The value is written into the document beside the body it produced, so the
/// mesh a later phase regenerates can only come from these numbers. `ringCount`
/// is the number of vertices every section is resampled to, which is what gives
/// the surface a vertex correspondence at all; `subdivisions` is how many steps
/// each band of a smooth loft takes, and is ignored by a ruled one.
struct FFLoftParameters: Codable, Equatable, Sendable {
    static let defaultRingCount = 64
    static let minimumRingCount = 8
    static let maximumRingCount = 512
    static let defaultSubdivisions = 8
    static let minimumSubdivisions = 1
    static let maximumSubdivisions = 64
    static let minimumSections = 3

    var mode: FFLoftMode
    var ringCount: Int
    var subdivisions: Int
    var caps: FFLoftCaps
    var endTangency: FFLoftEndTangency

    init(
        mode: FFLoftMode = .smooth,
        ringCount: Int = FFLoftParameters.defaultRingCount,
        subdivisions: Int = FFLoftParameters.defaultSubdivisions,
        caps: FFLoftCaps = .capped,
        endTangency: FFLoftEndTangency = .natural
    ) {
        self.mode = mode
        self.ringCount = ringCount
        self.subdivisions = subdivisions
        self.caps = caps
        self.endTangency = endTangency
    }

    var isRingCountValid: Bool {
        ringCount >= Self.minimumRingCount && ringCount <= Self.maximumRingCount
    }

    var isSubdivisionCountValid: Bool {
        subdivisions >= Self.minimumSubdivisions && subdivisions <= Self.maximumSubdivisions
    }

    /// The steps a smooth band actually takes. A ruled band is one straight span
    /// whatever the field says, so the field can never make a ruled body curve.
    var effectiveSubdivisions: Int {
        mode == .smooth ? subdivisions : 1
    }

    /// The sentence a chip shows beside the sections. Every part is named only
    /// when it is not the default, so the common loft reads short.
    var detail: String? {
        var parts: [String] = [mode.label]
        if mode == .smooth, subdivisions != Self.defaultSubdivisions {
            parts.append("\(subdivisions) steps")
        }
        if ringCount != Self.defaultRingCount {
            parts.append("\(ringCount) vertices")
        }
        if caps == .open { parts.append("open") }
        if mode == .smooth, endTangency == .perpendicular { parts.append("square ends") }
        return parts.joined(separator: " · ")
    }
}

/// Why a loft could not be built.
///
/// Each case carries a sentence, the rule Phases 44-59 follow: a refusal says
/// what about the input made the body impossible instead of committing a guess.
enum FFLoftError: Error, Equatable, LocalizedError {
    case notEnoughSections(Int)
    case mixedSectionStyles
    case emptySection(Int)
    case degenerateSection(Int)
    case coincidentSections(Int)
    case ringCountOutOfRange(Int)
    case subdivisionOutOfRange(Int)
    case sectionNotSimple(Int)
    case couldNotBuildMesh

    var errorDescription: String? {
        switch self {
        case .notEnoughSections(let count):
            return "A loft needs at least \(FFLoftParameters.minimumSections) sections; \(count) given"
        case .mixedSectionStyles:
            return "Every section of a loft must be closed, or every one open"
        case .emptySection(let index):
            return "Section \(index + 1) has no drawable span"
        case .degenerateSection(let index):
            return "Section \(index + 1) has no length, so it has no vertices to loft through"
        case .coincidentSections(let index):
            return "Sections \(index) and \(index + 1) sit on top of each other, so the loft has no height there"
        case .ringCountOutOfRange(let count):
            return "\(count) vertices is outside \(FFLoftParameters.minimumRingCount)-\(FFLoftParameters.maximumRingCount)"
        case .subdivisionOutOfRange(let count):
            return "\(count) steps is outside \(FFLoftParameters.minimumSubdivisions)-\(FFLoftParameters.maximumSubdivisions)"
        case .sectionNotSimple(let index):
            return "Section \(index + 1) crosses itself, so its cap has no inside"
        case .couldNotBuildMesh:
            return "The loft produced no triangles"
        }
    }
}

/// One section of a loft: a curve plus the plane it was drawn on.
///
/// The payload is copied into the record rather than referenced, so renaming,
/// moving or deleting the source curve cannot change what the loft means. The
/// plane is stored as three points because `Vec3` is not a file type.
struct FFLoftSection: Codable, Equatable, Sendable {
    var payload: FFCurvePayload
    var origin: FFPoint3
    var xAxis: FFPoint3
    var yAxis: FFPoint3

    init(payload: FFCurvePayload, origin: FFPoint3, xAxis: FFPoint3, yAxis: FFPoint3) {
        self.payload = payload
        self.origin = origin
        self.xAxis = xAxis
        self.yAxis = yAxis
    }

    init(payload: FFCurvePayload, plane: FFPlane3D) {
        self.init(
            payload: payload,
            origin: FFPoint3(plane.origin),
            xAxis: FFPoint3(plane.xAxis),
            yAxis: FFPoint3(plane.yAxis)
        )
    }

    /// The plane this section was drawn on, when its axes are unit length. A
    /// scaled node's axes are not unit, so the sampler uses `origin`, `xAxis`
    /// and `yAxis` directly rather than a normalised plane: a section drawn by a
    /// node scaled 2x is twice as large in world space, and losing that would
    /// silently resize a loft.
    var hasValidBasis: Bool {
        guard origin.vector.length.isFinite,
              xAxis.vector.length > FFMath.eps,
              yAxis.vector.length > FFMath.eps
        else { return false }
        return xAxis.vector.cross(yAxis.vector).length > FFMath.eps
    }

    var isClosed: Bool { payload.isClosed }
}

/// One section resampled into the vertices the loft runs through.
struct FFLoftRing: Equatable, Sendable {
    let points: [Vec3]
    let isClosed: Bool

    var count: Int { points.count }
}

/// Resamples a section's curve into an even ring of vertices.
///
/// Sampling happens once, when the body is built, from the curve itself rather
/// than from a polyline: every vertex is a point the curve really passes through
/// at a uniform arc length, so a loft through three circles has vertices exactly
/// on each circle rather than on a chord. Inversion is a linear step inside a
/// 33-entry arc-length table per span, which is accurate enough for the uniform
/// spacing and exact where it matters — the point is always evaluated on the
/// curve.
enum FFLoftSampler {
    /// Entries per span in the arc-length table. One more than a power of two
    /// keeps the bisection depth even and the table small enough to rebuild
    /// during a preview drag.
    static let tableSteps = 32

    static func ring(from section: FFLoftSection, count: Int) throws -> FFLoftRing {
        guard section.hasValidBasis else { throw FFLoftError.degenerateSection(0) }
        let curves = section.payload.segments.compactMap(\.curve)
        guard curves.count == section.payload.segments.count, !curves.isEmpty else {
            throw FFLoftError.emptySection(0)
        }

        let tables = curves.map { ArcTable(curve: $0, steps: tableSteps) }
        let total = tables.reduce(0) { $0 + $1.total }
        guard total > FFMath.eps else { throw FFLoftError.degenerateSection(0) }
        let origin = section.origin.vector
        let xAxis = section.xAxis.vector
        let yAxis = section.yAxis.vector

        let isClosed = section.payload.isClosed
        guard count >= 3 else { throw FFLoftError.ringCountOutOfRange(count) }

        var raw: [Vec2] = []
        raw.reserveCapacity(count)
        for index in 0..<count {
            let fraction = isClosed
                ? Double(index) / Double(count)
                : Double(index) / Double(count - 1)
            let point = try sample(
                atDistance: min(max(fraction, 0), 1) * total,
                tables: tables
            )
            raw.append(point)
        }

        if isClosed {
            guard raw.count >= 3, abs(FFSurfaceSweepProfile.area(of: raw)) > FFMath.eps else {
                throw FFLoftError.degenerateSection(0)
            }
            if FFSurfaceSweepProfile.area(of: raw) < 0 {
                raw.reverse()
            }
        }

        var points: [Vec3] = []
        points.reserveCapacity(raw.count)
        for point in raw {
            points.append(origin + xAxis * point.x + yAxis * point.y)
        }
        return FFLoftRing(points: points, isClosed: isClosed)
    }

    /// The point at a given distance along the whole payload, walked span by span.
    private static func sample(atDistance distance: Double, tables: [ArcTable]) throws -> Vec2 {
        var remaining = min(max(distance, 0), tables.reduce(0) { $0 + $1.total })
        for (index, table) in tables.enumerated() {
            let isLast = index == tables.count - 1
            if remaining <= table.total + 1e-12 || isLast {
                let local = min(max(remaining, 0), table.total)
                let t = table.parameter(atDistance: local)
                let point = table.curve.point(at: t)
                guard point.x.isFinite, point.y.isFinite else {
                    throw FFLoftError.degenerateSection(index)
                }
                return point
            }
            remaining -= table.total
        }
        throw FFLoftError.degenerateSection(0)
    }

    /// A span's cumulative arc length at 33 parameter values. Inverting a
    /// distance is a bisection over the table plus a linear step inside the
    /// bracket; the curve is then evaluated at that parameter, so the vertex
    /// lies on the curve and not on a chord between samples.
    private struct ArcTable {
        let curve: Curve2D
        let total: Double
        private let parameters: [Double]
        private let lengths: [Double]

        init(curve: Curve2D, steps: Int) {
            var parameters: [Double] = []
            var lengths: [Double] = []
            parameters.reserveCapacity(steps + 1)
            lengths.reserveCapacity(steps + 1)
            for index in 0...steps {
                let parameter = Double(index) / Double(steps)
                parameters.append(parameter)
                lengths.append(curve.arcLength(from: 0, to: parameter, tolerance: 1e-10))
            }
            self.curve = curve
            self.parameters = parameters
            self.lengths = lengths
            self.total = lengths[lengths.count - 1]
        }

        func parameter(atDistance distance: Double) -> Double {
            guard total > FFMath.eps else { return 0 }
            let target = min(max(distance, 0), total)
            var low = 0
            var high = lengths.count - 1
            while low < high {
                let middle = (low + high) / 2
                if lengths[middle] < target { low = middle + 1 } else { high = middle }
            }
            guard low > 0 else { return parameters[0] }
            let previous = lengths[low - 1]
            let next = lengths[low]
            guard next > previous + 1e-15 else { return parameters[low] }
            let fraction = (target - previous) / (next - previous)
            return parameters[low - 1] + (parameters[low] - parameters[low - 1]) * fraction
        }
    }
}

/// One multi-section loft, ready to become a document node.
///
/// The value is pure geometry: the same sections and parameters produce the same
/// mesh, and building it never touches a document. The rules the row names are
/// all enforced here rather than in a panel:
///
/// - a loft needs at least three sections, because two sections are an
///   extrusion with extra steps;
/// - every section has the same vertex count and the same closedness, because a
///   surface needs a vertex correspondence;
/// - consecutive sections may not coincide, because the band between them would
///   have no height;
/// - `ruled` joins sections with straight sides and `smooth` passes a cubic
///   through them, so only a smooth loft has continuous surface normals at an
///   interior section.
///
/// The winding is normalised from the mesh's own signed volume at the end, so
/// sections that run the other way round still produce an outward body rather
/// than an inside-out one. An open loft is a ribbon and has no volume to
/// normalise, so it keeps the winding its section order produced.
struct FFLoft: Equatable, Sendable {
    let rings: [FFLoftRing]
    let parameters: FFLoftParameters

    init(rings: [FFLoftRing], parameters: FFLoftParameters) throws {
        guard rings.count >= FFLoftParameters.minimumSections else {
            throw FFLoftError.notEnoughSections(rings.count)
        }
        guard parameters.isRingCountValid else {
            throw FFLoftError.ringCountOutOfRange(parameters.ringCount)
        }
        guard parameters.isSubdivisionCountValid else {
            throw FFLoftError.subdivisionOutOfRange(parameters.subdivisions)
        }
        let count = rings[0].count
        let isClosed = rings[0].isClosed
        guard count >= 3 else { throw FFLoftError.degenerateSection(0) }
        for (index, ring) in rings.enumerated() {
            guard ring.count == count, ring.isClosed == isClosed else {
                throw FFLoftError.mixedSectionStyles
            }
            guard ring.count >= 3 else { throw FFLoftError.degenerateSection(index) }
            for point in ring.points {
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                    throw FFLoftError.degenerateSection(index)
                }
            }
        }
        for index in 1..<rings.count {
            let previous = Self.centroid(rings[index - 1].points)
            let current = Self.centroid(rings[index].points)
            guard previous.distance(to: current) > 1e-6 else {
                throw FFLoftError.coincidentSections(index)
            }
        }
        self.rings = rings
        self.parameters = parameters
    }

    /// Builds the rings from sections, sampling every one to the parameters'
    /// vertex count. This is the one path the document and a preview share, so
    /// the ghost and the commit cannot disagree.
    init(sections: [FFLoftSection], parameters: FFLoftParameters) throws {
        guard sections.count >= FFLoftParameters.minimumSections else {
            throw FFLoftError.notEnoughSections(sections.count)
        }
        guard parameters.isRingCountValid else {
            throw FFLoftError.ringCountOutOfRange(parameters.ringCount)
        }
        guard parameters.isSubdivisionCountValid else {
            throw FFLoftError.subdivisionOutOfRange(parameters.subdivisions)
        }
        var rings: [FFLoftRing] = []
        rings.reserveCapacity(sections.count)
        for (index, section) in sections.enumerated() {
            do {
                rings.append(try FFLoftSampler.ring(from: section, count: parameters.ringCount))
            } catch let error as FFLoftError {
                throw Self.renumbered(error, as: index)
            }
        }
        try self.init(rings: rings, parameters: parameters)
    }

    /// Sampling reports section 0 because one section on its own has no index
    /// context; the loft is what knows which section failed.
    private static func renumbered(_ error: FFLoftError, as index: Int) -> FFLoftError {
        switch error {
        case .emptySection: return .emptySection(index)
        case .degenerateSection: return .degenerateSection(index)
        default: return error
        }
    }

    var stationCount: Int { rings.count }

    var vertexCount: Int { rings[0].count }

    var isClosed: Bool { rings[0].isClosed }

    /// The number of quad edges around one ring: the wrap-around edge of a
    /// closed section is the last vertex's edge, not an extra one.
    var edgeCount: Int { isClosed ? vertexCount : vertexCount - 1 }

    var crossSectionCount: Int {
        (stationCount - 1) * parameters.effectiveSubdivisions + 1
    }

    var estimatedTriangles: Int {
        let sides = (crossSectionCount - 1) * edgeCount * 2
        let caps = isClosed && parameters.caps == .capped
            ? max(0, vertexCount - 2) * 2
            : 0
        return sides + caps
    }

    // MARK: - Surface

    /// The point on the loft at `station`, where 0 is the first section and
    /// `stationCount - 1` is the last.
    func point(atStation station: Double, ringIndex index: Int) -> Vec3 {
        guard rings.count >= 2, rings[0].count > 0 else { return .zero }
        let last = Double(rings.count - 1)
        let clamped = min(max(station, 0), last)
        let band = announcedBand(for: clamped)
        let t = clamped - Double(band)
        let safeIndex = min(max(index, 0), rings[0].count - 1)
        let tangents = parameters.mode == .smooth ? stationTangents() : []
        return surfacePoint(band: band, index: safeIndex, t: t, tangents: tangents)
    }

    /// One vertex of one band at local parameter `t`, using tangents computed
    /// once by the caller.
    private func surfacePoint(band: Int, index: Int, t: Double, tangents: [[Vec3]]) -> Vec3 {
        switch parameters.mode {
        case .ruled:
            return rings[band].points[index].lerp(to: rings[band + 1].points[index], t: t)
        case .smooth:
            return Self.hermite(
                rings[band].points[index],
                rings[band + 1].points[index],
                tangents[band][index],
                tangents[band + 1][index],
                t
            )
        }
    }

    /// The whole ring at `station`, in the same vertex order every section uses.
    ///
    /// The station's tangents are computed once for the whole ring rather than
    /// once per vertex, which is what keeps a cap build and a normal probe
    /// linear in the vertex count instead of quadratic.
    func ring(atStation station: Double) -> [Vec3] {
        let tangents = parameters.mode == .smooth ? stationTangents() : []
        let last = Double(rings.count - 1)
        let clamped = min(max(station, 0), last)
        let band = announcedBand(for: clamped)
        let t = clamped - Double(band)
        return (0..<vertexCount).map { index in
            surfacePoint(band: band, index: index, t: t, tangents: tangents)
        }
    }

    /// The loft's direction of travel at a station. A ruled loft's direction is
    /// constant inside a band, so it jumps at an interior section; a smooth
    /// loft's tangent is the same value from either side, which is what makes
    /// the surface C1.
    func tangent(atStation station: Double, ringIndex index: Int) -> Vec3 {
        guard rings.count >= 2, rings[0].count > 0 else { return .unitZ }
        let last = Double(rings.count - 1)
        let clamped = min(max(station, 0), last)
        let band = announcedBand(for: clamped)
        let t = clamped - Double(band)
        let safeIndex = min(max(index, 0), rings[0].count - 1)
        switch parameters.mode {
        case .ruled:
            return (rings[band + 1].points[safeIndex] - rings[band].points[safeIndex])
                .normalized() ?? .unitZ
        case .smooth:
            let tangents = stationTangents()
            return Self.hermiteDerivative(
                rings[band].points[safeIndex],
                rings[band + 1].points[safeIndex],
                tangents[band][safeIndex],
                tangents[band + 1][safeIndex],
                t
            ).normalized() ?? .unitZ
        }
    }

    /// The surface normal at a station: the cross product of the direction of
    /// travel and the direction around the ring. It is what the row's normal
    /// continuity is measured on, because it is the surface's own definition
    /// rather than a facet of whatever subdivision the mesh happens to use.
    ///
    /// The sign is a convention, not an outward direction; only its continuity
    /// across a section is claimed here.
    func normal(atStation station: Double, ringIndex index: Int) -> Vec3 {
        let ring = self.ring(atStation: station)
        guard ring.count >= 3 else { return .unitZ }
        let vertex = min(max(index, 0), ring.count - 1)
        let along = tangent(atStation: station, ringIndex: vertex)
        let previous = ring[(vertex - 1 + ring.count) % ring.count]
        let next = ring[(vertex + 1) % ring.count]
        let around: Vec3
        if isClosed {
            around = next - previous
        } else if vertex == 0 {
            around = ring[1] - ring[0]
        } else if vertex == ring.count - 1 {
            around = ring[vertex] - ring[vertex - 1]
        } else {
            around = next - previous
        }
        guard let normal = along.cross(around).normalized() else { return .unitZ }
        return normal
    }

    func mesh() throws -> IndexedMesh {
        guard rings.count >= 2 else { throw FFLoftError.notEnoughSections(rings.count) }
        let count = vertexCount
        let edges = edgeCount
        let steps = parameters.effectiveSubdivisions

        var positions: [Vec3] = []
        positions.reserveCapacity(crossSectionCount * count)

        if parameters.mode == .ruled {
            for ring in rings {
                positions.append(contentsOf: ring.points)
            }
        } else {
            let tangents = stationTangents()
            for band in 0..<(rings.count - 1) {
                for step in 0..<steps {
                    let t = Double(step) / Double(steps)
                    for vertex in 0..<count {
                        positions.append(Self.hermite(
                            rings[band].points[vertex],
                            rings[band + 1].points[vertex],
                            tangents[band][vertex],
                            tangents[band + 1][vertex],
                            t
                        ))
                    }
                }
            }
            positions.append(contentsOf: rings[rings.count - 1].points)
        }

        var triangles: [MeshTriangle] = []
        triangles.reserveCapacity(estimatedTriangles)
        let sectionCount = positions.count / count
        for section in 0..<(sectionCount - 1) {
            for edge in 0..<edges {
                let next = (edge + 1) % count
                let a = section * count + edge
                let b = section * count + next
                let c = (section + 1) * count + next
                let d = (section + 1) * count + edge
                triangles.append(MeshTriangle(a, b, c))
                triangles.append(MeshTriangle(a, c, d))
            }
        }

        if isClosed, parameters.caps == .capped, count >= 3 {
            let startCap = try capTriangles(ring: rings[0], ringIndex: 0)
            let endCap = try capTriangles(ring: rings[rings.count - 1], ringIndex: rings.count - 1)
            let startBase = 0
            let endBase = positions.count - count
            let startOutward = tangent(atStation: 0, ringIndex: 0) * -1
            let endOutward = tangent(
                atStation: Double(rings.count - 1),
                ringIndex: 0
            )
            for triangle in startCap {
                triangles.append(Self.oriented(
                    triangle,
                    base: startBase,
                    outward: startOutward,
                    ringNormal: Self.newellNormal(rings[0].points)
                ))
            }
            for triangle in endCap {
                triangles.append(Self.oriented(
                    triangle,
                    base: endBase,
                    outward: endOutward,
                    ringNormal: Self.newellNormal(rings[rings.count - 1].points)
                ))
            }
        }

        guard let built = IndexedMesh(positions: positions, triangles: triangles) else {
            throw FFLoftError.couldNotBuildMesh
        }
        guard isClosed, parameters.caps == .capped else { return built }
        guard built.signedVolume() < 0 else { return built }
        let flipped = triangles.map { MeshTriangle($0.c, $0.b, $0.a) }
        guard let outward = IndexedMesh(positions: positions, triangles: flipped) else {
            throw FFLoftError.couldNotBuildMesh
        }
        return outward
    }

    // MARK: - Frames

    /// One tangent per station per vertex. Interior stations use the central
    /// difference, which is the Catmull–Rom tangent; the two ends follow the
    /// end-tangency choice.
    private func stationTangents() -> [[Vec3]] {
        let count = vertexCount
        let last = rings.count - 1
        var tangents: [[Vec3]] = []
        tangents.reserveCapacity(rings.count)
        for station in 0...last {
            var row: [Vec3] = []
            row.reserveCapacity(count)
            if station > 0, station < last {
                for vertex in 0..<count {
                    row.append(
                        (rings[station + 1].points[vertex] - rings[station - 1].points[vertex]) * 0.5
                    )
                }
            } else if station == 0 {
                let chord = (0..<count).map { rings[1].points[$0] - rings[0].points[$0] }
                row = endTangents(ring: rings[0], chord: chord, direction: 1)
            } else {
                let chord = (0..<count).map {
                    rings[last].points[$0] - rings[last - 1].points[$0]
                }
                row = endTangents(ring: rings[last], chord: chord, direction: 1)
            }
            tangents.append(row)
        }
        return tangents
    }

    /// The tangent row of one end section.
    ///
    /// `natural` keeps the chord to the neighbouring station. `perpendicular`
    /// turns it onto the section's own normal, keeping the chord's length and
    /// the direction that agrees with the chord, so an end ring meets the
    /// surface square without the loft reversing on itself.
    private func endTangents(ring: FFLoftRing, chord: [Vec3], direction: Double) -> [Vec3] {
        guard parameters.mode == .smooth, parameters.endTangency == .perpendicular else {
            return chord
        }
        guard let raw = Self.newellNormal(ring.points), let normal = raw.normalized() else {
            return chord
        }
        return chord.map { value in
            let length = value.length
            let sign = value.dot(normal) < 0 ? -1.0 : 1.0
            return normal * (length * sign * direction)
        }
    }

    /// The band a station sits in. A station on the final section belongs to the
    /// last band at t = 1 rather than to a band that does not exist.
    private func announcedBand(for station: Double) -> Int {
        let last = rings.count - 1
        let floored = Int(station.rounded(.down))
        return min(max(floored, 0), last - 1)
    }

    private static func hermite(
        _ start: Vec3,
        _ end: Vec3,
        _ startTangent: Vec3,
        _ endTangent: Vec3,
        _ t: Double
    ) -> Vec3 {
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return start * h00 + startTangent * h10 + end * h01 + endTangent * h11
    }

    private static func hermiteDerivative(
        _ start: Vec3,
        _ end: Vec3,
        _ startTangent: Vec3,
        _ endTangent: Vec3,
        _ t: Double
    ) -> Vec3 {
        let t2 = t * t
        let d00 = 6 * t2 - 6 * t
        let d10 = 3 * t2 - 4 * t + 1
        let d01 = -6 * t2 + 6 * t
        let d11 = 3 * t2 - 2 * t
        return start * d00 + startTangent * d10 + end * d01 + endTangent * d11
    }

    // MARK: - Caps and orientation

    /// A cap is triangulated in the section's own plane, then mapped back to its
    /// ring indices. The plane basis comes from the ring's Newell normal, so a
    /// cap works on a section that is not axis aligned.
    private func capTriangles(ring: FFLoftRing, ringIndex: Int) throws -> [(Int, Int, Int)] {
        guard let raw = Self.newellNormal(ring.points), let normal = raw.normalized() else {
            throw FFLoftError.sectionNotSimple(ringIndex)
        }
        let helper: Vec3
        if abs(normal.x) <= abs(normal.y) && abs(normal.x) <= abs(normal.z) {
            helper = .unitX
        } else if abs(normal.y) <= abs(normal.z) {
            helper = .unitY
        } else {
            helper = .unitZ
        }
        guard let uAxis = helper.cross(normal).normalized(),
              let vAxis = normal.cross(uAxis).normalized()
        else {
            throw FFLoftError.sectionNotSimple(ringIndex)
        }
        let origin = ring.points[0]
        let flat = ring.points.map { point -> Vec2 in
            let offset = point - origin
            return Vec2(x: offset.dot(uAxis), y: offset.dot(vAxis))
        }
        do {
            return try FFPolygonTriangulator.triangulate(flat)
        } catch {
            throw FFLoftError.sectionNotSimple(ringIndex)
        }
    }

    /// Winds one cap triangle so its face normal agrees with the outward half of
    /// the loft. The triangulator returns triangles in the ring's own plane
    /// order, so the work is deciding whether that order faces outward.
    private static func oriented(
        _ triangle: (Int, Int, Int),
        base: Int,
        outward: Vec3,
        ringNormal: Vec3?
    ) -> MeshTriangle {
        let agrees = (ringNormal ?? .unitZ).dot(outward) >= 0
        if agrees {
            return MeshTriangle(base + triangle.0, base + triangle.1, base + triangle.2)
        }
        return MeshTriangle(base + triangle.2, base + triangle.1, base + triangle.0)
    }

    /// Newell's normal: the area-weighted average of the ring's own triangles,
    /// which is well defined for a ring that is nearly but not exactly planar.
    static func newellNormal(_ points: [Vec3]) -> Vec3? {
        guard points.count >= 3 else { return nil }
        var normal = Vec3.zero
        for index in 0..<points.count {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            normal = normal + Vec3(
                x: (current.y - next.y) * (current.z + next.z),
                y: (current.z - next.z) * (current.x + next.x),
                z: (current.x - next.x) * (current.y + next.y)
            )
        }
        return normal.length > FFMath.eps ? normal : nil
    }

    private static func centroid(_ points: [Vec3]) -> Vec3 {
        guard !points.isEmpty else { return .zero }
        var sum = Vec3.zero
        for point in points { sum = sum + point }
        return sum * (1 / Double(points.count))
    }
}
