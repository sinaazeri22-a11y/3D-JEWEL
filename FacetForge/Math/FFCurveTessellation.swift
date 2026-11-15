import Foundation

extension TessellationSettings {
    /// The sketch overlay's per-span budget.
    ///
    /// It is the display tolerance with a much smaller segment cap than
    /// `display`, because `display` is a per-call budget for a whole mesh edge
    /// while this one applies to every span of a payload that may hold ten
    /// thousand spans. The cap bounds one pathological span without coarsening
    /// the ordinary ones, and a straight span collapses to its two endpoints
    /// rather than paying eight samples for a line.
    static let curveDisplay: TessellationSettings = {
        guard let settings = TessellationSettings(
            chordalTolerance: 0.05,
            angularTolerance: FFMath.radians(10),
            maximumSegments: 64
        ) else {
            preconditionFailure("built-in curve tessellation preset must be valid")
        }
        return settings
    }()
}

/// Flattening for the sketch overlay.
///
/// The overlay used to sample every span at eight parameters regardless of what
/// the span was, which is eight times the geometry of a polyline and a fresh
/// sample of the entire payload after any edit. This keeps the same contract -
/// a span that cannot be rebuilt refuses the whole payload - but tessellates
/// each span against the display tolerance, so a straight span costs two points
/// and a curved one costs what its curvature asks for, never more than the
/// per-span cap.
enum FFCurveTessellation {
    /// The local points for one span, including both of its endpoints.
    static func segmentPoints(
        for segment: FFCurveSegment,
        settings: TessellationSettings = .curveDisplay
    ) -> [Vec3]? {
        guard let curve = segment.curve,
              let path = Tessellator.tessellate(curve, settings: settings)
        else {
            return nil
        }
        var points: [Vec3] = []
        points.reserveCapacity(path.points.count)
        for point in path.points {
            guard point.x.isFinite, point.y.isFinite else { return nil }
            let world = Vec3(x: point.x, y: point.y, z: 0)
            // A degenerate span can tessellate to the same point repeatedly.
            // Keeping one copy bounds the cost without changing the drawing.
            if let last = points.last, last == world { continue }
            points.append(world)
        }
        guard points.count >= 2 else { return nil }
        return points
    }

    /// Appends one span, dropping the joint it shares with the previous span so
    /// a chain stores each vertex once.
    static func append(_ span: [Vec3], to result: inout [Vec3]) {
        guard !span.isEmpty else { return }
        var start = 0
        if let last = result.last, span[0] == last {
            start = 1
        }
        result.append(contentsOf: span.dropFirst(start))
    }
}

/// A per-node tessellation that survives between edits.
///
/// The payload is a value and every edit replaces it, so the cache compares the
/// new segments with the ones it last sampled and re-uses each unchanged
/// span's points. An edit to one control point therefore re-samples the one or
/// two spans that point belongs to instead of the whole curve, and the world
/// points are only re-projected when the node's transform actually moved.
///
/// It is a class because the session owns one per node; the arrays it returns
/// are values, so no caller can mutate its state through them.
final class FFCurveTessellationCache {
    private var segments: [FFCurveSegment] = []
    private var spans: [[Vec3]] = []
    private var settings: TessellationSettings?
    private(set) var localPoints: [Vec3] = []
    private var matrix: Mat4?
    private var worldPoints: [Vec3] = []

    /// How many spans the last `update` had to sample. Zero means the payload
    /// was unchanged; a control-point edit is normally one or two.
    private(set) var resampledSegmentCount = 0
    /// How many times `worldPoints` actually transformed the local points.
    private(set) var worldRebuildCount = 0

    /// Returns the local points, or nil when a span cannot be rebuilt. A nil
    /// answer also clears the cache, so a later valid payload samples from
    /// scratch instead of mixing in points from the broken one.
    @discardableResult
    func update(
        payload: FFCurvePayload,
        settings newSettings: TessellationSettings = .curveDisplay
    ) -> [Vec3]? {
        let sameSettings = settings == newSettings
        if sameSettings, payload.segments == segments, !localPoints.isEmpty {
            resampledSegmentCount = 0
            return localPoints
        }

        var updatedSpans: [[Vec3]] = []
        updatedSpans.reserveCapacity(payload.segments.count)
        var resampled = 0
        for (index, segment) in payload.segments.enumerated() {
            if sameSettings,
               index < segments.count,
               index < spans.count,
               segments[index] == segment {
                updatedSpans.append(spans[index])
                continue
            }
            guard let sampled = FFCurveTessellation.segmentPoints(
                for: segment,
                settings: newSettings
            ) else {
                reset()
                return nil
            }
            updatedSpans.append(sampled)
            resampled += 1
        }

        var flat: [Vec3] = []
        flat.reserveCapacity(updatedSpans.reduce(0) { $0 + $1.count })
        for span in updatedSpans {
            FFCurveTessellation.append(span, to: &flat)
        }
        guard flat.count >= 2 else {
            reset()
            return nil
        }

        spans = updatedSpans
        segments = payload.segments
        settings = newSettings
        localPoints = flat
        resampledSegmentCount = resampled
        matrix = nil
        worldPoints = []
        return localPoints
    }

    /// The same points walked through a node's world matrix. An unchanged
    /// matrix answers the previous array instead of transforming every vertex
    /// again.
    func worldPoints(matrix newMatrix: Mat4) -> [Vec3] {
        if newMatrix == matrix, worldPoints.count == localPoints.count {
            return worldPoints
        }
        var transformed: [Vec3] = []
        transformed.reserveCapacity(localPoints.count)
        for point in localPoints {
            let value = newMatrix * Vec4(x: point.x, y: point.y, z: point.z, w: 1)
            guard abs(value.w) > FFMath.eps else {
                transformed.append(point)
                continue
            }
            transformed.append(Vec3(
                x: value.x / value.w,
                y: value.y / value.w,
                z: value.z / value.w
            ))
        }
        matrix = newMatrix
        worldPoints = transformed
        worldRebuildCount += 1
        return transformed
    }

    private func reset() {
        segments = []
        spans = []
        settings = nil
        localPoints = []
        resampledSegmentCount = 0
        matrix = nil
        worldPoints = []
    }
}
