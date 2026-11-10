import Foundation

/// Why a freehand stroke could not become a curve. Each case carries a
/// sentence, because the only feedback a pencil gets is what the panel says.
enum FFFreehandError: Error, Equatable, LocalizedError {
    case notEnoughPoints
    case invalidSimplifyTolerance
    case cannotFit(maximumError: Double)

    var errorDescription: String? {
        switch self {
        case .notEnoughPoints:
            return "A freehand spline needs at least two points"
        case .invalidSimplifyTolerance:
            return "The simplify threshold must be greater than zero"
        case .cannotFit(let maximumError):
            return "That stroke cannot fit within 0.2 mm (best \(FFPrecision.lengthString(millimetres: maximumError, unit: .millimetres)))"
        }
    }
}

/// A pencil stroke in the sketch plane, and the deterministic fit that turns it
/// into an ordinary curve payload.
///
/// The pipeline is fixed and testable: Douglas–Peucker decides which samples
/// survive at the simplify threshold, a Laplacian relaxation applies the
/// smoothing control without moving the endpoints, and a centripetal
/// Catmull–Rom interpolation through the surviving points is written as cubic
/// NURBS spans. The fit is then measured against the raw samples; if it misses
/// the row's 0.2 mm budget, the fit retries tighter (less smoothing, a
/// smaller simplify tolerance) instead of committing a curve that does not
/// represent the stroke.
struct FFFreehandStroke: Equatable, Sendable {
    var samples: [Vec2]
    var smoothing: Double = FFFreehandStroke.defaultSmoothing
    var simplifyTolerance: Double = FFFreehandStroke.defaultSimplifyTolerance

    /// The row's fidelity budget for the committed curve.
    static let maximumFitError = 0.2
    static let defaultSmoothing = 0.35
    static let defaultSimplifyTolerance = 0.05
    /// The most a stroke may be relaxed before the slider stops mattering.
    static let smoothingLimit = 0.9

    var polylineLength: Double {
        guard samples.count >= 2 else { return 0 }
        return (0..<(samples.count - 1)).reduce(0) { total, index in
            total + samples[index].distance(to: samples[index + 1])
        }
    }

    var isValid: Bool {
        samples.count >= 2
            && samples.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            && simplifyTolerance.isFinite
            && simplifyTolerance > 0
            && smoothing.isFinite
    }

    /// The surviving samples, using the stated tolerance. The simplified
    /// polyline is guaranteed within that distance of every raw sample, which is
    /// what "simplify preserves shape within 0.05 mm" means.
    func simplifiedPoints(tolerance: Double? = nil) -> [Vec2] {
        Self.douglasPeucker(samples, tolerance: tolerance ?? simplifyTolerance)
    }

    /// The exact curve to commit. One call is deterministic for the same
    /// samples and controls.
    func payload() throws -> FFCurvePayload {
        guard samples.count >= 2, samples.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw FFFreehandError.notEnoughPoints
        }
        guard simplifyTolerance.isFinite, simplifyTolerance > 0 else {
            throw FFFreehandError.invalidSimplifyTolerance
        }

        var amount = FFMath.clamp(smoothing.isFinite ? smoothing : 0, to: 0...Self.smoothingLimit)
        var tolerance = simplifyTolerance
        var worst = Double.infinity

        // The first attempt is the user's settings. A denser, less relaxed fit
        // is only a fallback for a stroke whose spans curve more than their
        // samples suggest; it never loosens the budget.
        for _ in 0..<4 {
            let reduced = Self.douglasPeucker(samples, tolerance: tolerance)
            let relaxed = Self.relaxed(reduced, amount: amount)
            let fitted = Self.fit(points: relaxed)
            worst = maximumFitError(of: fitted)
            if worst <= Self.maximumFitError {
                return fitted
            }
            amount = max(0, amount - 0.25)
            tolerance = max(1e-4, tolerance / 2)
        }
        throw FFFreehandError.cannotFit(maximumError: worst)
    }

    /// The largest distance from a raw sample to the fitted curve, estimated by
    /// dense sampling of the exact NURBS spans. This is the measurement the
    /// acceptance cites, so the production fit and the tests share one routine.
    func maximumFitError(of payload: FFCurvePayload) -> Double {
        guard let path = payload.path(), !samples.isEmpty else { return .infinity }
        let polylines: [[Vec2]] = path.curves.map { curve in
            (0...24).map { curve.point(at: Double($0) / 24) }
        }
        var worst = 0.0
        for sample in samples {
            var best = Double.infinity
            for polyline in polylines where polyline.count >= 2 {
                for index in 0..<(polyline.count - 1) {
                    best = min(
                        best,
                        Self.distance(from: sample, toSegment: polyline[index], polyline[index + 1])
                    )
                }
            }
            worst = max(worst, best)
        }
        return worst
    }

    // MARK: - Fitting

    /// Douglas–Peucker. The first and last points always survive.
    static func douglasPeucker(_ points: [Vec2], tolerance: Double) -> [Vec2] {
        guard points.count > 2, tolerance.isFinite, tolerance >= 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let pair = stack.popLast() {
            let (first, last) = pair
            guard last > first + 1 else { continue }
            var worst = 0.0
            var index = -1
            for candidate in (first + 1)..<last {
                let distance = distance(
                    from: points[candidate],
                    toSegment: points[first],
                    points[last]
                )
                if distance > worst {
                    worst = distance
                    index = candidate
                }
            }
            if worst > tolerance, index > first {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// One Laplacian pass over interior points. Endpoints stay put, so the
    /// stroke still starts and ends where the pencil did.
    static func relaxed(_ points: [Vec2], amount: Double) -> [Vec2] {
        guard points.count > 2, amount > 0 else { return points }
        let factor = FFMath.clamp(amount, to: 0...1) * 0.5
        var result = points
        for index in 1..<(points.count - 1) {
            let midpoint = (points[index - 1] + points[index + 1]) * 0.5
            result[index] = points[index] + (midpoint - points[index]) * factor
        }
        return result
    }

    /// Catmull–Rom through the points, emitted as one cubic NURBS span per
    /// segment. The span's four Bézier control points are also valid NURBS
    /// control points at knots `0,0,0,0,1,1,1,1`, so the curve is exact and
    /// stays in the payload the document already stores.
    static func fit(points: [Vec2]) -> FFCurvePayload {
        guard points.count >= 2 else { return FFCurvePayload(segments: []) }
        var segments: [FFCurveSegment] = []
        segments.reserveCapacity(points.count - 1)
        for index in 0..<(points.count - 1) {
            let previous = index == 0 ? points[index] : points[index - 1]
            let start = points[index]
            let end = points[index + 1]
            let following = index + 2 < points.count ? points[index + 2] : points[points.count - 1]
            let controlOne = start + (end - previous) * (1.0 / 6.0)
            let controlTwo = end - (following - start) * (1.0 / 6.0)
            segments.append(FFCurveSegment(
                kind: .nurbs,
                controlPoints: [
                    FFPoint2(start),
                    FFPoint2(controlOne),
                    FFPoint2(controlTwo),
                    FFPoint2(end),
                ],
                weights: [1, 1, 1, 1],
                degree: 3,
                knots: [0, 0, 0, 0, 1, 1, 1, 1]
            ))
        }
        return FFCurvePayload(segments: segments, isClosed: false)
    }

    /// The distance from a point to a line segment, clamped to the segment.
    static func distance(from point: Vec2, toSegment start: Vec2, _ end: Vec2) -> Double {
        let span = end - start
        let lengthSquared = span.lengthSquared
        guard lengthSquared > FFMath.eps else { return point.distance(to: start) }
        let t = FFMath.clamp((point - start).dot(span) / lengthSquared, to: 0...1)
        return point.distance(to: start + span * t)
    }
}
