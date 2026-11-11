import Foundation

/// An oriented plane in millimetre space with an orthonormal in-plane basis.
///
/// A plane is the exact bridge between the 3-D scene and the 2-D payload a curve
/// already stores: `coordinates(of:)` flattens a point into the plane's frame and
/// `embed(_:)` lifts a sketch point back into space. Both constructors
/// orthonormalise, so `normal` is a unit vector and embedding a point and reading
/// it back round-trips to floating-point noise instead of to a tolerance. A
/// degenerate, parallel or non-finite input is refused rather than repaired.
struct FFPlane3D: Equatable, Sendable {
    var origin: Vec3
    var xAxis: Vec3
    var yAxis: Vec3

    /// The unit normal, right-handed with `xAxis` and `yAxis`.
    var normal: Vec3 { xAxis.cross(yAxis) }

    init?(origin: Vec3, xAxis: Vec3, yAxis: Vec3) {
        guard Self.isFinite(origin), Self.isFinite(xAxis), Self.isFinite(yAxis) else { return nil }
        guard let first = xAxis.normalized() else { return nil }
        let residual = yAxis - first * yAxis.dot(first)
        guard let second = residual.normalized() else { return nil }
        self.origin = origin
        self.xAxis = first
        self.yAxis = second
    }

    init?(origin: Vec3, normal: Vec3) {
        guard Self.isFinite(origin), let unit = normal.normalized() else { return nil }
        // The helper axis least aligned with the normal keeps the cross product
        // well conditioned for every orientation.
        let helper: Vec3
        if abs(unit.x) <= abs(unit.y) && abs(unit.x) <= abs(unit.z) {
            helper = .unitX
        } else if abs(unit.y) <= abs(unit.z) {
            helper = .unitY
        } else {
            helper = .unitZ
        }
        guard let first = helper.cross(unit).normalized() else { return nil }
        self.init(origin: origin, xAxis: first, yAxis: unit.cross(first))
    }

    private init(trusted origin: Vec3, xAxis: Vec3, yAxis: Vec3) {
        self.origin = origin
        self.xAxis = xAxis
        self.yAxis = yAxis
    }

    /// z = 0: the plane every new sketch starts on, and the plane the bench
    /// sample's ring stands on.
    static let ground = FFPlane3D(trusted: .zero, xAxis: .unitX, yAxis: .unitY)

    static func isFinite(_ vector: Vec3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    /// Positive on the normal's side of the plane, in millimetres.
    func signedDistance(of point: Vec3) -> Double {
        (point - origin).dot(normal)
    }

    /// The orthogonal (not normal-scaled) projection of a point onto the plane.
    func project(_ point: Vec3) -> Vec3 {
        point - normal * signedDistance(of: point)
    }

    /// The point's coordinates in the plane's own 2-D frame. For a point that
    /// already lies in the plane this loses nothing: `embed` is its exact inverse
    /// up to arithmetic.
    func coordinates(of point: Vec3) -> Vec2 {
        let offset = point - origin
        return Vec2(x: offset.dot(xAxis), y: offset.dot(yAxis))
    }

    func embed(_ point: Vec2) -> Vec3 {
        origin + xAxis * point.x + yAxis * point.y
    }

    func contains(_ point: Vec3, tolerance: Double = 1e-9) -> Bool {
        abs(signedDistance(of: point)) <= tolerance
    }

    func isParallel(to other: FFPlane3D, tolerance: Double = 1e-9) -> Bool {
        normal.cross(other.normal).length <= tolerance
    }

    func isPerpendicular(to other: FFPlane3D, tolerance: Double = 1e-9) -> Bool {
        abs(normal.dot(other.normal)) <= tolerance
    }
}

/// A curve payload placed in space by a plane.
///
/// The payload stays the document's own 2-D form, so a placed curve needs no
/// second geometry type and a projection can hand back a payload the file format
/// already accepts. A payload whose spans cannot be rebuilt is still a value the
/// document may hold, so the accessors here answer nil rather than guessing.
struct FFSpatialCurve: Equatable, Sendable {
    var payload: FFCurvePayload
    var plane: FFPlane3D

    var segmentCount: Int { payload.segments.count }

    /// The point at a payload-wide parameter `u` in `0...segmentCount`: the
    /// integer part selects the span and the fraction is that span's own `t`.
    /// A continuous parameter is what lets a scan cross a joint without treating
    /// the joint as a special case.
    func point(atGlobal u: Double) -> Vec3? {
        guard segmentCount > 0, u.isFinite, u >= 0 else { return nil }
        let span = min(Int(u.rounded(.down)), segmentCount - 1)
        let parameter = FFMath.clamp(u - Double(span), to: 0...1)
        return point(segment: span, parameter: parameter)
    }

    func point(segment: Int, parameter: Double) -> Vec3? {
        guard payload.segments.indices.contains(segment),
              let curve = payload.segments[segment].curve
        else { return nil }
        return plane.embed(curve.point(at: parameter))
    }

    var startPoint: Vec3? { point(segment: 0, parameter: 0) }

    var endPoint: Vec3? {
        guard segmentCount > 0 else { return nil }
        return point(segment: segmentCount - 1, parameter: 1)
    }

    /// Splits a payload-wide parameter into the span and the span's parameter.
    func location(atGlobal u: Double) -> (segment: Int, parameter: Double)? {
        guard segmentCount > 0, u.isFinite, u >= 0 else { return nil }
        let span = min(Int(u.rounded(.down)), segmentCount - 1)
        return (span, FFMath.clamp(u - Double(span), to: 0...1))
    }
}

extension FFSpatialCurve {
    /// The exact orthogonal projection of a curve onto a plane.
    ///
    /// Orthogonal projection is affine, and a Bézier or a rational NURBS is
    /// invariant under affine maps, so each span moves by its control points
    /// alone: weights, degree and knots do not change and nothing is refitted.
    /// The result is expressed in the target plane's coordinates, which is what
    /// makes the projection a payload rather than a sampled shadow. A payload
    /// whose spans cannot be rebuilt is refused instead of half-projected.
    func projected(onto plane: FFPlane3D) -> FFSpatialCurve? {
        guard !payload.segments.isEmpty else { return nil }
        var segments: [FFCurveSegment] = []
        segments.reserveCapacity(payload.segments.count)
        for segment in payload.segments {
            var moved = segment
            moved.controlPoints = segment.controlPoints.map { control in
                let world = self.plane.embed(control.vector)
                return FFPoint2(plane.coordinates(of: plane.project(world)))
            }
            guard moved.curve != nil else { return nil }
            segments.append(moved)
        }
        return FFSpatialCurve(
            payload: FFCurvePayload(segments: segments, isClosed: payload.isClosed),
            plane: plane
        )
    }

    /// The payload sampled into space at a caller's tolerance. This is display
    /// and interchange sampling, not a second representation: the payload stays
    /// the exact geometry and the projection of a curved surface lands on these
    /// points because its image has no payload form.
    func tessellatedPoints(settings: TessellationSettings = .export) -> [Vec3]? {
        guard !payload.segments.isEmpty else { return nil }
        var points: [Vec3] = []
        for segment in payload.segments {
            guard let curve = segment.curve,
                  let flattened = Tessellator.tessellate(curve, settings: settings)
            else { return nil }
            for point in flattened.points {
                let world = plane.embed(point)
                if let last = points.last, last.distance(to: world) <= FFTolerance.curveJoin {
                    continue
                }
                points.append(world)
            }
        }
        if payload.isClosed, points.count > 2,
           let first = points.first, let last = points.last,
           first.distance(to: last) <= FFTolerance.curveJoin {
            points.removeLast()
        }
        return points.count >= 2 ? points : nil
    }
}

/// A point where a spatial curve passes through a plane, in path order.
struct FFCurveCrossing: Equatable, Sendable {
    var segment: Int
    var parameter: Double
    var point: Vec3

    var summary: String {
        "Crossing · span \(segment + 1) · t \(FFPrecision.fixed(parameter, decimals: 4))"
    }
}

/// A sampled curve in space, from a projection whose image is not a payload.
///
/// This is a result type, never stored in a document: a projected curve on a
/// curved surface is not generally a rational curve, so it is carried as points
/// at whatever tolerance the caller asked for.
struct FFSpatialPolyline: Equatable, Sendable {
    var points: [Vec3]
    var isClosed: Bool

    init?(points: [Vec3], isClosed: Bool) {
        guard points.count >= (isClosed ? 3 : 2) else { return nil }
        guard points.allSatisfy(FFPlane3D.isFinite) else { return nil }
        self.points = points
        self.isClosed = isClosed
    }

    var length: Double {
        let edges = isClosed ? points.count : points.count - 1
        guard edges > 0 else { return 0 }
        var total = 0.0
        for index in 0..<edges {
            total += points[index].distance(to: points[(index + 1) % points.count])
        }
        return total
    }
}

/// A crossing of one sampled scalar along a payload-wide parameter.
///
/// The convention matches Phase 47's inflection search on purpose: a crossing is
/// a sign change between samples whose magnitudes both exceed the zero limit, or
/// a sample that sits on zero with opposite signs on either side. A span that
/// touches the zero and turns back is not a crossing, and a payload that lies
/// entirely on the zero reports none.
enum FFSpatialRoots {
    static let zero: Double = 1e-12
    static let bisectionSteps = 80
    static let bisectionTolerance = 1e-12

    static func crossings(
        spans: Int,
        samplesPerSpan: Int = 128,
        isCyclic: Bool,
        value: (Double) -> Double?
    ) -> [Double] {
        guard spans > 0 else { return [] }
        let steps = max(2, samplesPerSpan)
        let count = spans * steps
        var parameters: [Double] = []
        var values: [Double?] = []
        parameters.reserveCapacity(count + 1)
        values.reserveCapacity(count + 1)
        for index in 0...count {
            let u = Double(index) / Double(steps)
            parameters.append(u)
            values.append(value(u))
        }

        // A closed payload's seam is the same point twice, so rotating the sample
        // window to start at a nonzero sample puts that seam inside the scan and
        // leaves every zero with a neighbour on both sides.
        if isCyclic, count >= 2,
           let start = values.firstIndex(where: { sample in
               guard let sample else { return false }
               return abs(sample) > zero
           }),
           start > 0 {
            parameters = Array(parameters[start...]) + Array(parameters[..<start])
            values = Array(values[start...]) + Array(values[..<start])
        }

        var roots: [Double] = []
        var lastNonZero: Int?

        for index in values.indices {
            guard let sample = values[index] else {
                lastNonZero = nil
                continue
            }
            if abs(sample) <= zero {
                if let before = nearestNonZero(values, from: index, step: -1, isCyclic: isCyclic),
                   let after = nearestNonZero(values, from: index, step: 1, isCyclic: isCyclic),
                   let first = values[before], let second = values[after],
                   (first > 0) != (second > 0) {
                    roots.append(parameters[index])
                }
                // Either this zero is the crossing or the curve only touches, but
                // in both cases no bisection may straddle it.
                lastNonZero = nil
                continue
            }
            if let previous = lastNonZero, let before = values[previous],
               (before > 0) != (sample > 0),
               let root = bisect(
                   low: parameters[previous],
                   high: parameters[index],
                   value: value
               ) {
                roots.append(root)
            }
            lastNonZero = index
        }
        return roots
    }

    static func bisect(
        low: Double,
        high: Double,
        value: (Double) -> Double?
    ) -> Double? {
        var a = low
        var b = high
        guard var valueAtA = value(a), let valueAtB = value(b),
              (valueAtA > 0) != (valueAtB > 0)
        else { return nil }
        for _ in 0..<bisectionSteps {
            let middle = (a + b) / 2
            guard let valueAtMiddle = value(middle) else { return nil }
            if valueAtMiddle == 0 { return middle }
            if (valueAtMiddle > 0) == (valueAtA > 0) {
                a = middle
                valueAtA = valueAtMiddle
            } else {
                b = middle
            }
            if b - a <= bisectionTolerance { break }
        }
        return (a + b) / 2
    }

    /// The nearest sample that is not on zero in the given direction.
    ///
    /// A cyclic scan wraps once around the seam, because a closed payload's
    /// first and last sample are the same point: without the wrap, a crossing
    /// that lands exactly on that point — the ring's own profile starts on the
    /// mid-plane — would have no neighbour on one of its sides and would be
    /// dropped.
    private static func nearestNonZero(
        _ values: [Double?],
        from index: Int,
        step: Int,
        isCyclic: Bool
    ) -> Int? {
        var cursor = index
        for _ in 0..<values.count {
            cursor += step
            if cursor < 0 || cursor >= values.count {
                guard isCyclic else { return nil }
                cursor = (cursor + values.count) % values.count
            }
            guard let sample = values[cursor] else { return nil }
            if abs(sample) > zero { return cursor }
        }
        return nil
    }
}

extension FFSpatialCurve {
    /// Every place the curve passes through `plane`, in path order.
    ///
    /// The signed distance is sampled on a payload-wide parameter, so a crossing
    /// that falls exactly on a span joint is found by the joint's own samples
    /// rather than being missed by a per-span scan. Each reported point is
    /// evaluated on the curve itself, so it lies on the plane to arithmetic noise
    /// and on the curve exactly.
    func crossings(
        with plane: FFPlane3D,
        samplesPerSegment: Int = 128
    ) -> [FFCurveCrossing]? {
        guard segmentCount > 0 else { return [] }
        for segment in payload.segments where segment.curve == nil {
            return nil
        }
        let parameters = FFSpatialRoots.crossings(
            spans: segmentCount,
            samplesPerSpan: samplesPerSegment,
            isCyclic: payload.isClosed
        ) { u in
            guard let probe = self.point(atGlobal: u) else { return nil }
            return plane.signedDistance(of: probe)
        }

        var found: [FFCurveCrossing] = []
        for parameter in parameters {
            guard let spot = self.location(atGlobal: parameter),
                  let probe = self.point(atGlobal: parameter)
            else { continue }
            if let last = found.last, last.point.distance(to: probe) <= FFTolerance.curveJoin {
                continue
            }
            found.append(FFCurveCrossing(
                segment: spot.segment,
                parameter: spot.parameter,
                point: probe
            ))
        }
        return found
    }
}

/// Why a surface of revolution refused a construction or a query.
enum FFRevolutionError: Error, Equatable, LocalizedError, Sendable {
    case degenerateAxis
    case emptyProfile
    case profileOffAxis
    case flatProfile
    case unsupportedSectionPlane
    case multiSheetProfile
    case damagedCurve
    case profileCrossesAxis

    var errorDescription: String? {
        switch self {
        case .degenerateAxis:
            return "A surface of revolution needs a finite, non-zero axis"
        case .emptyProfile:
            return "A surface of revolution needs a profile with at least one span"
        case .profileOffAxis:
            return "The profile must lie in a plane that contains the axis"
        case .flatProfile:
            return "The profile must change height along the axis; a flat profile revolves to a ring, not a surface"
        case .unsupportedSectionPlane:
            return "A section needs a plane perpendicular to the axis or one that contains it; any other plane is not a curve this model represents"
        case .multiSheetProfile:
            return "This surface has an inner and an outer wall at one height; cut the body with a section plane instead of intersecting a curve"
        case .damagedCurve:
            return "The curve has a span that cannot be rebuilt, so it has no crossings"
        case .profileCrossesAxis:
            return "The profile must stay on one side of the axis; a profile that crosses it revolves to a self-intersecting surface"
        }
    }
}

/// A surface swept by revolving a planar profile about an axis in that plane.
///
/// The point at profile parameter `t` and angle `theta` is
/// `axisOrigin + axis * a(t) + (radial * cos(theta) + outOfPlane * sin(theta)) * r(t)`,
/// where `a` is the profile point's axial coordinate and `r` its distance from
/// the axis. The ring the app already draws is exactly this surface: the demo
/// scene's torus uses the same parameterisation, which is what lets a section of
/// this model be checked against the shipping body instead of against a refit.
struct FFRevolutionSurface: Equatable, Sendable {
    let axisOrigin: Vec3
    let axis: Vec3
    let profile: FFSpatialCurve
    /// True when the profile's axial coordinate only rises or only falls, so
    /// every height has exactly one radius. A closed profile such as the ring's
    /// tube is not single-sheeted: at one height it has an inner and an outer
    /// wall.
    let isSingleSheet: Bool

    /// The profile plane's angle-zero radial direction, oriented towards the
    /// side the profile is actually on. `axis x normal` alone would mirror the
    /// surface whenever the profile sits on the other side of the axis, so the
    /// initialiser turns it to the profile and refuses a profile that straddles
    /// the axis.
    let radialAxis: Vec3

    /// The profile plane's normal: the direction a revolution turns into.
    var outOfPlane: Vec3 { profile.plane.normal }

    let heightRange: ClosedRange<Double>

    init(axisOrigin: Vec3, axis: Vec3, profile: FFSpatialCurve) throws {
        guard FFPlane3D.isFinite(axisOrigin), let unitAxis = axis.normalized() else {
            throw FFRevolutionError.degenerateAxis
        }
        guard !profile.payload.segments.isEmpty else {
            throw FFRevolutionError.emptyProfile
        }
        guard profile.plane.contains(axisOrigin, tolerance: 1e-9),
              abs(profile.plane.normal.dot(unitAxis)) <= 1e-9
        else {
            throw FFRevolutionError.profileOffAxis
        }
        for segment in profile.payload.segments where segment.curve == nil {
            throw FFRevolutionError.emptyProfile
        }
        guard let candidate = unitAxis.cross(profile.plane.normal).normalized() else {
            throw FFRevolutionError.degenerateAxis
        }

        // Orient the radial axis to the profile's own side. On-curve samples are
        // what the surface actually has to reproduce, so the check uses them
        // rather than control points, which may stand off a rational span.
        var smallest = Double.infinity
        var largest = -Double.infinity
        for segment in profile.payload.segments {
            guard let curve = segment.curve else { throw FFRevolutionError.emptyProfile }
            for step in 0...4 {
                let sample = profile.plane.embed(curve.point(at: Double(step) / 4))
                let offset = sample - axisOrigin
                let perpendicular = offset - unitAxis * offset.dot(unitAxis)
                let side = perpendicular.dot(candidate)
                smallest = min(smallest, side)
                largest = max(largest, side)
            }
        }
        let oriented: Vec3
        if smallest < -1e-9 {
            guard largest <= 1e-9 else {
                throw FFRevolutionError.profileCrossesAxis
            }
            oriented = candidate * -1
        } else {
            oriented = candidate
        }

        var lowest = Double.infinity
        var highest = -Double.infinity
        var rising = false
        var falling = false
        var previousHeight: Double?
        let samplesPerSegment = 128
        for span in 0..<profile.segmentCount {
            for step in 0...samplesPerSegment {
                let u = Double(span) + Double(step) / Double(samplesPerSegment)
                guard let point = profile.point(atGlobal: u) else {
                    throw FFRevolutionError.emptyProfile
                }
                let height = (point - axisOrigin).dot(unitAxis)
                lowest = min(lowest, height)
                highest = max(highest, height)
                if let previousHeight {
                    let change = height - previousHeight
                    if change > 1e-9 { rising = true }
                    if change < -1e-9 { falling = true }
                }
                previousHeight = height
            }
        }
        guard highest - lowest > FFMath.eps else {
            throw FFRevolutionError.flatProfile
        }

        self.axisOrigin = axisOrigin
        self.axis = unitAxis
        self.profile = profile
        self.radialAxis = oriented
        self.heightRange = lowest...highest
        self.isSingleSheet = !(rising && falling)
    }

    func axialCoordinate(of point: Vec3) -> Double {
        (point - axisOrigin).dot(axis)
    }

    func radialDistance(of point: Vec3) -> Double {
        let offset = point - axisOrigin
        return (offset - axis * offset.dot(axis)).length
    }

    /// The angle of a point about the axis, measured from the profile plane.
    func angle(of point: Vec3) -> Double {
        let offset = point - axisOrigin
        let radial = offset - axis * offset.dot(axis)
        return atan2(radial.dot(outOfPlane), radial.dot(radialAxis))
    }

    /// The surface point at a profile parameter and a revolution angle.
    func point(atParameter u: Double, around angle: Double) -> Vec3? {
        guard let profilePoint = profile.point(atGlobal: u) else { return nil }
        let height = axialCoordinate(of: profilePoint)
        let radius = radialDistance(of: profilePoint)
        return axisOrigin
            + axis * height
            + (radialAxis * cos(angle) + outOfPlane * sin(angle)) * radius
    }

    // MARK: - Profile inversion

    /// The profile parameters at one axial height, in path order.
    ///
    /// A transversal crossing of the height plane is a root of `a(t) - h`, found
    /// with the same sign-change scan the curve/plane intersection uses. A
    /// profile that only touches the height contributes no root, which is the
    /// same convention as a curve that only touches a plane.
    func profileParameters(atHeight height: Double) -> [Double] {
        guard height.isFinite else { return [] }
        return FFSpatialRoots.crossings(
            spans: profile.segmentCount,
            samplesPerSpan: 128,
            isCyclic: profile.payload.isClosed
        ) { u in
            guard let point = profile.point(atGlobal: u) else { return nil }
            return axialCoordinate(of: point) - height
        }
    }

    func profileRadius(atParameter u: Double) -> Double? {
        guard let point = profile.point(atGlobal: u) else { return nil }
        return radialDistance(of: point)
    }

    // MARK: - Sections

    /// The curves where a plane cuts the surface.
    ///
    /// Two families are representable exactly. A plane perpendicular to the axis
    /// cuts a circle at every height where the profile has a radius, and each
    /// circle is the exact rational quadratic the arc tool already writes. A
    /// plane containing the axis cuts the profile itself and its opposite side,
    /// both rigid images of the same payload, so neither is refitted. Any other
    /// plane is refused with a sentence rather than approximated, because its
    /// section is not a curve this model can express.
    func section(by plane: FFPlane3D) throws -> [FFSpatialCurve] {
        if abs(plane.normal.dot(axis)) >= 1 - 1e-9 {
            return sectionPerpendicular(plane)
        }
        if plane.contains(axisOrigin, tolerance: 1e-9),
           abs(plane.normal.dot(axis)) <= 1e-9 {
            return try sectionThroughAxis(plane)
        }
        throw FFRevolutionError.unsupportedSectionPlane
    }

    private func sectionPerpendicular(_ plane: FFPlane3D) -> [FFSpatialCurve] {
        let height = axialCoordinate(of: plane.origin)
        guard height >= heightRange.lowerBound - 1e-9,
              height <= heightRange.upperBound + 1e-9
        else { return [] }

        var curves: [FFSpatialCurve] = []
        var radii: [Double] = []
        let centre = axisOrigin + axis * height
        for parameter in profileParameters(atHeight: height) {
            guard let radius = profileRadius(atParameter: parameter),
                  radius > FFMath.eps
            else { continue }
            if radii.contains(where: { abs($0 - radius) <= 1e-9 }) { continue }
            guard let arc = try? FFArc2D(
                center: .zero,
                radius: radius,
                startAngle: 0,
                sweep: FFArc2D.fullTurn
            ),
            let sectionPlane = FFPlane3D(
                origin: centre,
                xAxis: plane.xAxis,
                yAxis: plane.yAxis
            )
            else { continue }
            radii.append(radius)
            curves.append(FFSpatialCurve(
                payload: FFArcTool.payload(for: arc),
                plane: sectionPlane
            ))
        }
        return curves
    }

    private func sectionThroughAxis(_ plane: FFPlane3D) throws -> [FFSpatialCurve] {
        guard let sectionRadial = axis.cross(plane.normal).normalized() else {
            throw FFRevolutionError.unsupportedSectionPlane
        }
        // Rotation about the axis takes `radialAxis` to
        // `radialAxis cos(b) + (axis x radialAxis) sin(b)`, so this is the angle
        // that lands the profile on the section plane.
        let cosine = radialAxis.dot(sectionRadial)
        let sine = axis.cross(radialAxis).dot(sectionRadial)
        let offset = atan2(sine, cosine)

        var curves: [FFSpatialCurve] = []
        for turn in [offset, offset + Double.pi] {
            var segments: [FFCurveSegment] = []
            segments.reserveCapacity(profile.payload.segments.count)
            for segment in profile.payload.segments {
                var moved = segment
                moved.controlPoints = segment.controlPoints.map { control in
                    let world = profile.plane.embed(control.vector)
                    let rotated = rotated(world, by: turn)
                    return FFPoint2(plane.coordinates(of: rotated))
                }
                guard moved.curve != nil else { return [] }
                segments.append(moved)
            }
            guard !segments.isEmpty else { continue }
            curves.append(FFSpatialCurve(
                payload: FFCurvePayload(segments: segments, isClosed: profile.payload.isClosed),
                plane: plane
            ))
        }
        return curves
    }

    private func rotated(_ point: Vec3, by angle: Double) -> Vec3 {
        let offset = point - axisOrigin
        let parallel = axis * offset.dot(axis)
        let perpendicular = offset - parallel
        let turned = perpendicular * cos(angle) + axis.cross(perpendicular) * sin(angle)
        return axisOrigin + parallel + turned
    }

    // MARK: - Projection onto the surface

    /// Projects a curve onto the surface along the surface's own radial
    /// parameterisation.
    ///
    /// A point keeps its revolution angle and its axial height, and its distance
    /// from the axis becomes the profile's radius at that height. Where a profile
    /// crosses one height twice — the ring's inner and outer wall — the wall
    /// nearer the source point is chosen, so the result is deterministic. The
    /// image of a rational curve under this map is not rational in general, so
    /// the result is a sampled polyline rather than a payload; every one of its
    /// points is a surface point by construction.
    func projected(
        _ curve: FFSpatialCurve,
        settings: TessellationSettings = .export
    ) -> FFSpatialPolyline? {
        guard let source = curve.tessellatedPoints(settings: settings) else { return nil }
        var points: [Vec3] = []
        points.reserveCapacity(source.count)
        for point in source {
            let height = axialCoordinate(of: point)
            let radial = radialDistance(of: point)
            let candidates = profileParameters(atHeight: height)
            guard !candidates.isEmpty else { return nil }
            var chosen: (radius: Double, gap: Double)?
            for parameter in candidates {
                guard let radius = profileRadius(atParameter: parameter) else { continue }
                let gap = abs(radius - radial)
                if chosen == nil || gap < chosen!.gap {
                    chosen = (radius, gap)
                }
            }
            guard let chosen else { return nil }
            let theta = angle(of: point)
            let mapped = axisOrigin
                + axis * height
                + (radialAxis * cos(theta) + outOfPlane * sin(theta)) * chosen.radius
            if let last = points.last, last.distance(to: mapped) <= FFTolerance.curveJoin {
                continue
            }
            points.append(mapped)
        }
        return FFSpatialPolyline(points: points, isClosed: curve.payload.isClosed)
    }

    // MARK: - Intersection with a curve

    /// Where a curve passes through the surface.
    ///
    /// This needs one radius per height, so it is defined for a single-sheeted
    /// profile only; a closed profile has two walls at one height and is cut by a
    /// section plane instead. A curve outside the surface's height extent cannot
    /// cross it, so those stretches break the scan rather than producing a sign
    /// that has no meaning there.
    func crossings(of curve: FFSpatialCurve) throws -> [FFCurveCrossing] {
        guard isSingleSheet else { throw FFRevolutionError.multiSheetProfile }
        for segment in curve.payload.segments where segment.curve == nil {
            throw FFRevolutionError.damagedCurve
        }
        var result: [FFCurveCrossing] = []
        let parameters = FFSpatialRoots.crossings(
            spans: curve.segmentCount,
            samplesPerSpan: 128,
            isCyclic: curve.payload.isClosed
        ) { u in
            guard let point = curve.point(atGlobal: u) else { return nil }
            let height = axialCoordinate(of: point)
            guard height >= heightRange.lowerBound - 1e-9,
                  height <= heightRange.upperBound + 1e-9
            else { return nil }
            guard let profileParameter = profileParameters(atHeight: height).first,
                  let radius = profileRadius(atParameter: profileParameter)
            else { return nil }
            return radialDistance(of: point) - radius
        }

        for parameter in parameters {
            guard let location = curve.location(atGlobal: parameter),
                  let point = curve.point(atGlobal: parameter)
            else { continue }
            if let last = result.last, last.point.distance(to: point) <= FFTolerance.curveJoin {
                continue
            }
            result.append(FFCurveCrossing(
                segment: location.segment,
                parameter: location.parameter,
                point: point
            ))
        }
        return result
    }
}
