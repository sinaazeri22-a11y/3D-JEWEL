import Foundation

/// The twelve original ring cross-sections the profile library offers.
///
/// A band's cross-section is drawn in the profile plane: `x` is the distance
/// from the ring axis and `y` is the height along it, so the bore is the face at
/// `x = boreRadius`, the crest is the face at `x = boreRadius + thickness`, and
/// the two side faces are at `y = +/- width/2`. Every kind is built from
/// straight spans and exact circular arcs, and each arc is encoded with the
/// rational quadratic `FFArcTool` already writes, so a profile opens as an
/// ordinary curve payload: the file format, the schema and the canonical hash
/// need no new field, and the control-point tools edit the result like any other
/// curve.
enum FFRingProfileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case dShape
    case flat
    case comfortFit
    case comfortDome
    case knifeEdge
    case knifeChamfer
    case cathedral
    case cathedralChamfer
    case cathedralStep
    case oval
    case cushion
    case bevel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dShape: return "D-shape"
        case .flat: return "Flat band"
        case .comfortFit: return "Comfort fit"
        case .comfortDome: return "Comfort dome"
        case .knifeEdge: return "Knife edge"
        case .knifeChamfer: return "Chamfered knife"
        case .cathedral: return "Cathedral"
        case .cathedralChamfer: return "Cathedral chamfer"
        case .cathedralStep: return "Cathedral step"
        case .oval: return "Oval"
        case .cushion: return "Cushion"
        case .bevel: return "Bevelled"
        }
    }

    /// One sentence for a picker: what the section does, not how it is built.
    var detail: String {
        switch self {
        case .dShape:
            return "Flat bore with a single round crown, the classic D section"
        case .flat:
            return "Rectangular band with softened crest edges"
        case .comfortFit:
            return "Relieved bore that only touches the finger at mid-width, flat crest"
        case .comfortDome:
            return "Relieved bore and a domed crest, two arcs meeting at the band edges"
        case .knifeEdge:
            return "Flat bore tapering to a sharp ridge on the crest"
        case .knifeChamfer:
            return "Knife edge truncated to a narrow flat crest"
        case .cathedral:
            return "Raised crest with hollow shoulders"
        case .cathedralChamfer:
            return "Raised crest with straight chamfered shoulders"
        case .cathedralStep:
            return "Raised crest with a square step down to each shoulder"
        case .oval:
            return "Full elliptical section, round inside and out"
        case .cushion:
            return "Band with generous round crest and bore edges"
        case .bevel:
            return "Rectangular band with 45 degree edge chamfers"
        }
    }
}

/// The three measurements a band is specified by, in millimetres.
///
/// `boreRadius` is the smallest bore radius, which for a comfort-fit section is
/// the radius at mid-width; the relieved band edges sit further out. Every
/// derived radius and offset in the library is a proportion of these three, so a
/// parameter change moves the whole section instead of one face of it.
struct FFRingProfileParameters: Codable, Equatable, Sendable {
    var boreRadius: Double
    var width: Double
    var thickness: Double

    /// A 19 mm bore, 2 mm wide and 1.6 mm thick: a common light band, and room
    /// for every proportion in the library to be a sensible size.
    static let standard = FFRingProfileParameters(
        boreRadius: 9.5,
        width: 2,
        thickness: 1.6
    )

    init(boreRadius: Double = 9.5, width: Double = 2, thickness: Double = 1.6) {
        self.boreRadius = boreRadius
        self.width = width
        self.thickness = thickness
    }

    var halfWidth: Double { width / 2 }

    var outerRadius: Double { boreRadius + thickness }

    /// The only validation source: the document and a panel's enabled state both
    /// read this, so they cannot disagree about whether a section can be built.
    var isValid: Bool {
        boreRadius.isFinite && width.isFinite && thickness.isFinite
            && boreRadius > FFMath.eps
            && width > FFMath.eps
            && thickness > FFMath.eps
    }
}

/// One library section: a kind plus the band it is cut from.
struct FFRingProfile: Equatable, Sendable {
    var kind: FFRingProfileKind
    var parameters: FFRingProfileParameters

    init(kind: FFRingProfileKind, parameters: FFRingProfileParameters = .standard) {
        self.kind = kind
        self.parameters = parameters
    }

    /// The exact closed payload this section stands for.
    func payload() throws -> FFCurvePayload {
        try FFRingProfileGeometry.payload(for: self)
    }

    /// The same payload placed on a plane that contains the axis, which is the
    /// form a revolution surface needs. The plane's x axis is the radial
    /// direction, so the profile's own x is the distance from the axis.
    func spatial(axisOrigin: Vec3 = .zero, axis: Vec3 = .unitY) throws -> FFSpatialCurve {
        guard let unitAxis = axis.normalized() else {
            throw FFRingProfileError.invalidAxis
        }
        // The profile plane must contain the axis, because a revolution turns
        // the profile about a line in its own plane. The helper axis is the one
        // least aligned with the axis, the same choice `FFPlane3D`'s normal
        // initialiser makes, so the frame stays well conditioned at every
        // orientation rather than only at the default one.
        let helper: Vec3
        if abs(unitAxis.x) <= abs(unitAxis.y) && abs(unitAxis.x) <= abs(unitAxis.z) {
            helper = .unitX
        } else if abs(unitAxis.y) <= abs(unitAxis.z) {
            helper = .unitY
        } else {
            helper = .unitZ
        }
        guard let radial = helper.cross(unitAxis).normalized(),
              let plane = FFPlane3D(origin: axisOrigin, xAxis: radial, yAxis: unitAxis)
        else {
            throw FFRingProfileError.invalidAxis
        }
        return FFSpatialCurve(payload: try payload(), plane: plane)
    }

    /// A short, display-ready description in the document's unit. Views format
    /// it, never compute it.
    func summary(unit: FFLengthUnit) -> String {
        let bore = FFPrecision.lengthString(
            millimetres: parameters.boreRadius * 2,
            unit: unit
        )
        let width = FFPrecision.lengthString(millimetres: parameters.width, unit: unit)
        let thickness = FFPrecision.lengthString(millimetres: parameters.thickness, unit: unit)
        return "bore \(bore) · \(width) wide · \(thickness) thick"
    }
}

/// Why a section could not be built. Each case carries a sentence so a refusal
/// explains itself instead of returning a plausible-looking curve.
enum FFRingProfileError: Error, Equatable, LocalizedError, Sendable {
    case invalidParameters
    case invalidAxis
    case damagedProfile

    var errorDescription: String? {
        switch self {
        case .invalidParameters:
            return "A ring profile needs a bore radius, width and thickness greater than zero"
        case .invalidAxis:
            return "A ring profile needs a finite, non-zero axis to revolve about"
        case .damagedProfile:
            return "The profile produced a curve that could not be rebuilt"
        }
    }
}

/// Turns a section into the payload the document already stores.
///
/// Nothing here samples or fits: every curved span is a circular arc encoded as
/// the exact rational quadratic `FFArcTool` writes, and every straight span is a
/// degree-one Bézier. The proportions below are the design of each section, not
/// tunable knobs; a parameter change scales the same construction.
enum FFRingProfileGeometry {
    static func payload(for profile: FFRingProfile) throws -> FFCurvePayload {
        let parameters = profile.parameters
        guard parameters.isValid else { throw FFRingProfileError.invalidParameters }
        let segments = try segments(for: profile.kind, parameters: parameters)
        guard segments.count >= 2 else { throw FFRingProfileError.damagedProfile }

        var curves: [Curve2D] = []
        curves.reserveCapacity(segments.count)
        for segment in segments {
            guard let curve = segment.curve else { throw FFRingProfileError.damagedProfile }
            curves.append(curve)
        }
        // Every joint of a closed section is the same computed point twice, so
        // the seam check is arithmetic noise rather than a tolerance to tune.
        for index in curves.indices {
            let next = (index + 1) % curves.count
            guard curves[index].end.distance(to: curves[next].start) <= FFTolerance.curveJoin else {
                throw FFRingProfileError.damagedProfile
            }
        }
        return FFCurvePayload(segments: segments, isClosed: true)
    }

    static func segments(
        for kind: FFRingProfileKind,
        parameters: FFRingProfileParameters
    ) throws -> [FFCurveSegment] {
        let bore = parameters.boreRadius
        let outer = parameters.outerRadius
        let half = parameters.halfWidth
        let thickness = parameters.thickness

        switch kind {
        case .dShape:
            // Flat bore and a half-ellipse crown. A *circular* arc through the
            // bore's two ends and the crest point is only a semicircle when the
            // thickness is half the width: at any other proportion it is the
            // major arc, which leaves the band box and wraps the section round
            // on itself. The ellipse has the same three points for every
            // proportion, stays inside the box, and is a true circular D when
            // the thickness is half the width.
            let crown = Vec2(x: bore, y: 0)
            var segments = [line(Vec2(x: bore, y: -half), Vec2(x: bore, y: half))]
            segments.append(clockwiseEllipseQuarter(
                center: crown,
                halfWidth: thickness,
                halfHeight: half,
                startAngle: FFPrimitiveGeometry.quarterTurn
            ))
            segments.append(clockwiseEllipseQuarter(
                center: crown,
                halfWidth: thickness,
                halfHeight: half,
                startAngle: 0
            ))
            return segments

        case .flat:
            return try roundedBox(
                bore: bore,
                outer: outer,
                half: half,
                corner: 0.15 * min(thickness, parameters.width)
            )

        case .comfortFit:
            let relief = 0.30 * min(thickness, half)
            let corner = 0.15 * min(thickness, half)
            let bottom = Vec2(x: bore + relief, y: -half)
            let top = Vec2(x: bore + relief, y: half)
            let crestTop = Vec2(x: outer, y: half - corner)
            let crestBottom = Vec2(x: outer, y: -half + corner)
            var segments = try arc(bottom, Vec2(x: bore, y: 0), top)
            segments.append(line(top, Vec2(x: outer - corner, y: half)))
            segments += try fillet(
                Vec2(x: outer - corner, y: half),
                crestTop,
                center: Vec2(x: outer - corner, y: half - corner)
            )
            segments.append(line(crestTop, crestBottom))
            segments += try fillet(
                crestBottom,
                Vec2(x: outer - corner, y: -half),
                center: Vec2(x: outer - corner, y: -half + corner)
            )
            segments.append(line(Vec2(x: outer - corner, y: -half), bottom))
            return segments

        case .comfortDome:
            let relief = 0.30 * min(thickness, half)
            let bottom = Vec2(x: bore + relief, y: -half)
            let top = Vec2(x: bore + relief, y: half)
            var segments = try arc(bottom, Vec2(x: bore, y: 0), top)
            // The crest is the same half-ellipse reasoning as the D section.
            let crown = Vec2(x: bore + relief, y: 0)
            segments.append(clockwiseEllipseQuarter(
                center: crown,
                halfWidth: thickness - relief,
                halfHeight: half,
                startAngle: FFPrimitiveGeometry.quarterTurn
            ))
            segments.append(clockwiseEllipseQuarter(
                center: crown,
                halfWidth: thickness - relief,
                halfHeight: half,
                startAngle: 0
            ))
            return segments

        case .knifeEdge:
            return [
                line(Vec2(x: bore, y: -half), Vec2(x: bore, y: half)),
                line(Vec2(x: bore, y: half), Vec2(x: outer, y: 0)),
                line(Vec2(x: outer, y: 0), Vec2(x: bore, y: -half)),
            ]

        case .knifeChamfer:
            let tip = 0.25 * half
            return [
                line(Vec2(x: bore, y: -half), Vec2(x: bore, y: half)),
                line(Vec2(x: bore, y: half), Vec2(x: outer, y: tip)),
                line(Vec2(x: outer, y: tip), Vec2(x: outer, y: -tip)),
                line(Vec2(x: outer, y: -tip), Vec2(x: bore, y: -half)),
            ]

        case .cathedral:
            let radius = min(thickness / 2, half / 2)
            let shoulder = outer - radius
            var segments = [line(Vec2(x: bore, y: -half), Vec2(x: bore, y: half))]
            segments.append(line(Vec2(x: bore, y: half), Vec2(x: shoulder, y: half)))
            segments += try fillet(
                Vec2(x: shoulder, y: half),
                Vec2(x: outer, y: half - radius),
                center: Vec2(x: shoulder, y: half - radius)
            )
            segments.append(line(
                Vec2(x: outer, y: half - radius),
                Vec2(x: outer, y: -half + radius)
            ))
            segments += try fillet(
                Vec2(x: outer, y: -half + radius),
                Vec2(x: shoulder, y: -half),
                center: Vec2(x: shoulder, y: -half + radius)
            )
            segments.append(line(Vec2(x: shoulder, y: -half), Vec2(x: bore, y: -half)))
            return segments

        case .cathedralChamfer:
            let chamfer = min(0.4 * thickness, 0.4 * half)
            return [
                line(Vec2(x: bore, y: -half), Vec2(x: bore, y: half)),
                line(Vec2(x: bore, y: half), Vec2(x: outer - chamfer, y: half)),
                line(
                    Vec2(x: outer - chamfer, y: half),
                    Vec2(x: outer, y: half - chamfer)
                ),
                line(
                    Vec2(x: outer, y: half - chamfer),
                    Vec2(x: outer, y: -half + chamfer)
                ),
                line(
                    Vec2(x: outer, y: -half + chamfer),
                    Vec2(x: outer - chamfer, y: -half)
                ),
                line(Vec2(x: outer - chamfer, y: -half), Vec2(x: bore, y: -half)),
            ]

        case .cathedralStep:
            let step = 0.35 * thickness
            let tread = 0.4 * half
            return [
                line(Vec2(x: bore, y: -half), Vec2(x: bore, y: half)),
                line(Vec2(x: bore, y: half), Vec2(x: outer - step, y: half)),
                line(
                    Vec2(x: outer - step, y: half),
                    Vec2(x: outer - step, y: half - tread)
                ),
                line(
                    Vec2(x: outer - step, y: half - tread),
                    Vec2(x: outer, y: half - tread)
                ),
                line(
                    Vec2(x: outer, y: half - tread),
                    Vec2(x: outer, y: -half + tread)
                ),
                line(
                    Vec2(x: outer, y: -half + tread),
                    Vec2(x: outer - step, y: -half + tread)
                ),
                line(
                    Vec2(x: outer - step, y: -half + tread),
                    Vec2(x: outer - step, y: -half)
                ),
                line(Vec2(x: outer - step, y: -half), Vec2(x: bore, y: -half)),
            ]

        case .oval:
            // Four exact rational quadratic quarters of one ellipse, the same
            // encoding Phase 41's ellipse primitive uses.
            let center = Vec2(x: bore + thickness / 2, y: 0)
            return (0..<4).map { index in
                FFPrimitiveGeometry.ellipticalQuarter(
                    center: center,
                    halfWidth: thickness / 2,
                    halfHeight: half,
                    startAngle: Double(index) * FFPrimitiveGeometry.quarterTurn
                )
            }

        case .cushion:
            return try roundedBox(
                bore: bore,
                outer: outer,
                half: half,
                corner: 0.45 * min(thickness, parameters.width)
            )

        case .bevel:
            let chamfer = 0.2 * min(thickness, parameters.width)
            return [
                line(
                    Vec2(x: bore, y: -half + chamfer),
                    Vec2(x: bore, y: half - chamfer)
                ),
                line(Vec2(x: bore, y: half - chamfer), Vec2(x: bore + chamfer, y: half)),
                line(
                    Vec2(x: bore + chamfer, y: half),
                    Vec2(x: outer - chamfer, y: half)
                ),
                line(Vec2(x: outer - chamfer, y: half), Vec2(x: outer, y: half - chamfer)),
                line(
                    Vec2(x: outer, y: half - chamfer),
                    Vec2(x: outer, y: -half + chamfer)
                ),
                line(
                    Vec2(x: outer, y: -half + chamfer),
                    Vec2(x: outer - chamfer, y: -half)
                ),
                line(
                    Vec2(x: outer - chamfer, y: -half),
                    Vec2(x: bore + chamfer, y: -half)
                ),
                line(Vec2(x: bore + chamfer, y: -half), Vec2(x: bore, y: -half + chamfer)),
            ]
        }
    }

    // MARK: - Pieces

    /// A closed box with the same quarter arc at each of its four corners.
    private static func roundedBox(
        bore: Double,
        outer: Double,
        half: Double,
        corner: Double
    ) throws -> [FFCurveSegment] {
        let leftTop = Vec2(x: bore, y: half - corner)
        let topLeft = Vec2(x: bore + corner, y: half)
        let topRight = Vec2(x: outer - corner, y: half)
        let rightTop = Vec2(x: outer, y: half - corner)
        let rightBottom = Vec2(x: outer, y: -half + corner)
        let bottomRight = Vec2(x: outer - corner, y: -half)
        let bottomLeft = Vec2(x: bore + corner, y: -half)
        let leftBottom = Vec2(x: bore, y: -half + corner)

        var segments = [line(leftBottom, leftTop)]
        segments += try fillet(
            leftTop,
            topLeft,
            center: Vec2(x: bore + corner, y: half - corner)
        )
        segments.append(line(topLeft, topRight))
        segments += try fillet(
            topRight,
            rightTop,
            center: Vec2(x: outer - corner, y: half - corner)
        )
        segments.append(line(rightTop, rightBottom))
        segments += try fillet(
            rightBottom,
            bottomRight,
            center: Vec2(x: outer - corner, y: -half + corner)
        )
        segments.append(line(bottomRight, bottomLeft))
        segments += try fillet(
            bottomLeft,
            leftBottom,
            center: Vec2(x: bore + corner, y: -half + corner)
        )
        return segments
    }

    /// A quarter of an axis-aligned ellipse traversed clockwise from
    /// `startAngle`, which is the direction a crown runs when the bore is walked
    /// upwards. The control point is the tangent intersection, so the span is the
    /// exact conic rather than a sampled arc; `halfWidth` is the radial semi-axis
    /// and `halfHeight` the axial one.
    private static func clockwiseEllipseQuarter(
        center: Vec2,
        halfWidth: Double,
        halfHeight: Double,
        startAngle: Double
    ) -> FFCurveSegment {
        let quarter = FFPrimitiveGeometry.quarterTurn
        let endAngle = startAngle - quarter
        let middle = startAngle - quarter / 2
        let cosine = cos(quarter / 2)
        let start = center + Vec2(
            x: halfWidth * cos(startAngle),
            y: halfHeight * sin(startAngle)
        )
        let end = center + Vec2(
            x: halfWidth * cos(endAngle),
            y: halfHeight * sin(endAngle)
        )
        let control = center + Vec2(
            x: halfWidth * cos(middle) / cosine,
            y: halfHeight * sin(middle) / cosine
        )
        return FFCurveSegment(
            kind: .nurbs,
            controlPoints: [FFPoint2(start), FFPoint2(control), FFPoint2(end)],
            weights: [1, cosine, 1],
            degree: 2,
            knots: [0, 0, 0, 1, 1, 1]
        )
    }

    /// The 90 degree arc between two points that both sit one radius from
    /// `center`. Its midpoint lies on the bisector, so one construction serves a
    /// convex edge break and a concave shoulder fillet: the material side is
    /// decided by where the centre is, not by a second code path.
    private static func fillet(
        _ start: Vec2,
        _ end: Vec2,
        center: Vec2
    ) throws -> [FFCurveSegment] {
        let first = start - center
        let second = end - center
        guard let bisector = (first + second).normalized() else {
            throw FFRingProfileError.damagedProfile
        }
        let middle = center + bisector * first.length
        return try arc(start, middle, end)
    }

    private static func arc(
        _ start: Vec2,
        _ through: Vec2,
        _ end: Vec2
    ) throws -> [FFCurveSegment] {
        let fitted = try FFArc2D.through(start, through, end)
        return FFArcTool.segments(for: fitted)
    }

    private static func line(_ start: Vec2, _ end: Vec2) -> FFCurveSegment {
        FFCurveSegment(kind: .bezier, controlPoints: [FFPoint2(start), FFPoint2(end)])
    }
}

/// The swept body a profile previews, and the sampled mesh a viewport draws.
///
/// The surface is Phase 48's exact `FFRevolutionSurface`, so the preview is the
/// geometry a section or a volume would be measured against rather than a second
/// model. The mesh is display only: every vertex is a surface point at a sampled
/// profile parameter and a sampled angle, so the solid it encloses converges to
/// the true swept volume as the angle count rises. Phase 49's test measures that
/// convergence against Pappus's theorem instead of assuming a tolerance.
struct FFRingSweep: Equatable, Sendable {
    let surface: FFRevolutionSurface
    let angularSegments: Int

    init(
        profile: FFRingProfile,
        axisOrigin: Vec3 = .zero,
        axis: Vec3 = .unitY,
        angularSegments: Int = 96
    ) throws {
        let placed = try profile.spatial(axisOrigin: axisOrigin, axis: axis)
        self.surface = try FFRevolutionSurface(
            axisOrigin: axisOrigin,
            axis: axis,
            profile: placed
        )
        self.angularSegments = max(3, angularSegments)
    }

    /// The closed preview mesh: one ring of vertices per profile sample around
    /// one revolution. The profile is sampled per span and the seam is welded by
    /// index, so a closed section sweeps to a watertight body.
    func mesh(profileSamplesPerSpan: Int = 8) -> IndexedMesh? {
        let payload = surface.profile.payload
        guard payload.isClosed else { return nil }
        let spans = payload.segments.count
        guard spans > 0 else { return nil }
        let samples = max(2, profileSamplesPerSpan)

        var profile: [(height: Double, radius: Double)] = []
        profile.reserveCapacity(spans * samples)
        for span in 0..<spans {
            guard let curve = payload.segments[span].curve else { return nil }
            for step in 0..<samples {
                let parameter = Double(step) / Double(samples)
                let world = surface.profile.plane.embed(curve.point(at: parameter))
                let height = surface.axialCoordinate(of: world)
                let radius = surface.radialDistance(of: world)
                guard radius > FFMath.eps else { return nil }
                profile.append((height, radius))
            }
        }
        guard profile.count >= 3 else { return nil }

        let angles = angularSegments
        var positions: [Vec3] = []
        positions.reserveCapacity(profile.count * angles)
        for angleIndex in 0..<angles {
            let theta = 2 * Double.pi * Double(angleIndex) / Double(angles)
            let cosine = cos(theta)
            let sine = sin(theta)
            for sample in profile {
                positions.append(
                    surface.axisOrigin
                        + surface.axis * sample.height
                        + (surface.radialAxis * cosine + surface.outOfPlane * sine)
                            * sample.radius
                )
            }
        }

        var triangles: [MeshTriangle] = []
        triangles.reserveCapacity(profile.count * angles * 2)
        for angleIndex in 0..<angles {
            let nextAngle = (angleIndex + 1) % angles
            for index in 0..<profile.count {
                let next = (index + 1) % profile.count
                let a = angleIndex * profile.count + index
                let b = angleIndex * profile.count + next
                let c = nextAngle * profile.count + next
                let d = nextAngle * profile.count + index
                // One diagonal per quad, the same way round everywhere, keeps
                // every shared edge traversed in opposite directions.
                triangles.append(MeshTriangle(a, b, c))
                triangles.append(MeshTriangle(a, c, d))
            }
        }
        return IndexedMesh(positions: positions, triangles: triangles)
    }

    /// The signed volume the preview mesh encloses, by the divergence theorem.
    /// Its sign follows the winding, so a caller that only wants the magnitude
    /// takes the absolute value.
    func volume(profileSamplesPerSpan: Int = 8) -> Double? {
        guard let mesh = mesh(profileSamplesPerSpan: profileSamplesPerSpan) else {
            return nil
        }
        var total = 0.0
        for triangle in mesh.triangles {
            let a = mesh.positions[triangle.a]
            let b = mesh.positions[triangle.b]
            let c = mesh.positions[triangle.c]
            total += a.dot(b.cross(c)) / 6
        }
        return total
    }
}
