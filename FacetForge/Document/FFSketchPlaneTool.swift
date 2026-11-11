import Foundation

/// The work-plane definition in progress: its mode, the taps offered so far and
/// the plane once the source resolves.
///
/// Transient only. The plane a user locks is a tool value; every sketch curve is
/// an ordinary curve node placed by an ordinary `FFTransform`, so a work plane
/// adds no document field and no schema revision.
struct FFSketchPlaneDraft: Equatable, Sendable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case face
        case axis
        case threePoints

        var id: String { rawValue }

        var title: String {
            switch self {
            case .face: return "Face"
            case .axis: return "Axis"
            case .threePoints: return "Three points"
            }
        }

        var hint: String {
            switch self {
            case .face:
                return "Tap a face; its plane becomes the sketch plane"
            case .axis:
                return "Name an axis; the plane perpendicular to it becomes the sketch plane"
            case .threePoints:
                return "Tap three points that are not on one line"
            }
        }

        /// How many values a mode needs before it can name a plane. Face and axis
        /// resolve from one picked reference plus a direction; three points need
        /// three distinct places.
        var pointCount: Int { self == .threePoints ? 3 : 1 }
    }

    private(set) var mode: Mode = .threePoints
    private(set) var points: [Vec3] = []
    private(set) var plane: FFPlane3D?

    var isComplete: Bool { plane != nil }
    var tapCount: Int { points.count }

    mutating func begin(_ mode: Mode) {
        self.mode = mode
        points = []
        plane = nil
    }

    mutating func cancel() {
        self = FFSketchPlaneDraft()
    }

    /// A picked face: one point on it and the face normal. The plane is the
    /// face's own plane, so a sketch drawn here lies on the face.
    @discardableResult
    mutating func takeFace(origin: Vec3, normal: Vec3) throws -> FFPlane3D {
        mode = .face
        let resolved = try FFPlane3D.workPlane(.face(origin: origin, normal: normal))
        points = [origin]
        plane = resolved
        return resolved
    }

    /// A named axis. The plane is the one perpendicular to the axis through
    /// `origin`, which is the only plane an axis alone determines.
    @discardableResult
    mutating func takeAxis(origin: Vec3, direction: Vec3) throws -> FFPlane3D {
        mode = .axis
        let resolved = try FFPlane3D.workPlane(.axis(origin: origin, direction: direction))
        points = [origin]
        plane = resolved
        return resolved
    }

    /// One tap of a three-point definition. Returns the plane when that tap
    /// completed it, `nil` while more are needed.
    ///
    /// A refused tap is removed again, so the user can retap instead of being
    /// stuck with a draft that can never finish. That is deliberately the same
    /// shape as `FFArcDraft.add`.
    @discardableResult
    mutating func add(_ point: Vec3) throws -> FFPlane3D? {
        guard mode == .threePoints else { return plane }
        guard points.count < Mode.threePoints.pointCount else { return plane }
        if let last = points.last, last.distance(to: point) <= FFTolerance.curveJoin {
            throw FFWorkPlaneError.coincidentPoints(points.count, points.count + 1)
        }
        points.append(point)
        guard points.count == Mode.threePoints.pointCount else { return nil }
        do {
            let resolved = try FFPlane3D.planeThrough(points[0], points[1], points[2])
            plane = resolved
            return resolved
        } catch {
            points.removeLast()
            throw error
        }
    }
}

/// The live sketch: the plane it is locked to and the chain drawn in that
/// plane's own coordinates.
///
/// The chain is the Phase 39 draft, reused rather than re-implemented: duplicate
/// vertices, closing and the payload are the same code the line tool already
/// exercises. This type adds only the plane the coordinates belong to.
struct FFSketchDraft: Equatable, Sendable {
    private(set) var plane: FFPlane3D?
    private(set) var chain = FFLineChainDraft()

    var isLocked: Bool { plane != nil }
    var isActive: Bool { chain.isActive }
    var isClosed: Bool { chain.isClosed }
    var pointCount: Int { chain.points.count }

    /// What is drawn but not yet committed, in world space. Display only: the
    /// committed payload is the plane's coordinates and stays exact.
    var preview: [Vec3] {
        guard let plane else { return [] }
        var result = chain.points.map { plane.embed($0) }
        if let pending = chain.pending {
            result.append(plane.embed(pending))
        }
        return result
    }

    mutating func lock(on plane: FFPlane3D) {
        self.plane = plane
        chain = FFLineChainDraft()
    }

    /// Adds one vertex, in the locked plane's coordinates. The first tap starts
    /// the stroke; every later tap commits a segment.
    @discardableResult
    mutating func add(_ point: Vec2) throws -> Bool {
        guard isLocked else { throw FFWorkPlaneError.sketchNotLocked }
        guard point.x.isFinite, point.y.isFinite else { throw FFWorkPlaneError.nonFiniteInput }
        if chain.isActive {
            chain.preview(to: point)
            return try chain.commitPending()
        }
        chain.begin(at: point)
        return false
    }

    /// Drops the stroke that was just committed and keeps the plane locked.
    mutating func clearStroke() {
        chain = FFLineChainDraft()
    }

    func payload() throws -> FFCurvePayload {
        guard isLocked else { throw FFWorkPlaneError.sketchNotLocked }
        return try chain.payload()
    }

    mutating func cancel() {
        self = FFSketchDraft()
    }
}

extension FFPlane3D {
    /// The node transform that places a payload drawn in this plane's own
    /// coordinates into space.
    ///
    /// A curve node already stores a 2-D payload plus a `T * Rz * Ry * Rx * S`
    /// transform, so a sketch on a tilted plane needs no new document field: the
    /// plane's orthonormal frame becomes the rotation columns and its origin
    /// becomes the translation. The Euler decomposition is the document's
    /// existing `FFTransform(matrix:)` — the same conversion the gimbal commits
    /// through — so no second decomposition exists to disagree with it.
    ///
    /// Measured before this was written, in a local model of the exact
    /// composition: rebuilding the matrix from the decomposed angles reproduces
    /// the frame to 1.2e-16 on the six axis-aligned normals (four of which take
    /// the pinned-roll branch) and to 2.8e-15 over 20,000 random orthonormal
    /// frames, and transforms a 2-D sketch point to the plane's embedded point to
    /// 1.1e-13 mm at coordinates up to 80 mm. The tests therefore assert 1e-9 mm
    /// for a placed point and 1e-12 for a rotation column: four orders above the
    /// measured noise, not at the ideal geometry.
    var nodePlacement: FFTransform {
        FFTransform(matrix: Mat4(
            m00: xAxis.x, m01: yAxis.x, m02: normal.x, m03: origin.x,
            m10: xAxis.y, m11: yAxis.y, m12: normal.y, m13: origin.y,
            m20: xAxis.z, m21: yAxis.z, m22: normal.z, m23: origin.z,
            m30: 0, m31: 0, m32: 0, m33: 1
        ))
    }
}
