import Foundation

/// How a corner is replaced. The treatment is a value, not a mode: it carries
/// the measurement the user typed, and resolving that measurement against a
/// corner's legs is what decides whether it fits. A fillet is an exact circular
/// arc tangent to both legs; a chamfer is the straight cut between them.
enum FFCornerTreatment: Equatable, Sendable {
    case fillet(radius: Double)
    case chamfer(distance: Double)

    var label: String {
        switch self {
        case .fillet: return "Fillet"
        case .chamfer: return "Chamfer"
        }
    }

    /// The number the user typed, in millimetres.
    var measurement: Double {
        switch self {
        case .fillet(let radius): return radius
        case .chamfer(let distance): return distance
        }
    }

    /// The base name for a node created by the keep option.
    var nodeName: String { label }
}

/// Why a corner treatment was refused. Every case carries a sentence, and the
/// two fit refusals name both numbers, because "the radius is too big" is not
/// something a jeweller can act on.
enum FFCornerError: Error, Equatable, LocalizedError, Sendable {
    case emptyCurve
    case noCorner(Int)
    case cornerNotJoined(Int)
    case curvedLeg(segment: Int)
    case invalidCurve(segment: Int)
    case degenerateLeg(segment: Int)
    case degenerateCorner(Int)
    case invalidRadius(Double)
    case invalidDistance(Double)
    case filletExceedsLeg(corner: Int, radius: Double, required: Double, available: Double)
    case chamferExceedsLeg(corner: Int, distance: Double, required: Double, available: Double)

    var errorDescription: String? {
        switch self {
        case .emptyCurve:
            return "The curve has no spans to treat"
        case .noCorner(let corner):
            return "The curve has no corner \(corner + 1)"
        case .cornerNotJoined(let corner):
            return "Corner \(corner + 1) is not a joint: its two spans do not meet"
        case .curvedLeg(let segment):
            return "Segment \(segment + 1) is not a straight leg; a fillet needs straight spans"
        case .invalidCurve(let segment):
            return "Segment \(segment + 1) cannot be rebuilt as a curve"
        case .degenerateLeg(let segment):
            return "Segment \(segment + 1) has no length to treat"
        case .degenerateCorner(let corner):
            return "Corner \(corner + 1) has collinear legs, so there is no corner to treat"
        case .invalidRadius(let radius):
            return "A fillet radius must be finite and greater than zero (got \(FFPrecision.fixed(radius, decimals: 4)) mm)"
        case .invalidDistance(let distance):
            return "A chamfer distance must be finite and greater than zero (got \(FFPrecision.fixed(distance, decimals: 4)) mm)"
        case .filletExceedsLeg(let corner, let radius, let required, let available):
            return "A \(FFPrecision.fixed(radius, decimals: 3)) mm fillet radius needs \(FFPrecision.fixed(required, decimals: 3)) mm of leg at corner \(corner + 1), but its shortest leg is \(FFPrecision.fixed(available, decimals: 3)) mm"
        case .chamferExceedsLeg(let corner, let distance, let required, let available):
            return "A \(FFPrecision.fixed(distance, decimals: 3)) mm chamfer needs \(FFPrecision.fixed(required, decimals: 3)) mm of leg at corner \(corner + 1), but its shortest leg is \(FFPrecision.fixed(available, decimals: 3)) mm"
        }
    }
}

/// The measured corner a treatment resolves against: the shared vertex, the two
/// unit directions of travel, the available leg on each side, and the interior
/// angle. Plain data so a view or a tool can preview the result without owning
/// a curve, and so the fit maths is testable on its own.
struct FFCornerGeometry: Equatable, Sendable {
    /// Index of the span whose end is the corner; the next span owns its start.
    var index: Int
    var vertex: Vec2
    /// Unit direction of travel arriving at the vertex.
    var incomingDirection: Vec2
    /// Unit direction of travel leaving the vertex.
    var outgoingDirection: Vec2
    /// Distance from the previous point to the vertex, in millimetres.
    var incomingLeg: Double
    /// Distance from the vertex to the next point, in millimetres.
    var outgoingLeg: Double
    /// The angle between the two legs inside the corner, in radians.
    var interiorAngle: Double

    /// The leg that limits a treatment: a fillet must fit inside both.
    var availableLeg: Double { min(incomingLeg, outgoingLeg) }

    /// How far along each leg the tangent point sits for a radius. This is
    /// `radius / tan(interior / 2)`, so a right angle needs exactly the radius
    /// and a sharp corner needs much more than it.
    func tangentLength(forRadius radius: Double) -> Double {
        radius / tan(interiorAngle / 2)
    }

    /// A chamfer measures along the legs directly.
    func tangentLength(forChamfer distance: Double) -> Double { distance }

    /// The two tangent points, in path order.
    func tangentPoints(for treatment: FFCornerTreatment) -> (start: Vec2, end: Vec2) {
        let length: Double
        switch treatment {
        case .fillet(let radius): length = tangentLength(forRadius: radius)
        case .chamfer(let distance): length = tangentLength(forChamfer: distance)
        }
        return (
            vertex - incomingDirection * length,
            vertex + outgoingDirection * length
        )
    }
}

/// What one corner treatment changed, in numbers a panel can show.
struct FFCornerReport: Equatable, Sendable {
    /// Index of the treated corner, in the pre-treatment payload.
    var corner: Int
    var label: String
    var measurement: Double
    /// Distance from the removed vertex to each tangent point, in millimetres.
    var tangentLength: Double
    /// Spans the treatment itself costs: one for a chamfer or a shallow arc,
    /// two for an arc wider than a quarter turn.
    var treatmentSpanCount: Int
    /// The vertex the treatment removed.
    var vertex: Vec2
    var isClosed: Bool

    var summary: String {
        let spans = treatmentSpanCount == 1 ? "1 span" : "\(treatmentSpanCount) spans"
        return "\(label) \(FFPrecision.fixed(measurement, decimals: 3)) mm · \(spans)"
    }
}

/// A finished corner treatment. `payload` is the whole path with the corner
/// trimmed at the tangent points; `treatment` is the arc or the chamfer span on
/// its own, which is what the keep option commits as separate geometry and what
/// a preview draws before anything is committed.
struct FFCornerOutcome: Equatable, Sendable {
    var payload: FFCurvePayload
    var treatment: FFCurvePayload
    var report: FFCornerReport
}

extension FFCurvePayload {
    /// The number of joints a treatment can address. An open path has one fewer
    /// corner than spans; a closed path also has the join from its last span
    /// back to its first.
    var cornerCount: Int {
        guard segments.count >= 2 else { return 0 }
        return isClosed ? segments.count : segments.count - 1
    }

    /// Resolves one corner into the geometry a treatment needs. Every refusal
    /// here is a statement about the input, so a caller never gets a geometry
    /// it cannot act on.
    func cornerGeometry(at index: Int) throws -> FFCornerGeometry {
        guard !segments.isEmpty else { throw FFCornerError.emptyCurve }
        guard index >= 0, index < cornerCount else { throw FFCornerError.noCorner(index) }

        let nextIndex = (index + 1) % segments.count
        let incomingSegment = segments[index]
        let outgoingSegment = segments[nextIndex]

        guard let incoming = incomingSegment.curve else {
            throw FFCornerError.invalidCurve(segment: index)
        }
        guard let outgoing = outgoingSegment.curve else {
            throw FFCornerError.invalidCurve(segment: nextIndex)
        }
        guard Self.isStraightLeg(incomingSegment) else {
            throw FFCornerError.curvedLeg(segment: index)
        }
        guard Self.isStraightLeg(outgoingSegment) else {
            throw FFCornerError.curvedLeg(segment: nextIndex)
        }
        guard incoming.end.distance(to: outgoing.start) <= FFTolerance.curveJoin else {
            throw FFCornerError.cornerNotJoined(index)
        }

        let incomingLeg = incoming.start.distance(to: incoming.end)
        guard incomingLeg > FFTolerance.curveJoin else {
            throw FFCornerError.degenerateLeg(segment: index)
        }
        let outgoingLeg = outgoing.start.distance(to: outgoing.end)
        guard outgoingLeg > FFTolerance.curveJoin else {
            throw FFCornerError.degenerateLeg(segment: nextIndex)
        }
        guard let incomingDirection = (incoming.end - incoming.start).normalized(),
              let outgoingDirection = (outgoing.end - outgoing.start).normalized()
        else {
            throw FFCornerError.degenerateLeg(segment: index)
        }

        let cosine = FFMath.clamp((-incomingDirection).dot(outgoingDirection), to: -1...1)
        let interiorAngle = acos(cosine)
        guard interiorAngle > 1e-9, interiorAngle < Double.pi - 1e-9 else {
            throw FFCornerError.degenerateCorner(index)
        }

        return FFCornerGeometry(
            index: index,
            vertex: incoming.end,
            incomingDirection: incomingDirection,
            outgoingDirection: outgoingDirection,
            incomingLeg: incomingLeg,
            outgoingLeg: outgoingLeg,
            interiorAngle: interiorAngle
        )
    }

    /// Replaces one corner with a fillet arc or a chamfer cut.
    ///
    /// The treated path keeps the payload representation: a fillet is an exact
    /// rational quadratic NURBS arc, the same encoding `FFArcTool` already
    /// writes, and a chamfer is a two-point span. Both legs are trimmed back to
    /// their tangent points, so the result is one connected path whose join
    /// distances stay inside the kernel's tolerance — this is a corner
    /// treatment, not a weld of three unrelated pieces.
    ///
    /// Nothing is committed here and no document is touched: the result is a
    /// value, so a tool can preview it by drawing `treatment` and only the
    /// session turns it into an undoable edit.
    func treatingCorner(_ index: Int, with treatment: FFCornerTreatment) throws -> FFCornerOutcome {
        let geometry = try cornerGeometry(at: index)

        var treatmentSegments: [FFCurveSegment]
        let tangentLength: Double

        switch treatment {
        case .fillet(let radius):
            guard radius.isFinite, radius > FFMath.eps else {
                throw FFCornerError.invalidRadius(radius)
            }
            tangentLength = geometry.tangentLength(forRadius: radius)
            guard tangentLength.isFinite, tangentLength > 0 else {
                throw FFCornerError.invalidRadius(radius)
            }
            try Self.checkFit(
                required: tangentLength,
                geometry: geometry,
                refusal: { corner, required, available in
                    FFCornerError.filletExceedsLeg(
                        corner: corner,
                        radius: radius,
                        required: required,
                        available: available
                    )
                }
            )
            let arc = try FFArc2D.fillet(
                corner: geometry.vertex,
                first: geometry.vertex - geometry.incomingDirection * geometry.incomingLeg,
                second: geometry.vertex + geometry.outgoingDirection * geometry.outgoingLeg,
                radius: radius
            )
            treatmentSegments = FFArcTool.segments(for: arc)
            guard !treatmentSegments.isEmpty,
                  treatmentSegments.allSatisfy({ $0.curve != nil })
            else {
                throw FFCornerError.invalidRadius(radius)
            }
            // The arc must start and end on the resolved tangent points; a
            // construction that missed them would trim the legs to one place
            // and draw the arc in another.
            let filletPoints = geometry.tangentPoints(for: treatment)
            guard let first = treatmentSegments.first?.curve,
                  let last = treatmentSegments.last?.curve,
                  first.start.distance(to: filletPoints.start) <= FFTolerance.curveJoin,
                  last.end.distance(to: filletPoints.end) <= FFTolerance.curveJoin
            else {
                throw FFCornerError.invalidRadius(radius)
            }

        case .chamfer(let distance):
            guard distance.isFinite, distance > FFMath.eps else {
                throw FFCornerError.invalidDistance(distance)
            }
            tangentLength = geometry.tangentLength(forChamfer: distance)
            try Self.checkFit(
                required: tangentLength,
                geometry: geometry,
                refusal: { corner, required, available in
                    FFCornerError.chamferExceedsLeg(
                        corner: corner,
                        distance: distance,
                        required: required,
                        available: available
                    )
                }
            )
            let chamferPoints = geometry.tangentPoints(for: treatment)
            treatmentSegments = [
                FFCurveSegment(
                    kind: .bezier,
                    controlPoints: [FFPoint2(chamferPoints.start), FFPoint2(chamferPoints.end)]
                ),
            ]
            guard treatmentSegments[0].curve != nil else {
                throw FFCornerError.invalidDistance(distance)
            }
        }

        let points = geometry.tangentPoints(for: treatment)
        let trimmed = replacingCorner(
            at: index,
            with: treatmentSegments,
            tangentStart: points.start,
            tangentEnd: points.end
        )
        return FFCornerOutcome(
            payload: trimmed,
            treatment: FFCurvePayload(segments: treatmentSegments),
            report: FFCornerReport(
                corner: index,
                label: treatment.label,
                measurement: treatment.measurement,
                tangentLength: tangentLength,
                treatmentSpanCount: treatmentSegments.count,
                vertex: geometry.vertex,
                isClosed: isClosed
            )
        )
    }

    // MARK: - Internals

    /// A leg a corner treatment can trim exactly: a two-control-point span. A
    /// Bézier with two points is the line between them; a degree-one NURBS with
    /// two points is the same line however it is weighted. Anything else is a
    /// curve, and trimming it at a tangent point would need a split this
    /// operation does not claim to perform, so it is refused rather than
    /// approximated.
    private static func isStraightLeg(_ segment: FFCurveSegment) -> Bool {
        guard segment.controlPoints.count == 2 else { return false }
        switch segment.kind {
        case .bezier:
            return true
        case .nurbs:
            return segment.degree == 1
        }
    }

    /// A treatment fits only when it leaves some leg on both sides. Equality is
    /// refused: it would trim a neighbouring span to zero length, which is a
    /// broken curve rather than a tight fit.
    private static func checkFit(
        required: Double,
        geometry: FFCornerGeometry,
        refusal: (Int, Double, Double) -> FFCornerError
    ) throws {
        let available = geometry.availableLeg
        let limit = available - FFTolerance.curveJoin
        guard required.isFinite, required > 0, required <= limit else {
            throw refusal(geometry.index, required, available)
        }
    }

    /// Splices the treatment spans in at the corner and shortens both legs to
    /// their tangent points, preserving path order. For the closing corner of a
    /// closed payload the treatment belongs after the last span, because that
    /// is where the path wraps.
    private func replacingCorner(
        at index: Int,
        with treatmentSegments: [FFCurveSegment],
        tangentStart: Vec2,
        tangentEnd: Vec2
    ) -> FFCurvePayload {
        let nextIndex = (index + 1) % segments.count

        var incoming = segments[index]
        incoming.controlPoints = [incoming.controlPoints[0], FFPoint2(tangentStart)]

        var outgoing = segments[nextIndex]
        outgoing.controlPoints = [FFPoint2(tangentEnd), outgoing.controlPoints[1]]

        var result: [FFCurveSegment] = []
        result.reserveCapacity(segments.count + treatmentSegments.count)
        for position in 0..<segments.count {
            if position == index {
                result.append(incoming)
                if nextIndex == position + 1 {
                    result.append(contentsOf: treatmentSegments)
                }
            } else if position == nextIndex {
                result.append(outgoing)
            } else {
                result.append(segments[position])
            }
        }
        if nextIndex == 0 {
            result.append(contentsOf: treatmentSegments)
        }
        return FFCurvePayload(segments: result, isClosed: isClosed)
    }
}
