import Foundation

/// The ring body primitive: a circular section revolved a full turn.
///
/// This is the row's second deliverable, and it is the same geometry a jeweller
/// reaches by drawing a circle and revolving it 360 degrees, not a second torus
/// generator: the section is an ordinary closed payload and the body is built by
/// `FFRevolve`, so the primitive and a commit share one winding, one cap rule and
/// one volume.
///
/// The section is eight exact rational-quadratic arcs rather than Phase 41's four
/// quarters, and that is an acceptance decision, not a style one. The payload is
/// sampled at eight points per span, so a four-span circle becomes a 32-gon
/// around the tube and the row's torus sits 0.771% under its analytic volume at
/// any angular resolution; eight spans make it a 64-gon and 0.287% under, inside
/// the row's 0.5% with room for a runner's arithmetic. The count was modelled
/// before it was written.
struct FFRingBody: Equatable, Sendable {
    /// An 18 mm bore with a 6 mm round section: a plain band a jeweller can
    /// shell or cut later without scaling a demo body.
    static let defaultMajorRadius = 12.0
    static let defaultMinorRadius = 3.0
    static let defaultAngularSegments = 72
    static let minimumAngularSegments = 3
    static let maximumAngularSegments = 512
    static let sectionSpans = 8

    /// Axis to the centre of the tube, in millimetres.
    let majorRadius: Double
    /// Tube radius, in millimetres.
    let minorRadius: Double
    let angularSegments: Int

    init(
        majorRadius: Double = FFRingBody.defaultMajorRadius,
        minorRadius: Double = FFRingBody.defaultMinorRadius,
        angularSegments: Int = FFRingBody.defaultAngularSegments
    ) {
        self.majorRadius = majorRadius
        self.minorRadius = minorRadius
        self.angularSegments = angularSegments
    }

    var boreRadius: Double { majorRadius - minorRadius }

    var outsideDiameter: Double { (majorRadius + minorRadius) * 2 }

    var boreDiameter: Double { max(0, boreRadius) * 2 }

    /// Pappus: the section's area times the distance its centroid travels in one
    /// turn. The mesh is inscribed, so it approaches this from below.
    var analyticVolume: Double {
        2 * Double.pi * Double.pi * majorRadius * minorRadius * minorRadius
    }

    /// The one validation source: the document and a refusal both read it, so
    /// they cannot disagree about whether a body can be built.
    var validationError: FFRingBodyError? {
        guard majorRadius.isFinite, minorRadius.isFinite else { return .nonPositiveRadius }
        guard majorRadius > FFMath.eps, minorRadius > FFMath.eps else {
            return .nonPositiveRadius
        }
        guard minorRadius < majorRadius else { return .tubeFillsBore }
        guard angularSegments >= Self.minimumAngularSegments,
              angularSegments <= Self.maximumAngularSegments
        else { return .sectionsOutOfRange }
        return nil
    }

    var isValid: Bool { validationError == nil }

    /// The exact closed section this primitive revolves.
    func sectionPayload() throws -> FFCurvePayload {
        if let error = validationError { throw error }
        let sweep = 2 * Double.pi / Double(Self.sectionSpans)
        let segments = (0..<Self.sectionSpans).map { index in
            Self.arcSegment(
                center: Vec2(x: majorRadius, y: 0),
                radius: minorRadius,
                startAngle: Double(index) * sweep,
                sweep: sweep
            )
        }
        return FFCurvePayload(segments: segments, isClosed: true)
    }

    func mesh() throws -> IndexedMesh {
        let sampled = try FFSurfaceSweepProfile(payload: try sectionPayload())
        return try FFRevolve(
            profile: sampled,
            parameters: FFRevolveParameters(
                angleDegrees: FFRevolveParameters.maximumAngleDegrees
            ),
            angularSegments: angularSegments
        ).mesh()
    }

    /// A short, display-ready description in the document's unit. Views format
    /// it, never compute it.
    func summary(unit: FFLengthUnit) -> String {
        let outside = FFPrecision.lengthString(millimetres: outsideDiameter, unit: unit)
        let bore = FFPrecision.lengthString(millimetres: boreDiameter, unit: unit)
        return "Ring body · OD \(outside) · bore \(bore)"
    }

    /// One exact arc of a circle, as the rational quadratic the payload already
    /// writes for conics: the control point is the intersection of the tangents,
    /// so the span is the circle rather than a polygon of it before sampling.
    private static func arcSegment(
        center: Vec2,
        radius: Double,
        startAngle: Double,
        sweep: Double
    ) -> FFCurveSegment {
        let half = sweep / 2
        let weight = cos(half)
        let middle = startAngle + half
        let start = center + Vec2(x: cos(startAngle), y: sin(startAngle)) * radius
        let end = center + Vec2(x: cos(startAngle + sweep), y: sin(startAngle + sweep)) * radius
        let control = center + Vec2(x: cos(middle), y: sin(middle)) * (radius / weight)
        return FFCurveSegment(
            kind: .nurbs,
            controlPoints: [FFPoint2(start), FFPoint2(control), FFPoint2(end)],
            weights: [1, weight, 1],
            degree: 2,
            knots: [0, 0, 0, 1, 1, 1]
        )
    }
}

/// Why a ring body could not be built. Each case carries a sentence so a refusal
/// explains itself instead of returning a plausible-looking body.
enum FFRingBodyError: Error, Equatable, LocalizedError {
    case nonPositiveRadius
    case tubeFillsBore
    case sectionsOutOfRange

    var errorDescription: String? {
        switch self {
        case .nonPositiveRadius:
            return "A ring body needs a major and a minor radius greater than zero"
        case .tubeFillsBore:
            return "The tube radius must be smaller than the major radius, or the body closes on itself"
        case .sectionsOutOfRange:
            return "A ring body needs between \(FFRingBody.minimumAngularSegments) and \(FFRingBody.maximumAngularSegments) angular segments"
        }
    }
}
