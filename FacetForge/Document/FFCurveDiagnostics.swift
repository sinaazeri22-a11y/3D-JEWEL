import Foundation

/// A point where a span's signed curvature passes through zero. An inflection
/// is an interior property of one span: a corner where two spans meet with
/// opposite curvature is a G0 or G1 seam, not an inflection, because the
/// curvature jumps there rather than crossing zero.
struct FFInflectionMarker: Equatable, Sendable {
    var segment: Int
    /// The resolved parameter inside the span, in 0...1.
    var parameter: Double
    var point: Vec2

    var summary: String {
        "Inflection · span \(segment + 1) · t \(FFPrecision.fixed(parameter, decimals: 4))"
    }
}

/// One measured seam in a payload. `continuity` is nil when the two spans do not
/// actually meet, so "parallel but 1 mm apart" can never be read as a G1 join.
struct FFJoinReading: Equatable, Sendable {
    /// Index of the span whose end owns the seam.
    var index: Int
    /// The arriving span's end point.
    var position: Vec2
    /// Distance from `position` to the departing span's start.
    var gap: Double
    /// Unsigned angle between the arriving and departing unit tangents, in
    /// radians.
    var tangentAngle: Double
    var continuity: FFCurveContinuity?
    var curvatureBefore: Double
    var curvatureAfter: Double

    var curvatureDifference: Double { abs(curvatureAfter - curvatureBefore) }

    var summary: String {
        let label = continuity?.label ?? "Not joined"
        let bend = FFPrecision.fixed(FFMath.degrees(tangentAngle), decimals: 3)
        let gap = FFPrecision.fixed(self.gap, decimals: 6)
        return "\(label) · gap \(gap) mm · bend \(bend)°"
    }
}

/// The tightest bend on a payload: the parameter where |curvature| is largest
/// and the radius that follows from it.
struct FFMinRadiusReading: Equatable, Sendable {
    var segment: Int
    var parameter: Double
    var point: Vec2
    /// `1 / abs(curvature)`, in millimetres.
    var radius: Double
    /// Signed curvature at the reported parameter, in inverse millimetres.
    var curvature: Double

    var summary: String {
        "min radius \(FFPrecision.fixed(radius, decimals: 3)) mm · span \(segment + 1)"
    }
}

/// The whole min-radius answer. `tightest` is nil for a payload that never
/// bends — a straight line or a closed square — which is different from a
/// payload that could not be measured at all, where the report itself is nil.
struct FFMinRadiusReport: Equatable, Sendable {
    var tightest: FFMinRadiusReading?
    var spanCount: Int

    var isStraight: Bool { tightest == nil }

    var summary: String {
        guard let tightest else {
            return spanCount == 0 ? "No spans" : "Every span is straight"
        }
        return tightest.summary
    }
}

/// Limits shared by the readouts. A curvature below `zero` is numerically
/// indistinguishable from straight, so it neither counts as a bend nor makes an
/// inflection.
private enum FFDiagnosticLimit {
    static let zero: Double = 1e-12
    static let bisectionSteps = 80
    static let bisectionTolerance = 1e-12
    static let refinementSteps = 60
}

/// Precision budget: the kernel's NURBS second derivative is a documented
/// finite difference (`h = 1e-6`) that becomes one-sided at a span's ends,
/// so curvature there carries a measured relative bias of 8.8e-7 while
/// interior samples agree with the analytic value to 1e-11. The readouts
/// report the measured number; the tolerances they are consumed against are
/// stated against that budget, never as if the ends were exact.
///
extension FFCurveDiagnostics {
    // MARK: - Curvature

    /// The signed curvature `(x'y'' − y'x'') / |B'|³` at one parameter. It is
    /// positive where the curve turns left, which is what makes an inflection a
    /// change of sign rather than a change of magnitude. A zero-speed parameter
    /// reports zero: the direction is undefined, so the curvature is not a
    /// number the readout may invent.
    static func signedCurvature(of curve: Curve2D, at parameter: Double) -> Double {
        FFCurveCleanup.signedCurvature(
            curve,
            at: parameter,
            derivative: curve.derivative(at: parameter)
        )
    }

    // MARK: - Inflections

    /// Every interior zero of a span's signed curvature, in path order. The
    /// search samples each span, keeps the samples whose curvature is large
    /// enough to have a sign, and bisects the parameter between consecutive
    /// samples of opposite sign. Return nil when a span cannot be rebuilt, so a
    /// damaged payload never produces a plausible marker list.
    static func inflections(
        of payload: FFCurvePayload,
        samplesPerSegment: Int = 64
    ) -> [FFInflectionMarker]? {
        let samples = max(2, samplesPerSegment)
        var markers: [FFInflectionMarker] = []

        for (segmentIndex, segment) in payload.segments.enumerated() {
            guard let curve = segment.curve else { return nil }
            var bends: [(parameter: Double, curvature: Double)] = []
            bends.reserveCapacity(samples + 1)
            for step in 0...samples {
                let parameter = Double(step) / Double(samples)
                let curvature = signedCurvature(of: curve, at: parameter)
                if abs(curvature) > FFDiagnosticLimit.zero {
                    bends.append((parameter, curvature))
                }
            }
            guard bends.count >= 2 else { continue }

            var found: [Double] = []
            for index in 1..<bends.count {
                let previous = bends[index - 1]
                let current = bends[index]
                let changesSign = (previous.curvature > 0) != (current.curvature > 0)
                guard changesSign else { continue }
                let root = crossing(
                    of: curve,
                    between: previous.parameter,
                    and: current.parameter,
                    signAtLow: previous.curvature > 0
                )
                if let last = found.last, abs(root - last) <= 1e-6 { continue }
                found.append(root)
            }
            for parameter in found {
                markers.append(FFInflectionMarker(
                    segment: segmentIndex,
                    parameter: parameter,
                    point: curve.point(at: parameter)
                ))
            }
        }
        return markers
    }

    /// Bisects a parameter interval whose curvature has opposite signs at its
    /// ends. The curvature is continuous inside a span, so a sign change
    /// guarantees a zero in the interval.
    private static func crossing(
        of curve: Curve2D,
        between low: Double,
        and high: Double,
        signAtLow: Bool
    ) -> Double {
        var a = low
        var b = high
        for _ in 0..<FFDiagnosticLimit.bisectionSteps {
            let middle = (a + b) / 2
            let curvature = signedCurvature(of: curve, at: middle)
            if curvature == 0 { return middle }
            if (curvature > 0) == signAtLow {
                a = middle
            } else {
                b = middle
            }
            if b - a <= FFDiagnosticLimit.bisectionTolerance { break }
        }
        return (a + b) / 2
    }

    // MARK: - Continuity between joined curves

    /// Measures every seam in a payload: each join between consecutive spans,
    /// plus the closing join of a closed path. The label comes from the same
    /// measurement Phase 44's join uses, so a readout and an operation cannot
    /// disagree about a seam.
    static func joins(
        of payload: FFCurvePayload,
        tangentTolerance: Double = 1e-6,
        curvatureTolerance: Double = 1e-6
    ) -> [FFJoinReading]? {
        let count = payload.segments.count
        guard count >= 2 else { return [] }
        let seamCount = payload.isClosed ? count : count - 1
        var readings: [FFJoinReading] = []
        readings.reserveCapacity(seamCount)

        for index in 0..<seamCount {
            let next = (index + 1) % count
            let first = payload.segments[index]
            let second = payload.segments[next]
            guard let arriving = first.curve, let departing = second.curve else { return nil }
            let gap = arriving.end.distance(to: departing.start)
            guard let measurement = try? FFCurveCleanup.continuity(
                atEndOf: first,
                andStartOf: second,
                gap: gap,
                tangentTolerance: tangentTolerance,
                curvatureTolerance: curvatureTolerance
            ) else {
                return nil
            }
            readings.append(FFJoinReading(
                index: index,
                position: arriving.end,
                gap: gap,
                tangentAngle: measurement.tangentAngle,
                continuity: gap <= FFTolerance.curveJoin ? measurement.continuity : nil,
                curvatureBefore: signedCurvature(of: arriving, at: 1),
                curvatureAfter: signedCurvature(of: departing, at: 0)
            ))
        }
        return readings
    }

    // MARK: - Minimum radius

    /// The tightest bend in the payload. Samples every span for the largest
    /// |curvature|, then refines the parameter locally around that sample, so
    /// the answer is a maximum of the curvature rather than whichever sample
    /// happened to land nearest it. A payload that never bends reports no
    /// reading; a payload that cannot be rebuilt reports nil.
    static func minRadius(
        of payload: FFCurvePayload,
        samplesPerSegment: Int = 128
    ) -> FFMinRadiusReport? {
        let samples = max(2, samplesPerSegment)
        var bestSegment = 0
        var bestParameter = 0.0
        var bestMagnitude = 0.0

        for (segmentIndex, segment) in payload.segments.enumerated() {
            guard let curve = segment.curve else { return nil }
            for step in 0...samples {
                let parameter = Double(step) / Double(samples)
                let curvature = signedCurvature(of: curve, at: parameter)
                let magnitude = abs(curvature)
                if magnitude > bestMagnitude {
                    bestSegment = segmentIndex
                    bestParameter = parameter
                    bestMagnitude = magnitude
                }
            }
        }

        guard bestMagnitude > FFDiagnosticLimit.zero else {
            return FFMinRadiusReport(tightest: nil, spanCount: payload.segments.count)
        }
        guard let curve = payload.segments[bestSegment].curve else { return nil }

        let step = 1 / Double(samples)
        let refined = refineMaximum(
            of: { abs(signedCurvature(of: curve, at: $0)) },
            between: max(0, bestParameter - step),
            and: min(1, bestParameter + step)
        )
        let parameter = abs(refined.value) >= bestMagnitude ? refined.parameter : bestParameter
        let curvature = signedCurvature(of: curve, at: parameter)
        let magnitude = max(abs(curvature), bestMagnitude)
        return FFMinRadiusReport(
            tightest: FFMinRadiusReading(
                segment: bestSegment,
                parameter: parameter,
                point: curve.point(at: parameter),
                radius: 1 / magnitude,
                curvature: curvature
            ),
            spanCount: payload.segments.count
        )
    }

    /// Ternary search for the largest value in a bracket. It assumes the bracket
    /// is unimodal, which is the case around a sampled maximum of |curvature|
    /// for the spans a profile contains; the caller keeps the better of the
    /// refined and sampled answers, so a poor refinement can never make the
    /// reported radius larger than the sampled one.
    private static func refineMaximum(
        of value: (Double) -> Double,
        between low: Double,
        and high: Double
    ) -> (parameter: Double, value: Double) {
        var a = low
        var b = high
        for _ in 0..<FFDiagnosticLimit.refinementSteps {
            let third = (b - a) / 3
            let first = a + third
            let second = b - third
            if value(first) < value(second) {
                a = first
            } else {
                b = second
            }
        }
        let parameter = (a + b) / 2
        return (parameter, value(parameter))
    }
}
