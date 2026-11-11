import Foundation

/// The three ways Phase 50 defines a work plane.
///
/// The sources are deliberately not interchangeable. A face fixes a point and a
/// normal, so it determines one plane outright. Three points determine the plane
/// through them. An axis fixes only a direction: the planes containing a line are
/// a one-parameter family, so the unique plane an axis alone names is the one
/// perpendicular to it. A caller that wants a plane *containing* the axis passes
/// a face whose normal is perpendicular to that axis. Stating the premise here is
/// what stops a later phase from reading `.axis` as "contains".
enum FFWorkPlaneSource: Equatable, Sendable {
    case face(origin: Vec3, normal: Vec3)
    case axis(origin: Vec3, direction: Vec3)
    case threePoints(Vec3, Vec3, Vec3)
}

/// Why a work-plane definition was refused.
///
/// Every case carries a sentence. A plane that silently falls back to the ground
/// plane would put a sketch somewhere the user did not ask for, so a refusal has
/// to say what was wrong.
enum FFWorkPlaneError: Error, Equatable, LocalizedError {
    case nonFiniteInput
    case degenerateNormal
    case degenerateAxis
    case coincidentPoints(Int, Int)
    case collinearPoints
    case unreachablePlane
    case sketchNotLocked

    var errorDescription: String? {
        switch self {
        case .nonFiniteInput:
            return "A work plane needs finite coordinates"
        case .degenerateNormal:
            return "A face needs a normal with a length; this one has none"
        case .degenerateAxis:
            return "An axis needs a direction with a length; this one has none"
        case .coincidentPoints(let first, let second):
            return "Points \(first) and \(second) are the same place; three points need three distinct places"
        case .collinearPoints:
            return "Those three points lie on one line, so no plane passes through them"
        case .unreachablePlane:
            return "That tap runs parallel to the locked plane or behind the camera"
        case .sketchNotLocked:
            return "Lock a work plane before drawing on it"
        }
    }
}

extension FFPlane3D {
    /// The plane a source names, or a sentence saying why it names none.
    static func workPlane(_ source: FFWorkPlaneSource) throws -> FFPlane3D {
        switch source {
        case .face(let origin, let normal):
            return try facePlane(origin: origin, normal: normal)
        case .axis(let origin, let direction):
            return try planePerpendicular(to: direction, through: origin)
        case .threePoints(let first, let second, let third):
            return try planeThrough(first, second, third)
        }
    }

    /// A face's own plane: it passes through `origin` with `normal` as its
    /// normal, so a sketch drawn here lies on the face.
    static func facePlane(origin: Vec3, normal: Vec3) throws -> FFPlane3D {
        guard isFinite(origin), isFinite(normal) else { throw FFWorkPlaneError.nonFiniteInput }
        guard let plane = FFPlane3D(origin: origin, normal: normal) else {
            throw FFWorkPlaneError.degenerateNormal
        }
        return plane
    }

    /// The plane perpendicular to `axis` through `origin`, which is the only
    /// plane an axis alone determines: see `FFWorkPlaneSource.axis`.
    static func planePerpendicular(to axis: Vec3, through origin: Vec3) throws -> FFPlane3D {
        guard isFinite(origin), isFinite(axis) else { throw FFWorkPlaneError.nonFiniteInput }
        guard axis.length > FFMath.eps else { throw FFWorkPlaneError.degenerateAxis }
        guard let plane = FFPlane3D(origin: origin, normal: axis) else {
            throw FFWorkPlaneError.degenerateAxis
        }
        return plane
    }

    /// The plane through three distinct, non-collinear points. `a` is the
    /// origin, `a -> b` is the x axis, and `c` is folded into the y axis by
    /// orthogonalisation, so all three points lie in the plane by construction
    /// rather than by a later projection.
    ///
    /// Coincidence and collinearity are judged at the curve kernel's join
    /// tolerance, because a plane whose third point sits a nanometre off the
    /// line through the first two is a plane whose normal is noise.
    static func planeThrough(_ a: Vec3, _ b: Vec3, _ c: Vec3) throws -> FFPlane3D {
        guard isFinite(a), isFinite(b), isFinite(c) else { throw FFWorkPlaneError.nonFiniteInput }
        let first = b - a
        let second = c - a
        guard first.length > FFTolerance.curveJoin else {
            throw FFWorkPlaneError.coincidentPoints(1, 2)
        }
        guard second.length > FFTolerance.curveJoin else {
            throw FFWorkPlaneError.coincidentPoints(1, 3)
        }
        guard let firstAxis = first.normalized() else {
            throw FFWorkPlaneError.coincidentPoints(1, 2)
        }
        let residual = second - firstAxis * second.dot(firstAxis)
        guard residual.length > FFTolerance.curveJoin else {
            throw FFWorkPlaneError.collinearPoints
        }
        guard let plane = FFPlane3D(origin: a, xAxis: firstAxis, yAxis: residual) else {
            throw FFWorkPlaneError.collinearPoints
        }
        return plane
    }

    /// Where a ray meets this plane, expressed in the plane's own 2-D frame.
    ///
    /// This reuses `Ray.intersection(with:)` — the same Hessian solve Phase 16's
    /// picking uses — rather than repeating the denominator formula, so a
    /// parallel ray and a plane behind the camera are refused in exactly one
    /// place. `coordinates(of:)` drops the normal component, so a hit that is
    /// already on the plane round-trips to its own coordinates.
    func sketchPoint(of ray: Ray) -> Vec2? {
        guard let hessian = Plane(normal: normal, point: origin) else { return nil }
        guard let distance = ray.intersection(with: hessian) else { return nil }
        let hit = ray.point(at: distance)
        guard FFPlane3D.isFinite(hit) else { return nil }
        return coordinates(of: hit)
    }
}
