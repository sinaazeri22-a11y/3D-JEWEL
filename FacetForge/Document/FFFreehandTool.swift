import Foundation

/// The live freehand draft. It owns only what the pencil has sampled and the
/// two fit controls; the finished curve is an ordinary curve node committed by
/// the session, so undo, the journal and autosave need no freehand branch.
///
/// Sampling happens in the view (it knows the pencil location), but only the
/// session may decide what a sample means, when a stroke begins and when it
/// becomes document state. This type is the seam: plain data, no document, no
/// commit.
struct FFFreehandDraft: Equatable, Sendable {
    private(set) var samples: [Vec2] = []
    var smoothing: Double = FFFreehandStroke.defaultSmoothing
    var simplifyTolerance: Double = FFFreehandStroke.defaultSimplifyTolerance

    init() {}

    var isActive: Bool { !samples.isEmpty }
    var pointCount: Int { samples.count }

    /// The raw sampled polyline, already in sketch-plane millimetres. The view
    /// projects it through the camera; it never decides the fit.
    var preview: [Vec3] { samples.map { Vec3(x: $0.x, y: $0.y, z: 0) } }

    var length: Double { FFFreehandStroke(samples: samples).polylineLength }

    /// Clears the stroke but keeps the fit controls, so a second stroke uses
    /// the same smoothing the user just chose.
    mutating func begin() {
        samples = []
    }

    mutating func append(_ point: Vec2) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if let last = samples.last, last.distance(to: point) < 1e-6 {
            return
        }
        samples.append(point)
    }

    mutating func cancel() {
        samples = []
    }

    /// The stroke as a curve in the existing payload. Throws its own sentence
    /// when the pencil has not drawn enough to be a curve, or when the fit
    /// cannot honour the fidelity budget.
    func payload() throws -> FFCurvePayload {
        var stroke = FFFreehandStroke(samples: samples)
        stroke.smoothing = FFMath.clamp(smoothing, to: 0...FFFreehandStroke.smoothingLimit)
        stroke.simplifyTolerance = simplifyTolerance
        return try stroke.payload()
    }
}
